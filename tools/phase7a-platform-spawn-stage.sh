#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$HOME/Downloads"
OLD="$BASE/PixelIOS-Phase7A-DynamicRoot"
FINAL="$BASE/PixelIOS-Phase7A-PlatformSpawn-Root"
REF6B="$BASE/PixelIOS-Phase6B-Root/pixelios-phase6b-raven-safe-boot.sh"
ROOT_OLD_SHA=d8b38ca2f428a01bfb57b2ca53f5d7c3f93fd29c590d43d2de2d6a98b390981f
INIT_OLD_SHA=84d845ddbdf96ceae54e8f0242df067ea5c9f0d314fea2be20dae474cb4ef7fe
INIT_NEW_SHA=7e432debbf7f9a107609c23a663f630a517b6bfb61292a6ab8ba485a11edefd1
CHILD_SHA=a6df8fdabf445ec9825c6edef8c3444babf65ff647231e667f62c7544fdc0050
REF_SHA=1d63f48c2e660bc20582e93c7ec967bfc3f395308e80d517ddf4c682950aaa5d

for cmd in bash gh sha256sum python3 sudo losetup mount umount mountpoint findmnt fsck.hfsplus cmp cp mv df awk git file stat; do
    command -v "$cmd" >/dev/null || { echo "STOP: missing $cmd" >&2; exit 1; }
done

[[ ! -e "$FINAL" && ! -L "$FINAL" ]] || { echo 'STOP: Separate new root already exists; refusing overwrite' >&2; exit 1; }

echo "=== VERIFY ORIGINAL HARDWARE AND PHASE7A BASELINES ==="
printf '%s  %s\n' \
    "$ROOT_OLD_SHA" "$OLD/usbroot-phase7a.hfs" \
    "$INIT_OLD_SHA" "$OLD/dist/launchd" \
    "$CHILD_SHA" "$OLD/dist/pixelios-dynamic" \
    "$REF_SHA" "$REF6B" | sha256sum -c -
sha256sum -c "$BASE/PixelIOS-Phase6D-Root/ROOT_SHA256SUMS"
( cd "$OLD" && sha256sum -c dist/SHA256SUMS )

FREE_KIB="$(df -Pk "$BASE" | awk 'NR==2 {print $4}')"
[[ "$FREE_KIB" =~ ^[0-9]+$ ]] || { echo 'STOP: Unable to check free space' >&2; exit 1; }
(( FREE_KIB >= 4 * 1024 * 1024 )) || { echo 'STOP: Need >= 4 GiB free before copying separate root; no files removed' >&2; exit 1; }

STAGE="$(mktemp -d "$BASE/.PixelIOS-Phase7A-PlatformSpawn-XXXXXXXX")"
DIST="$STAGE/dist"
IMAGE="$STAGE/usbroot-phase7a.hfs"
MNT="$STAGE/mnt"
LOOP=""
mkdir "$DIST" "$MNT"

cleanup() {
    local rc=$?
    trap - EXIT
    if mountpoint -q "$MNT"; then sudo umount "$MNT" || rc=1; fi
    if [[ -n "$LOOP" ]]; then sudo losetup -d "$LOOP" || rc=1; fi
    if (( rc != 0 )); then printf 'STOP: Staging preserved at %s\n' "$STAGE" >&2; fi
    return "$rc"
}
trap cleanup EXIT

echo
echo "=== DOWNLOAD SIGNED IOS PLATFORM SPAWN PID1 ==="

gh run download 40479983927 \
    -R Mandrusian/pixelios-userland \
    -n pixelios-phase7a-platform-spawn-init \
    -D "$DIST"

printf '%s  %s\n' "$INIT_NEW_SHA" "$DIST/launchd" | sha256sum -c -
cp -- "$OLD/dist/pixelios-dynamic" "$DIST/pixelios-dynamic"
printf '%s  %s\n' "$CHILD_SHA" "$DIST/pixelios-dynamic" | sha256sum -c -

(
    cd "$STAGE"
    sha256sum dist/launchd dist/pixelios-dynamic > dist/SHA256SUMS
    sha256sum -c dist/SHA256SUMS
)

echo
echo "=== COPY THE PREVIOUS 4-GIB HFS+ IMAGE (PRESERVE ORIGINAL) ==="

cp --reflink=auto --sparse=always -- "$OLD/usbroot-phase7a.hfs" "$IMAGE"
printf '%s  %s\n' "$ROOT_OLD_SHA" "$IMAGE" | sha256sum -c -

echo
echo "=== INSTALL ONLY NEW STATIC PID1 IN THE COPY ==="

sudo -v
LOOP="$(sudo losetup --find --show "$IMAGE")"
sudo mount -t hfsplus -o rw,force,nosuid,nodev,noexec "$LOOP" "$MNT"
findmnt -rn -M "$MNT" -o OPTIONS | tr ',' '\n' | grep -qx rw || { echo 'STOP: new image mount is not RW' >&2; exit 1; }

sudo test -s "$MNT/usr/lib/dyld"
sudo test -s "$MNT/bin/pixelios-dynamic"
sudo cmp "$OLD/dist/pixelios-dynamic" "$MNT/bin/pixelios-dynamic"
sudo install -o 0 -g 0 -m 0755 "$DIST/launchd" "$MNT/sbin/launchd"
sudo cmp "$DIST/launchd" "$MNT/sbin/launchd"

