#!/bin/bash
#
# 本地构建 polaris 的内核（kernel.development.polaris），配方与上游 CI 一致：
# blacktop/darwin-xnu-build 固定 SHA + xnu/patches 全套 + POLARIS machine config。
#
# 宿主要求（详见 docs/KERNEL-BUILD.md）：
#   - Xcode 的工具链可用，且 xcrun --find iig 能命中
#   - 依赖命令存在：jq（真需要）、gum/xcodes/cmake/ninja（只用于存在性检查）
#
# 用法：
#   extra/build-kernel-macos.sh                 # 构建，产物落 build 目录
#   extra/build-kernel-macos.sh --replace       # 顺手替换 xnu/out/ 里的内核（旧的存为 .prev）
#   extra/build-kernel-macos.sh --dir /path     # 指定构建目录（默认 ~/.cache/polaris-xnu）
#   extra/build-kernel-macos.sh -k              # 出错继续编（MAKEFLAGS=-k）
#   extra/build-kernel-macos.sh --kdk           # 只装 Kernel Debug Kit（可断点续传）
#   extra/build-kernel-macos.sh --clean         # 清理：恢复源码树并删除全部编译产物
#
set -euo pipefail

DXB_REPO="https://github.com/blacktop/darwin-xnu-build"
DXB_SHA="663906528d1cd5ea8fde7de6f16de73db9511549"
MACOS_VERSION="${MACOS_VERSION:-13.5}"
MACHINE_CONFIG="${MACHINE_CONFIG:-POLARIS}"
KERNEL_CONFIG="${KERNEL_CONFIG:-DEVELOPMENT}"

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
build_root="${BUILD_ROOT:-$HOME/.cache/polaris-xnu}"
dxb_dir="$build_root/dxb"
replace=0
makeflags=""
kdk_only=0
clean=0

while [ $# -gt 0 ]; do
	case "$1" in
	--replace) replace=1 ;;
	-k|--keep-going) makeflags="-k" ;;
	--kdk) kdk_only=1 ;;
	--clean) clean=1 ;;
	--dir) shift; build_root="$1" ;;
	-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
	*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
	shift
done
dxb_dir="$build_root/dxb"

die() { echo "错误: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# KDK 用断点续传装好，绕开 build.sh 里那个没有 -C - 的 curl。
# 国内走代理时这一步最容易断，断了就白下 1.5 GB。
install_kdk() {
	local name url total have mnt tries
	case "$MACOS_VERSION" in
	13.5) name="Kernel Debug Kit 13.5 build 22G74"
	      kdk_path="/Library/Developer/KDKs/KDK_13.5_22G74.kdk" ;;
	*) die "--kdk 目前只处理 13.5（当前 MACOS_VERSION=${MACOS_VERSION}）" ;;
	esac
	if [ -d "$kdk_path" ]; then
		echo "已安装: $kdk_path"
		return 0
	fi

	command -v jq >/dev/null 2>&1 || die "需要 jq"
	echo "查询 KDK 地址（依赖 raw.githubusercontent.com 可达）"
	url=$(curl -fsSL --max-time 30 \
		https://raw.githubusercontent.com/dortania/KdkSupportPkg/gh-pages/manifest.json \
		| jq -r --arg n "$name" '.[] | select(.name == $n) | .url')
	[ -n "$url" ] && [ "$url" != "null" ] || die "manifest 里没有 '$name'，或 GitHub 不可达"
	echo "  $url"

	total=$(curl -sIL --max-time 30 "$url" | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2}END{print v+0}')
	[ "$total" -gt 0 ] || die "拿不到文件大小"
	printf '  需要 %s 字节（约 %s MiB）\n' "$total" "$((total / 1048576))"

	tries=0
	while :; do
		have=$(stat -f%z /tmp/KDK.dmg 2>/dev/null || echo 0)
		[ "$have" -ge "$total" ] && break
		tries=$((tries + 1))
		[ "$tries" -gt 40 ] && die "续传 40 次仍未完成（$have/$total 字节）"
		printf '  续传第 %d 次，已有 %s MiB\n' "$tries" "$((have / 1048576))"
		curl -L -C - --connect-timeout 20 --retry 3 --retry-delay 3 \
			-o /tmp/KDK.dmg "$url" || true
		sleep 2
	done
	echo "  下载完成"

	mnt="/Volumes/Kernel Debug Kit"
	hdiutil attach /tmp/KDK.dmg >/dev/null || die "hdiutil attach 失败"
	sudo installer -pkg "$mnt/KernelDebugKit.pkg" -target / || {
		hdiutil detach "$mnt" >/dev/null 2>&1 || true
		die "installer 失败"
	}
	hdiutil detach "$mnt" >/dev/null 2>&1 || true
	[ -d "$kdk_path" ] || die "装完了但没看到 $kdk_path"
	echo "已安装: $kdk_path"
}

