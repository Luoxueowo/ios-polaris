#!/bin/bash
#
# 把编好的内核打成可以 fastboot 的 shim 镜像：
#   kernel.development.<machine> -> out/polaris-payload.bin -> out/shim-polaris-xnu.img
#
# 用法：
#   extra/package-boot.sh                    # 用构建树里的内核
#   extra/package-boot.sh --kernel PATH      # 指定内核
#   extra/package-boot.sh --cpus 4           # 只起 A55
#   extra/package-boot.sh --touch 0          # 关掉触控驱动
#   extra/package-boot.sh --touchhw 0        # 只读，不写引脚/时钟/SE（默认会写）
#   extra/package-boot.sh --keyppid 0xc5     # 强制音量加的 PMIC GPIO PPID（调参用）
#   extra/package-boot.sh --stretch 1        # 画面拉满全屏（无黑边，横向约 8% 拉伸）
#   extra/package-boot.sh --zig /path/to/zig # 指定交叉编译器
#   extra/package-boot.sh --no-copy          # 不把内核拷回 xnu/out/
#
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
build_root="${BUILD_ROOT:-$HOME/.cache/polaris-xnu}"
MACHINE_CONFIG="${MACHINE_CONFIG:-POLARIS}"
KERNEL_CONFIG="${KERNEL_CONFIG:-DEVELOPMENT}"

kc=$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')
mc=$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')
kernel="$build_root/dxb/build/xnu.obj/kernel.$kc.$mc"

cpus=8
touch=1
touchhw=1
keyppid=0
touchldo=0
touchscan=0
stretch=0
battery=1
panel=1
hz=60
copy=1

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel) shift; kernel="$1" ;;
	--cpus) shift; cpus="$1" ;;
	--touch) shift; touch="$1" ;;
	--touchhw) shift; touchhw="$1" ;;
	--keyppid) shift; keyppid="$1" ;;
	--ldo) shift; touchldo="$1" ;;
	--scan) shift; touchscan="$1" ;;
	--stretch) shift; stretch="$1" ;;
	--battery) shift; battery="$1" ;;
	--panel) shift; panel="$1" ;;
	--hz) shift; hz="$1" ;;
	--zig) shift; ZIG="$1" ;;
	--no-copy) copy=0 ;;
	-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
	*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
	shift
done

die() { echo "错误: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

step "检查内核"
[ -f "$kernel" ] || die "找不到 ${kernel}（先跑 extra/build-kernel-macos.sh）"
size=$(wc -c < "$kernel" | tr -d ' ')
ver=$(strings -a "$kernel" | grep -m1 'Darwin Kernel Version' || true)
[ -n "$ver" ] || die "$kernel 不像 XNU 内核（没有版本串）"
echo "    $kernel"
echo "    $size 字节"
echo "    $ver"
# grep on the binary itself: piping strings into "grep -q" breaks under
# pipefail, because grep exits early and strings then dies of SIGPIPE.
if [ "$touch" = 1 ]; then
	# 旧内核会走 sweet 的 SE7 分支或缺少时钟修正，刷上去只会白等一轮。
	# 只挑字符串字面量：static 函数名会被内联，二进制里查不到。
	for m in 'polaris SE14 at' 's6 branch still halted' 'vol_up ppid=' 'line sda' 'dsx pdt has no'; do
		if ! grep -aqF "$m" "$kernel"; then
			echo "    注意: 内核缺少 '$m'，是旧产物；先跑 ./extra/build-kernel-macos.sh"
			break
		fi
	done
fi

if [ "$copy" = 1 ]; then
	step "拷回仓库"
	mkdir -p "$repo_dir/xnu/out"
	cp "$kernel" "$repo_dir/xnu/out/kernel.$kc.$mc"
	echo "    xnu/out/kernel.$kc.$mc"
fi

step "生成 payload（cpus=$cpus touch=$touch touchhw=$touchhw battery=$battery panel=$panel hz=${hz}）"
cmdline="debug=0xc serial=3 cpus=$cpus keepsyms=1 \
-enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 \
ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 \
launchd_unsecure_cache=1 wdt=-1 polarissample=- polarisiolog=none \
polarisfb_noconsole=1 \
polarisfb_hz=$hz polarispanel=$panel polaristouch=$touch polaristouchhid=1 polaristouchreset=1 \
polaristouchhw=$touchhw polariskeyppid=$keyppid polarisstretch=$stretch polaristouchldo=$touchldo polaristouchscan=$touchscan polarisbuild=$(date +%m%d%H%M) \
polarisbattery=$battery"
# 反斜杠会被当成 token 的一部分（\polarispanel=1），内核就认不出这个参数。
case "$cmdline" in
*\\*) die "cmdline 里混进了反斜杠，检查续行写法" ;;
esac
mkdir -p "$repo_dir/out"
python3 "$repo_dir/tools/mkpayload.py" \
	"$repo_dir/xnu/out/kernel.$kc.$mc" "$repo_dir/xnu/out/polaris.adt" \
	"$repo_dir/out/polaris-payload.bin" --cmdline "$cmdline" >/dev/null
payload=$(wc -c < "$repo_dir/out/polaris-payload.bin" | tr -d ' ')
echo "    out/polaris-payload.bin  $payload 字节"

step "找交叉编译器"
if [ -z "${ZIG:-}" ]; then
	ZIG=$(ls /tmp/zig-*/zig 2>/dev/null | head -1 || true)
fi
if [ -z "${ZIG:-}" ] && command -v zig >/dev/null 2>&1; then
	ZIG=zig
fi
if [ -z "${ZIG:-}" ]; then
	for c in aarch64-linux-gnu-gcc aarch64-unknown-linux-gnu-gcc; do
		command -v "$c" >/dev/null 2>&1 && ZIG=""
	done
fi
if [ -n "${ZIG:-}" ]; then
	[ -x "$ZIG" ] || die "$ZIG 不可执行"
	echo "    zig: $ZIG"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	echo "    aarch64-linux-gnu-gcc"
else
	die "没有 zig 也没有 aarch64-linux-gnu-gcc。zig:
  curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.13.0/zig-macos-x86_64-0.13.0.tar.xz
  tar xf /tmp/zig.tar.xz && export ZIG=/tmp/zig-macos-x86_64-0.13.0/zig"
fi

step "打包 boot 镜像"
ZIG="${ZIG:-}" "$repo_dir/shim/build.sh" "$repo_dir/out/polaris-payload.bin" \
	2>&1 | grep -vE '^zig: warning|warning: unused function|^ +[0-9]+ \||^ +\||^ *\^|^$' || true
img="$repo_dir/out/shim-polaris-xnu.img"
[ -f "$img" ] || die "没有生成 $img"

step "完成"
ls -l "$img" | awk '{print "    " $5 " 字节  " $9}'
shasum -a 256 "$img" | sed 's/^/    /'
echo
echo "刷机: fastboot boot $(basename "$img")"
echo "构建标记: $(grep -ao 'polarisbuild=[0-9]*' "$img" | head -1)"
