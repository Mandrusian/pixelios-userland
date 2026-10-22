#!/bin/bash
# Build the iOS root image for the Pixel's userdata (needs root: mounts HFS+/APFS). No sudo? tools/build-ios-root-rootless.sh does the same in a qemu guest.
#
#   tools/build-ios-root.sh IPSW_DIR OUT.img
#
# IPSW_DIR holds the three disk images of the iPhone10,3 16.7.16 (20H392) IPSW:
#   087-86698-044.dmg (OS), 087-86593-047.dmg (SystemOS cryptex), 087-86715-047.dmg (AppOS)
# (tools/remotezip.py can pull just those from Apple's CDN). Needs apfs-fuse (FUSE2 build is
# fine; found via $APFS_FUSE, PATH or ~/pixelios-artifacts/apfs-src/build/apfs-fuse), hfsprogs
# (mkfs.hfsplus, fsck.hfsplus) and the hfsplus kernel module; `tools/mkiosroot.sh --preflight`
# checks the tools and says how to get what is missing. IOS_ROOT_SIZE (default 16G) sets the
# volume size; it must fit the userdata partition (checked below).
# Steps: tools/mkiosroot.sh builds the image, tools/sweet-root-tweaks.py applies the bring-up
# changes inside it, fsck and tools/check-ios-root.py verify. Prints the SHA-256 at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 2 ]] || { sed -n '2,14p' "$0"; exit 2; }
PATH=$PATH:/usr/sbin:/sbin
dir=$(realpath "$1") out=$2 size=${IOS_ROOT_SIZE:-16G}
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
for f in 087-86698-044 087-86593-047 087-86715-047; do
	[[ -s $dir/$f.dmg ]] || { echo "missing $dir/$f.dmg" >&2; exit 1; }
done
tools/mkiosroot.sh --preflight || exit 1
sudo modprobe hfsplus || { echo "error: cannot load the hfsplus kernel module (kernel built without CONFIG_HFSPLUS_FS?)" >&2; exit 1; }

tools/mkiosroot.sh "$dir/087-86698-044.dmg" "$dir/087-86593-047.dmg" "$dir/087-86715-047.dmg" "$out" "$size"

mnt=$(mktemp -d)
trap 'mountpoint -q "$mnt" && sudo umount "$mnt"; rmdir "$mnt" 2>/dev/null || true' EXIT
fsck.hfsplus -fy "$out" >/dev/null || true
sudo mount -t hfsplus -o loop,force "$out" "$mnt"
touch "$mnt/.rwtest" 2>/dev/null || sudo touch "$mnt/.rwtest" || { echo "image mounted read-only" >&2; exit 1; }
sudo rm -f "$mnt/.rwtest"
sudo python3 tools/sweet-root-tweaks.py "$mnt"
sudo umount "$mnt"
fsck.hfsplus -fy "$out" | tail -3 || true
fsck.hfsplus -fn "$out" >/dev/null || { echo "error: $out is not clean after the tweaks: do NOT flash it" >&2; exit 1; }
python3 -I tools/check-ios-root.py "$out" || { echo "error: $out failed tools/check-ios-root.py: do NOT flash it" >&2; exit 1; }
sha256sum "$out" | tee "$out.sha256"
echo "Ready. You run (the phone must be in fastboot and report bluejay):"
echo "  fastboot getvar product            # product: bluejay"
echo "  fastboot flash userdata $out       # erases Android userdata"
