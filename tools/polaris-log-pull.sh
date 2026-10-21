#!/bin/sh
# Read the POLARIS console log (kernel patch 0047) from a phone booted into
# recovery (fastboot boot recovery.img; adb root shell).
#   tools/polaris-log-pull.sh [-s SERIAL] OUT.txt
# Only reads: the last 1025 blocks (4 KiB) of the userdata partition, which is
# where 0047 keeps a 4 MiB ring behind a header block.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	echo "Usage: $(basename "$0") [-s SERIAL] OUT.txt"
	echo "Pull the 4 MiB kernel log ring from userdata via recovery ADB."
	exit 0
fi

# adb: 优先用仓库内置的 macOS 版本。platform-tools 37.x 在 macOS 上启动
# server 时会崩在 IOUSBLib 的接口析构（EXC_GUARD / INVALID_NAME），
# 拉日志前就被 SIGKILL，看起来像是"设备上找不到分区"。内置的是 34.0.5。
here=$(cd "$(dirname "$0")" && pwd)
PT_URL=https://dl.google.com/android/repository/platform-tools_r34.0.5-darwin.zip

usable() { [ -n "$1" ] && [ -x "$1" ] && "$1" version >/dev/null 2>&1; }

ADB_BIN=""
for cand in "$here/platform-tools/adb" "$(command -v adb 2>/dev/null || true)"; do
	if usable "$cand"; then
		ADB_BIN=$cand
		break
	fi
done
if [ -z "$ADB_BIN" ]; then
	echo "没有可用的 adb，下载 platform-tools 34.0.5（约 13 MB）..." >&2
	mkdir -p "$here/platform-tools"
	tmp=$(mktemp -d)
	if curl -fsSL --max-time 300 -o "$tmp/pt.zip" "$PT_URL" &&
	    unzip -q -o -j "$tmp/pt.zip" platform-tools/adb -d "$here/platform-tools"; then
		chmod +x "$here/platform-tools/adb" 2>/dev/null || true
		usable "$here/platform-tools/adb" && ADB_BIN="$here/platform-tools/adb"
	fi
	rm -rf "$tmp"
fi
[ -n "$ADB_BIN" ] || {
	echo "Error: 没有可用的 adb，手动下载:" >&2
	echo "  curl -o /tmp/pt.zip $PT_URL" >&2
	echo "  unzip -o -j /tmp/pt.zip platform-tools/adb -d $here/platform-tools" >&2
	exit 1
}
echo "adb: $ADB_BIN ($("$ADB_BIN" version 2>/dev/null | sed -n 's/^Version //p' | head -1))" >&2

ADB="$ADB_BIN"
if [ "${1:-}" = "-s" ]; then
	shift
	SERIAL=${1:?Error: -s requires a device serial}
	shift
	ADB="$ADB_BIN -s $SERIAL"
fi

out=${1:?usage: polaris-log-pull.sh [-s SERIAL] OUT.txt}

# 一个 server 一旦 claim 了 USB 接口，别的 server 再启动会拿不到
# （LIBUSB_ERROR_ACCESS）然后自杀，客户端看到的是 "didn't ACK"。所以先找
# 现成的 server 复用，找不到才清理其它端口再起。
for port in 5037 5038 5039; do
	if ADB_SERVER_SOCKET=tcp:localhost:$port "$ADB_BIN" devices 2>/dev/null |
	    grep -q 'recovery\|device$'; then
		ADB_SERVER_SOCKET=tcp:localhost:$port
		export ADB_SERVER_SOCKET
		echo "复用已有 adb server: 端口 $port" >&2
		break
	fi
done

if [ -z "${ADB_SERVER_SOCKET:-}" ]; then
	for port in 5037 5038 5039; do
		"$ADB_BIN" -P "$port" kill-server >/dev/null 2>&1 || true
	done
	sleep 1
	if ! $ADB start-server >/tmp/adb-start.log 2>&1; then
		echo "adb server 启动失败:" >&2
		sed 's/^/  /' /tmp/adb-start.log >&2
		echo >&2
		if grep -q LIBUSB_ERROR_ACCESS /tmp/adb-start.log 2>/dev/null; then
			echo "USB 接口被其它进程占着：先把所有 adb 进程结束掉再重试" >&2
		else
			echo "5037 端口冲突或残留 daemon，检查端口占用" >&2
		fi
		exit 1
	fi
fi
# recovery 里 get-state 报的是 "recovery"，sideload 报 "sideload"；都算连上。
case "$($ADB get-state 2>/dev/null | tr -d '\r')" in
device|recovery) ;;
*)
	echo "已连上的设备状态: $($ADB get-state 2>&1 | tr -d '\r')" >&2
	echo "手机需要进 recovery 且 adb devices 能列出它" >&2
	exit 1
	;;
esac

# UFS recoveries disagree on the by-name path, so try the usual ones and
# only then fall back to a find over /dev/block.
dev=$($ADB shell 'for d in \
    /dev/block/by-name/userdata \
    /dev/block/bootdevice/by-name/userdata \
    /dev/block/platform/*/by-name/userdata \
    /dev/block/platform/*/*/by-name/userdata \
    /dev/block/platform/*/by-name/*userdata; do
        [ -e "$d" ] && readlink -f "$d" && exit 0
    done
    find /dev/block -name userdata -type l -o -name userdata -type b 2>/dev/null | head -1' 2>/dev/null | tr -d '\r' | head -1)
if [ -z "$dev" ]; then
	echo "userdata block device not found on connected device" >&2
	echo "看得到的分区:" >&2
	$ADB shell 'ls -d /dev/block/by-name /dev/block/platform/*/by-name 2>/dev/null; ls /dev/block/by-name 2>/dev/null | head -20' >&2 || true
	exit 1
fi
bytes=$($ADB shell blockdev --getsize64 "$dev" | tr -d '\r')
skip=$((bytes / 4096 - 1025))
$ADB exec-out "dd if=$dev bs=4096 skip=$skip count=1025 2>/dev/null" > "$out.bin"
echo "$dev: $bytes bytes, read blocks $skip.. ($(wc -c < "$out.bin" | tr -d ' ') bytes)" >&2
python3 "$(dirname "$0")/polaris-log.py" "$out.bin" "$out"