if [ "$kdk_only" = 1 ]; then
	step "安装 Kernel Debug Kit"
	install_kdk
	exit 0
fi

step "预检"

# 依赖：build.sh 在重写 PATH 后仍会看到 /usr/local/bin，所以那些必须在那里。
missing=""
for c in jq gum xcodes cmake ninja; do
	command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
	echo "缺少命令:$missing" >&2
	echo >&2
	echo "不要用 Homebrew（官方安装脚本已拒绝 Intel Mac）。装到 /usr/local/bin：" >&2
	echo >&2
	echo "  sudo mkdir -p /usr/local/bin" >&2
	if ! command -v jq >/dev/null 2>&1; then
		echo "  curl -fsSL -o /tmp/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64" >&2
		echo "  chmod +x /tmp/jq && sudo install -m 755 /tmp/jq /usr/local/bin/jq" >&2
	fi
	for c in gum xcodes cmake ninja; do
		command -v "$c" >/dev/null 2>&1 && continue
		echo "  printf '#!/bin/sh\\nexit 0\\n' | sudo tee /usr/local/bin/$c >/dev/null && sudo chmod 755 /usr/local/bin/$c" >&2
	done
	echo >&2
	echo "只出现在存在性检查里，构建过程不会调用它们。" >&2
	exit 1
fi

# Xcode 工具链：dxb 会优先用 DEVELOPER_DIR。
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
[ -n "$DEVELOPER_DIR" ] && [ -d "$DEVELOPER_DIR" ] || die "找不到 Xcode：xcode-select -p 为空"
export DEVELOPER_DIR
iig=$(xcrun --find iig 2>/dev/null || true)
[ -n "$iig" ] || die "xcrun 找不到 iig（Command Line Tools 不提供，必须有完整 Xcode）"
sdk=$(xcrun --show-sdk-version 2>/dev/null || true)
echo "    Xcode:  $DEVELOPER_DIR"
echo "    iig:    $iig"
echo "    SDK:    ${sdk:-未知}"
echo "    jq:     $(jq --version)"
echo "    构建目录: $build_root"

step "准备 darwin-xnu-build @ ${DXB_SHA:0:12}"
if [ ! -d "$dxb_dir/.git" ]; then
	mkdir -p "$build_root"
	git init -q "$dxb_dir"
	git -C "$dxb_dir" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
	git -C "$dxb_dir" checkout -q FETCH_HEAD
else
	head=$(git -C "$dxb_dir" rev-parse HEAD)
	[ "$head" = "$DXB_SHA" ] || die "$dxb_dir 已是别的版本（${head}），删掉重来或换 --dir"
	echo "    复用已有 checkout"
fi

