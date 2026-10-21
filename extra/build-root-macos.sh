#!/bin/bash
# Build the 16G iOS root image on macOS (native APFS/HFS+, no apfs-fuse).
#
#   sudo extra/build-root-macos.sh
#
# Same layout as tools/mkiosroot.sh: OS root + SystemOS/AppOS cryptexes in
# one case-sensitive journaled HFS+ image, then polaris-root-tweaks.py.
# KEEP_SETUP=1 keeps the Setup Assistant (default: skipped).
# Env: BUILD (work dir), IPSW, SIZE (default 16g).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$REPO/build-root}
IPSW=${IPSW:-$BUILD/iphonex-16.7.16.ipsw}
DMG_DIR=$BUILD/dmg
IMG=$BUILD/ios16-root.img
SIMG=$BUILD/ios16-root.simg
NEW=$BUILD/newroot
SIZE=${SIZE:-16g}
LOG=$BUILD/build-root.log

[ "$(id -u)" = 0 ] || { echo 'error: run as root (sudo extra/build-root-macos.sh)' >&2; exit 1; }
[ -f "$IPSW" ] || { echo "error: IPSW not found: $IPSW" >&2; exit 1; }
mkdir -p "$BUILD" "$DMG_DIR"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date) start root build (macOS) ==="
df -h "$BUILD" | tail -1

mounts=()
cleanup() {
	for m in "${mounts[@]}"; do
		hdiutil detach "$m" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

echo "=== phase 0: extract DMGs ==="
if [ ! -f "$DMG_DIR/087-86698-044.dmg" ] || [ ! -f "$DMG_DIR/087-86593-047.dmg" ] ||
   [ ! -f "$DMG_DIR/087-86715-047.dmg" ]; then
	unzip -o "$IPSW" '087-86698-044.dmg' '087-86593-047.dmg' '087-86715-047.dmg' -d "$DMG_DIR"
fi

attach_ro() {
	local img=$1 dir=$2
	rm -rf "$dir"
	mkdir -p "$dir"
	if ! hdiutil attach -readonly -owners on -nobrowse -mountpoint "$dir" "$img" >/dev/null 2>&1; then
		# The cryptex images are raw APFS, not UDIF.
		hdiutil attach -readonly -owners on -nobrowse -mountpoint "$dir" \
			-imagekey diskimage-class=CRawDiskImage "$img" >/dev/null
	fi
	mounts+=("$dir")
}

echo "=== phase 1: mount IPSW images ==="
attach_ro "$DMG_DIR/087-86698-044.dmg" "$BUILD/mnt-os"
attach_ro "$DMG_DIR/087-86593-047.dmg" "$BUILD/mnt-sysos"
attach_ro "$DMG_DIR/087-86715-047.dmg" "$BUILD/mnt-appos"

osroot=$BUILD/mnt-os
sysroot=$BUILD/mnt-sysos
approot=$BUILD/mnt-appos
[ -d "$osroot/root/System" ] && osroot=$osroot/root
[ -d "$sysroot/root/System" ] && sysroot=$sysroot/root
[ -d "$approot/root/System" ] && approot=$approot/root
[ -d "$osroot/System/Library/xpc" ] || { echo "error: not an iOS OS root: $osroot" >&2; exit 1; }
[ -d "$sysroot/System/Library/Caches/com.apple.dyld" ] || echo "warning: SystemOS has no shared cache"
[ -d "$approot/System/Library" ] || echo "warning: AppOS layout looks unexpected"
uid=$(stat -f '%u' "$osroot/System/Library/xpc/launchd.plist")
[ "$uid" = 0 ] || { echo "error: source mounted without owners (launchd.plist uid=$uid)" >&2; exit 1; }

echo "=== phase 2: create HFS+ image ==="
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" |
	awk '/^\/dev\/disk/{print $1; exit}')
newfs_hfs -s -J -v iOSRoot "$DEV"
hdiutil detach "$DEV" >/dev/null
mkdir -p "$NEW"
hdiutil attach -readwrite -owners on -nobrowse -mountpoint "$NEW" "$IMG" >/dev/null
mounts+=("$NEW")

