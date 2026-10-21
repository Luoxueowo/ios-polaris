#!/bin/bash
# Build the 16G iOS root image (HFS+) for the polaris userdata partition.
# The three source trees (OS / SystemOS / AppOS) are rsynced in parallel.
# Env: WORK (work dir, default $HOME/polaris-build), IPSW, TOOLS.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$REPO/build-root}
IPSW=${IPSW:-$WORK/iphonex.ipsw}
TOOLS=${TOOLS:-$REPO/tools}
export PATH=/usr/local/bin:$PATH
export TMPDIR=${TMPDIR:-$WORK/tmp}
mkdir -p "$TMPDIR" "$WORK/ipsw"
cd "$WORK"
LOG=$WORK/build-root.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

OS=$WORK/ipsw/087-86698-044.dmg
SYS=$WORK/ipsw/087-86593-047.dmg
APP=$WORK/ipsw/087-86715-047.dmg

echo "=== $(date) start root build (parallel copies) ==="
df -h "$WORK" | tail -1

if [ ! -f "$OS" ] || [ ! -f "$SYS" ] || [ ! -f "$APP" ]; then
	echo "=== phase 0: extract DMGs to SSD ($WORK/ipsw) ==="
	unzip -o "$IPSW" "087-86698-044.dmg" "087-86593-047.dmg" "087-86715-047.dmg" -d "$WORK/ipsw"
fi
ls -lh "$WORK/ipsw"

echo "=== phase 1: mkiosroot (3x rsync in parallel) ==="
python3 - "$TOOLS/mkiosroot.sh" "$WORK/mkiosroot-par.sh" <<'PY'
import sys
s = open(sys.argv[1], encoding='utf-8', errors='replace').read().replace('\r\n', '\n')
s = s.replace('sudo rsync -aH --numeric-ids',
              'sudo rsync -aH --numeric-ids --info=progress2')
old = ('copy "$work/os/root" "$work/root"\n'
       'copy "$work/sysos/root" "$work/root/private/preboot/Cryptexes/OS"\n'
       'copy "$work/appos/root" "$work/root/private/preboot/Cryptexes/App"')
new = ('copy "$work/os/root" "$work/root" & p1=$!\n'
       'copy "$work/sysos/root" "$work/root/private/preboot/Cryptexes/OS" & p2=$!\n'
       'copy "$work/appos/root" "$work/root/private/preboot/Cryptexes/App" & p3=$!\n'
       'wait $p1 && wait $p2 && wait $p3')
assert old in s, "copy lines not found in mkiosroot.sh"
open(sys.argv[2], 'w').write(s.replace(old, new))
print("patched mkiosroot: parallel copies + progress2")
PY
chmod +x "$WORK/mkiosroot-par.sh"
"$WORK/mkiosroot-par.sh" "$OS" "$SYS" "$APP" "$WORK/ios16-root.img" 16G

echo "=== phase 2: fsck + root tweaks ==="
fsck.hfsplus -f -y "$WORK/ios16-root.img" | tail -4 || true
mkdir -p "$WORK/iosroot"
mount -t hfsplus -o loop,force "$WORK/ios16-root.img" "$WORK/iosroot"
python3 "$TOOLS/polaris-root-tweaks.py" "$WORK/iosroot"
umount "$WORK/iosroot"
fsck.hfsplus -f -y "$WORK/ios16-root.img" | tail -4 || true

echo "=== phase 3: sparse image ==="
rm -f "$WORK/ios16-root.simg"
if command -v img2simg >/dev/null 2>&1; then
	img2simg "$WORK/ios16-root.img" "$WORK/ios16-root.simg"
else
	python3 "$TOOLS/raw2simg.py" "$WORK/ios16-root.img" "$WORK/ios16-root.simg"
fi
ls -lh "$WORK/ios16-root.img" "$WORK/ios16-root.simg"
sha256sum "$WORK/ios16-root.simg" | tee "$WORK/ios16-root.simg.sha256"

echo "=== DONE $(date) ==="