sudo umount "$MNT"
sudo losetup -d "$LOOP"
LOOP=""

echo
echo "=== FSCK AND PIN NEW PHASE7A ROOT HASH ==="

fsck.hfsplus -fn "$IMAGE"
NEW_SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"
printf '%s  %s\n' "$NEW_SHA" "$FINAL/usbroot-phase7a.hfs" > "$STAGE/ROOT_SHA256SUMS"

echo
echo "=== REPRODUCE VERIFIED 4-GIB LAUNCHER, UPDATE ROOT+SHA ONLY ==="

python3 - "$REF6B" "$OLD/pixelios-phase7a-raven-safe-boot.sh" \
    "$STAGE/pixelios-phase7a-platformspawn-raven-safe-boot.sh" "$NEW_SHA" <<'PY'
import hashlib
import os
import pathlib
import sys

ref, oldlauncher, output = (pathlib.Path(s) for s in sys.argv[1:4])
root_sha = sys.argv[4]
if len(root_sha) != 64 or any(c not in '0123456789abcdef' for c in root_sha):
    raise SystemExit("STOP: Invalid new root hash")
original = ref.read_bytes()
assert hashlib.sha256(original).hexdigest() == "1d63f48c2e660bc20582e93c7ec967bfc3f395308e80d517ddf4c682950aaa5d"

def replace_exact(text, a, b, count=1):
    if text.count(a) != count:
        raise SystemExit(f"STOP: Reviewed launcher source differs: {a}")
    return text.replace(a, b)

old = original.decode()
for a,b,n in (
    ("PixelIOS-Phase6B-Root","PixelIOS-Phase7A-DynamicRoot",1),
    ("usbroot-phase6b.hfs","usbroot-phase7a.hfs",1),
    ("583ef0c16116b376e69cfcfe3b3ad091a9d1aebae0f5bc930e1d3c72ed66a819",
     "d8b38ca2f428a01bfb57b2ca53f5d7c3f93fd29c590d43d2de2d6a98b390981f",1),
    ("PixelIOS-Phase6B-Hardware-","PixelIOS-Phase7A-Hardware-",1),
    ("phase51-before-phase6b-","phase51-before-phase7a-",1),
    ("phase6b-launcher.log","phase7a-launcher.log",1),
    ("PHASE 6B","PHASE 7A",2),
    ('[[ "$(stat -c %s "$ROOT_IMAGE")" == 67108864 ]]',
     '[[ "$(stat -c %s "$ROOT_IMAGE")" == 4294967296 ]]',1),
):
    old = replace_exact(old,a,b,n)
expected_old=old.encode()
if not oldlauncher.is_file() or oldlauncher.is_symlink() or oldlauncher.read_bytes()!=expected_old:
    raise SystemExit("STOP: Current Phase7A 4-GiB launcher is not the reviewed source")

new=old
for a,b,n in (
    ("PixelIOS-Phase7A-DynamicRoot","PixelIOS-Phase7A-PlatformSpawn-Root",1),
    ("d8b38ca2f428a01bfb57b2ca53f5d7c3f93fd29c590d43d2de2d6a98b390981f",root_sha,1),
    ("PixelIOS-Phase7A-Hardware-","PixelIOS-Phase7A-PlatformSpawn-Hardware-",1),
    ("phase51-before-phase7a-","phase51-before-phase7a-platformspawn-",1),
    ("phase7a-launcher.log","phase7a-platformspawn-launcher.log",1),
):
    new=replace_exact(new,a,b,n)

fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o700)
with os.fdopen(fd,'wb') as f:f.write(new.encode())
os.chmod(output,0o700)
print("PASS: reproduced verified earlier Phase7A 4-GiB launcher")
print("PASS: new launcher only changes root directory, image SHA and report names")
print("New launcher SHA256:",hashlib.sha256(new.encode()).hexdigest())
PY

bash -n "$STAGE/pixelios-phase7a-platformspawn-raven-safe-boot.sh"
sha256sum "$STAGE/pixelios-phase7a-platformspawn-raven-safe-boot.sh" \
    > "$STAGE/LAUNCHER_SHA256SUMS"

echo
echo "=== CONFIRM EARLIER IMAGES STILL MATCH ==="

printf '%s  %s\n' "$ROOT_OLD_SHA" "$OLD/usbroot-phase7a.hfs" | sha256sum -c -
sha256sum -c "$BASE/PixelIOS-Phase6D-Root/ROOT_SHA256SUMS"
mv -- "$STAGE" "$FINAL"
sha256sum -c "$FINAL/ROOT_SHA256SUMS"
sha256sum -c "$FINAL/LAUNCHER_SHA256SUMS"

echo
echo "=== RUN OFFLINE PHASE 7A PLATFORM-SPAWN PREFLIGHT ==="
bash "$FINAL/pixelios-phase7a-platformspawn-raven-safe-boot.sh" audit

echo
echo "=== PHASE 7A PLATFORM SPAWN ROOT READY ==="
echo "New root: $FINAL/usbroot-phase7a.hfs"
echo "New SHA: $NEW_SHA"
echo "Previous Phase7A, Phase6D and older images preserved."
echo "No fastboot, flash, reboot or internal UFS operation."