echo "=== phase 3: copy roots ==="
echo "copying OS root"
rsync -aH --numeric-ids "$osroot/" "$NEW/"
uid=$(stat -f '%u' "$NEW/System/Library/xpc/launchd.plist")
[ "$uid" = 0 ] || { echo "error: copy lost ownership (launchd.plist uid=$uid)" >&2; exit 1; }
uid=$(stat -f '%u' "$NEW/private/var/mobile")
[ "$uid" = 501 ] || { echo "error: copy lost ownership (/private/var/mobile uid=$uid)" >&2; exit 1; }
mkdir -p "$NEW/private/preboot/Cryptexes/OS" "$NEW/private/preboot/Cryptexes/App"
echo "copying SystemOS cryptex"
rsync -aH --numeric-ids "$sysroot/" "$NEW/private/preboot/Cryptexes/OS/"
echo "copying AppOS cryptex"
rsync -aH --numeric-ids "$approot/" "$NEW/private/preboot/Cryptexes/App/"

echo "=== phase 4: hard links ==="
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$NEW/System/Library/Caches/com.apple.dyld"
if [ -d "$NEW/$dsc" ]; then
	for f in "$NEW/$dsc"/*; do
		[ -e "$f" ] || continue
		dst=$NEW/System/Library/Caches/com.apple.dyld/${f##*/}
		[ -e "$dst" ] || ln "$f" "$dst"
	done
fi
for c in OS App; do
	base=$NEW/private/preboot/Cryptexes/$c
	[ -d "$base" ] || continue
	(cd "$base" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		dst=$NEW/$f
		if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
			mkdir -p "$NEW/$(dirname "$f")"
			if [ -L "$base/$f" ]; then
				cp -P "$base/$f" "$dst"
			else
				ln "$base/$f" "$dst" 2>/dev/null || cp -p "$base/$f" "$dst"
			fi
		fi
	done
done

echo "=== phase 5: logd stores and keybag ==="
db=$NEW/private/var/db
mkdir -p "$db/diagnostics/timesync" "$db/uuidtext"
chown 272:272 "$db/diagnostics" "$db/uuidtext" "$db/diagnostics/timesync"
chmod 0751 "$db/diagnostics"
chmod 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	: > "$db/$d/.migrated"
	chown 272:272 "$db/$d/.migrated"
	chmod 0644 "$db/$d/.migrated"
done
mkdir -p "$NEW/private/var/keybags"
chown 0:0 "$NEW/private/var/keybags"
chmod 0700 "$NEW/private/var/keybags"
cat > "$NEW/private/var/keybags/systembag.kb" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>
EOF
chown 0:0 "$NEW/private/var/keybags/systembag.kb"
chmod 0600 "$NEW/private/var/keybags/systembag.kb"

echo "=== phase 6: polaris tweaks ==="
# KEEP_SETUP=1 leaves the Setup Assistant enabled (first boot runs
# purplebuddy); the default marks Setup as finished.
tweak_args=""
[ "${KEEP_SETUP:-0}" = 1 ] && tweak_args="--keep-setup"
python3 "$REPO/tools/polaris-root-tweaks.py" "$NEW" $tweak_args

df -h "$NEW" | tail -1
hdiutil detach "$NEW" >/dev/null

echo "=== phase 7: fsck ==="
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" |
	awk '/^\/dev\/disk/{print $1; exit}')
fsck_hfs -f -y "$DEV" | tail -4 || true
fsck_hfs -f -n "$DEV"
hdiutil detach "$DEV" >/dev/null

echo "=== phase 8: sparse image ==="
rm -f "$SIMG"
python3 "$REPO/tools/raw2simg.py" "$IMG" "$SIMG"
shasum -a 256 "$SIMG" | tee "$SIMG.sha256"
ls -lh "$IMG" "$SIMG"
echo "=== DONE $(date) ==="
echo "flash: fastboot flash userdata $SIMG"