step "拷贝补丁"
patches=$(ls "$repo_dir"/xnu/patches/*.patch | wc -l | tr -d ' ')
scripts=$(ls "$repo_dir"/xnu/patches/*.sh | wc -l | tr -d ' ')
# 清掉上一轮留下的自有补丁（dxb 自带的那些没有数字前缀，必须保留）。
rm -f "$dxb_dir"/patches/[0-9][0-9][0-9][0-9]-*.patch "$dxb_dir"/patches/[0-9][0-9][0-9][0-9]-*.sh
cp "$repo_dir"/xnu/patches/*.patch "$repo_dir"/xnu/patches/*.sh "$dxb_dir/patches/"
echo "    $patches 个 .patch + $scripts 个 .sh"

# 被补丁改过的头文件，导出副本会留在 EXPORT_HDRS 里不更新，security/ 这类
# 目录的 -I 顺序会让它优先于源树，于是新加的宏在编译时"不存在"
# （mac_vfs_subr.c 的 UIO_STACKBUF 就是这样失败的）。删掉对应副本，让构建
# 从已打过补丁的源树重新导出。
if [ -d "$dxb_dir/build/xnu.obj/EXPORT_HDRS" ]; then
	changed_hdrs=$(grep -h '^+++ b/.*\.h$' "$repo_dir"/xnu/patches/*.patch 2>/dev/null |
	    sed 's|^+++ b/||' | sort -u)
	if [ -n "$changed_hdrs" ]; then
		echo "$changed_hdrs" | while read -r h; do
			rm -f "$dxb_dir/build/xnu.obj/EXPORT_HDRS/$h"
		done
		echo "    刷新被补丁修改的导出头文件"
	fi
fi

# CI 的第一步改动：libfirehose_kernel 只出 arm64e，而 POLARIS 内核是普通 arm64。
if ! grep -q 'ARCHS="x86_64 arm64e arm64"' "$dxb_dir/build.sh"; then
	sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' \
		"$dxb_dir/build.sh"
	echo "    已放开 libfirehose_kernel 的 arm64"
else
	echo "    libfirehose_kernel 已含 arm64"
fi

kc=$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')
mc=$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')
# dxb 只按“产物是否存在”决定编不编，删掉这个软链才会重新走 make；
# 它只是产物链接，.o 一个都不动，make 会按 mtime 只重编真正变了的文件。
rm -f "$dxb_dir/build/xnu.obj/kernel.$kc.$mc" "$dxb_dir/build/xnu.obj/kernel.$kc.$mc.link"

if [ "$clean" = 1 ]; then
	if [ -d "$dxb_dir/xnu/.git" ]; then
		echo "    清理: 恢复源码树到 $MACOS_VERSION 原始状态"
		git -C "$dxb_dir/xnu" reset --hard -q
		git -C "$dxb_dir/xnu" clean -fdxq
	fi
	echo "    清理: 删除编译产物（$dxb_dir/build）"
	rm -rf "$dxb_dir/build" "$dxb_dir/.applied-series"
else
	# 增量：只把上一轮应用过的补丁逐条撤回，让 build.sh 重新应用新序列。
	# 这样没被补丁碰过的 .o 全部保留，make 只重编受影响的那批文件。
	if [ -d "$dxb_dir/.applied-series" ]; then
		echo "    增量: 撤回上一轮的补丁（保留编译产物）"
		for p in $(ls "$dxb_dir/.applied-series"/*.patch 2>/dev/null | sort -r); do
			git -C "$dxb_dir/xnu" apply -R --whitespace=nowarn "$p" 2>/dev/null || true
		done
	else
		echo "    增量: 没有上一轮记录，按首次构建处理"
	fi
fi

# stage 脚本（0019/0020/0026）看到目标目录已存在会直接退出，而增量模式下
# 这些目录还在（它们不是补丁产物，撤回补丁不会删掉）。构建期间先挪走。
stage_off=""
# stage 脚本只要看到目标目录存在就拒绝，而补丁 0030 会在 bsd/polaris_hfs 里建
# 两个文件，留下一个没有 core/ 的半成品——此时脚本永远 stage 不进来，
# 0031/0041 随后因为找不到 HFS 源码被跳过，最终 osfmk 链接失败。
if [ -d "$dxb_dir/xnu/bsd/polaris_hfs" ] && [ ! -d "$dxb_dir/xnu/bsd/polaris_hfs/core" ]; then
	rm -rf "$dxb_dir/xnu/bsd/polaris_hfs"
	echo "    清理: 移除不完整的 bsd/polaris_hfs（stage 会重新拉取）"
fi
if [ "$clean" = 0 ] && [ -d "$dxb_dir/xnu/bsd/pthread/polaris_libpthread" ] &&
	[ -d "$dxb_dir/xnu/bsd/polaris_hfs/core" ]; then
	stage_off=$(mktemp -d "${TMPDIR:-/tmp}/stages.XXXXXX")
	mv "$dxb_dir"/patches/*.sh "$stage_off"/
	trap 'mv "$stage_off"/*.sh "$dxb_dir/patches/" 2>/dev/null || true; rmdir "$stage_off" 2>/dev/null || true' EXIT
	echo "    增量: staged 源码已存在，本轮跳过 stage 脚本"
fi

step "构建 $KERNEL_CONFIG / $MACHINE_CONFIG / macOS $MACOS_VERSION"
log="$build_root/build.log"
kdk_dir="/Library/Developer/KDKs/KDK_${MACOS_VERSION}_22G74.kdk"
if [ "$MACOS_VERSION" = "13.5" ] && [ ! -d "$kdk_dir" ]; then
	echo "    注意: $kdk_dir 不存在"
	echo "    构建会先下载 Kernel Debug Kit 13.5（约 1.5 GB）。dxb 的 curl 没有断点续传，"
	echo "    网络一断就得从头再来；想先手动装好，见 docs/KERNEL-BUILD.md。"
fi
if [ ! -d /Library/Developer/PrivateFrameworks/CoreSimulator.framework ]; then
	echo "    注意: 缺 CoreSimulator.framework，xcodebuild 会 abort（先 sudo xcodebuild -runFirstLaunch）"
fi
echo "    日志: $log"
on_error() {
local rc=$?
echo >&2
echo "构建失败（退出码 ${rc}），日志尾部:" >&2
tail -8 "$log" 2>/dev/null | cut -c1-200 | sed 's/^/  /' >&2 || true
echo >&2
echo "完整日志: $log" >&2
exit "$rc"
}

trap on_error ERR
cd "$dxb_dir"
MACOS_VERSION="$MACOS_VERSION" MACHINE_CONFIG="$MACHINE_CONFIG" KERNEL_CONFIG="$KERNEL_CONFIG" \
	MAKEFLAGS="$makeflags" bash ./build.sh 2>&1 | tee "$log"

# dxb 对 apply 失败的补丁只 warning 然后继续，所以“构建成功”不等于补丁都在。
# 但日志里的 Skipping 不能当判据：重跑时 get_xnu() 复用已打过补丁的源码树，
# 于是 86 个补丁全都会 check 失败而被“跳过”（其实早已生效）；dxb 自己那批
# 补丁（iobuffermemd_monterey、skywalk_sonoma、TrustCache…）也本来就该跳过。
# 所以直接验状态：看每个 polaris 补丁留下的标记是否在源码里。
check_marker() {
	local file="$1" needle="$2" what="$3"
	if [ ! -f "$dxb_dir/xnu/$file" ] || ! grep -q "$needle" "$dxb_dir/xnu/$file" 2>/dev/null; then
		die "$what 没生效：$file 里找不到 '$needle'（日志: ${log}）"
	fi
}
check_marker "iokit/Kernel/arm/PolarisDisplay.h"      "POLARIS_DISPLAY_LOGICAL_W"   "0082 显示缩放"
check_marker "osfmk/arm/arm_init.c"                 "polaris_early_init"          "0083 早期帧缓冲"
check_marker "bsd/dev/polaris_keys.c"                 "KEYS_POLARIS_GPIO_PPID"   "0084 按键"
check_marker "bsd/dev/polaris_touch.c"                "touch_polaris_probe"       "0085 触控探针"
check_marker "bsd/dev/polaris_spmi.c"                 "polaris_spmi_polaris_probe"  "0086 电量计探针"
echo "    5 个 polaris 补丁的标记都在"
# 记下这一轮应用过的序列，下次增量构建据此逐条撤回。
rm -rf "$dxb_dir/.applied-series"
mkdir -p "$dxb_dir/.applied-series"
cp "$repo_dir"/xnu/patches/*.patch "$dxb_dir/.applied-series/"

kc=$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')
mc=$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')
kernel="$dxb_dir/build/xnu.obj/kernel.$kc.$mc"
[ -f "$kernel" ] || die "没找到产物 $kernel"

step "完成"
ls -lh "$kernel"
shasum -a 256 "$kernel"

target="$repo_dir/xnu/out/kernel.$kc.$mc"
if [ "$replace" = 1 ]; then
	if [ -f "$target" ]; then
		cp -p "$target" "$target.prev"
		echo "    旧内核已备份为 $(basename "$target").prev"
	fi
	cp "$kernel" "$target"
	echo "    已替换 $target"
else
	echo "    产物留在 $kernel"
	echo "    要替换仓库里的内核，加 --replace"
fi

echo
echo "下一步："
echo "  ./extra/package-boot.sh                 # 打 payload 与 boot 镜像"
echo "  fastboot boot out/shim-polaris-xnu.img"
