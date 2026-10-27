#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$HOME/Downloads"
FINAL="$BASE/PixelIOS-Phase7A-DynamicRoot"
ASSETS="$BASE/PixelIOS-Phase7A-Assets/dist"
SOURCE="$HOME/pixelios-artifacts/work/dsc/raven-hfs-cow-20261025T074420Z-oHbZ6T/ios-root-with-dyld.hfs"
SRC_SHA_INIT=84d845ddbdf96ceae54e8f0242df067ea5c9f0d314fea2be20dae474cb4ef7fe
SRC_SHA_CHILD=a6df8fdabf445ec9825c6edef8c3444babf65ff647231e667f62c7544fdc0050

for cmd in bash python3 sha256sum sudo losetup mount umount mountpoint findmnt truncate mkfs.hfsplus fsck.hfsplus cmp cp mv df awk grep file; do
    command -v "$cmd" >/dev/null || { echo "STOP: Missing $cmd" >&2; exit 1; }
done
[[ -d "$BASE" && -f "$SOURCE" && ! -L "$SOURCE" ]] || { echo 'STOP: Expected source iOS HFS+ root missing or symlinked' >&2; exit 1; }
[[ -f "$ASSETS/launchd" && -f "$ASSETS/pixelios-dynamic" ]] || { echo 'STOP: Verified Phase 7A artifact not found' >&2; exit 1; }
[[ ! -e "$FINAL" && ! -L "$FINAL" ]] || { echo 'STOP: Phase 7A final root already exists; refusing overwrite' >&2; exit 1; }

printf '\n=== VERIFY PHASE 7A SIGNED BINARIES ===\n'
printf '%s  %s\n' "$SRC_SHA_INIT" "$ASSETS/launchd" "$SRC_SHA_CHILD" "$ASSETS/pixelios-dynamic" | sha256sum -c -

FREE_KIB="$(df -Pk "$BASE" | awk 'NR==2 {print $4}')"
[[ "$FREE_KIB" =~ ^[0-9]+$ ]] || { echo 'STOP: Unable to measure disk space' >&2; exit 1; }
(( FREE_KIB >= 5 * 1024 * 1024 )) || { echo 'STOP: Require at least 5 GiB free for separate external root; no cleanup attempted' >&2; exit 1; }

WORK="$(mktemp -d "$BASE/.PixelIOS-Phase7A-Stage-XXXXXXXX")"
SRC_MNT="$WORK/source"
DST_MNT="$WORK/destination"
IMAGE="$WORK/usbroot-phase7a.hfs"
SRC_LOOP=""
DST_LOOP=""
mkdir -p "$SRC_MNT" "$DST_MNT" "$WORK/dist"

cleanup() {
    local rc=$?
    trap - EXIT
    if mountpoint -q "$DST_MNT"; then sudo umount "$DST_MNT" || rc=1; fi
    if mountpoint -q "$SRC_MNT"; then sudo umount "$SRC_MNT" || rc=1; fi
    if [[ -n "$DST_LOOP" ]]; then sudo losetup -d "$DST_LOOP" || rc=1; fi
    if [[ -n "$SRC_LOOP" ]]; then sudo losetup -d "$SRC_LOOP" || rc=1; fi
    if (( rc != 0 )); then printf 'STOP: Preparation failed; safe staging directory retained: %s\n' "$WORK" >&2; fi
    return "$rc"
}
trap cleanup EXIT

cp -- "$ASSETS/launchd" "$ASSETS/pixelios-dynamic" "$WORK/dist/"
cp -- "$ASSETS/SHA256SUMS" "$WORK/dist/"
(
    cd "$WORK"
    sha256sum -c dist/SHA256SUMS
)

printf '\n=== MOUNT ORIGINAL 16-GIB IOS IMAGE READ ONLY ===\n'
sudo -v
SRC_LOOP="$(sudo losetup --read-only --find --show "$SOURCE")"
sudo mount -t hfsplus -o ro,nosuid,nodev,noexec "$SRC_LOOP" "$SRC_MNT"
findmnt -rn -M "$SRC_MNT" -o OPTIONS | tr ',' '\n' | grep -qx ro || { echo 'STOP: Source must be read-only' >&2; exit 1; }

printf '\n=== CREATE NEW INDEPENDENT SPARSE 4-GIB HFS+ ROOT ===\n'
truncate -s 4G "$IMAGE"
mkfs.hfsplus -b 4096 -v PIXELIOS_PHASE7A "$IMAGE"
DST_LOOP="$(sudo losetup --find --show "$IMAGE")"
sudo mount -t hfsplus -o rw,force,nosuid,nodev,noexec "$DST_LOOP" "$DST_MNT"
findmnt -rn -M "$DST_MNT" -o OPTIONS | tr ',' '\n' | grep -qx rw || { echo 'STOP: New target is not writable' >&2; exit 1; }

printf '\n=== COPY REAL DYLD AND ALL 43 CACHE PARTS ===\n'
sudo python3 - "$SRC_MNT" "$DST_MNT" "$WORK/dist" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import sys

src, dst, binaries = map(pathlib.Path, sys.argv[1:4])
src_cache = src / 'System/Library/Caches/com.apple.dyld'
dst_cache = dst / 'System/Library/Caches/com.apple.dyld'
dst_cryptex = dst / 'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
src_dyld = src / 'usr/lib/dyld'
if not src_dyld.is_file() or src_dyld.is_symlink() or not src_cache.is_dir() or src_cache.is_symlink():
    raise SystemExit('STOP: Source dyld/cache location invalid')
with src_dyld.open('rb') as f:
    if f.read(4) != bytes.fromhex('cffaedfe'):
        raise SystemExit('STOP: Source dyld is not a thin ARM64 Mach-O candidate')

entries = sorted((p for p in src_cache.iterdir()
                  if p.name.startswith('dyld_shared_cache_arm64') and not p.name.endswith('.symbols')),
                 key=lambda p: p.name)
if len(entries) != 43 or any(not p.is_file() or p.is_symlink() for p in entries):
    raise SystemExit(f'STOP: Expected 43 regular non-symlink dyld cache files, got {len(entries)}')
parts = set()
for p in entries:
    m = re.fullmatch(r'dyld_shared_cache_arm64\.(\d+)(?:\.dylddata|\.dyldlinkedit)?', p.name)
    if m:
        parts.add(int(m.group(1)))
if parts != set(range(1, 43)):
    raise SystemExit(f'STOP: Numbered shared-cache parts missing: {sorted(set(range(1, 43)) - parts)}')
if not any(p.name == 'dyld_shared_cache_arm64' for p in entries):
    raise SystemExit('STOP: No base dyld cache')
total = sum(p.stat().st_size for p in entries)
if not 2_000_000_000 < total < 3_500_000_000:
    raise SystemExit(f'STOP: Unexpected cache size {total}')

def copy_file(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    if source.stat().st_size != target.stat().st_size:
        raise SystemExit(f'STOP: Size mismatch after copy of {source.name}')

copy_file(src_dyld, dst / 'usr/lib/dyld')
copy_file(binaries / 'launchd', dst / 'sbin/launchd')
copy_file(binaries / 'pixelios-dynamic', dst / 'bin/pixelios-dynamic')
(dst / 'dev').mkdir(parents=True, exist_ok=True)

version = src / 'System/Library/CoreServices/SystemVersion.plist'
if version.is_file() and not version.is_symlink():
    copy_file(version, dst / 'System/Library/CoreServices/SystemVersion.plist')

dst_cryptex.mkdir(parents=True, exist_ok=True)
for i, source in enumerate(entries, 1):
    target = dst_cache / source.name
    copy_file(source, target)
    os.link(target, dst_cryptex / source.name)
    if i % 8 == 0 or i == len(entries):
        print(f'Copied {i}/{len(entries)} cache files ({total/1048576:.1f} MiB total)', flush=True)

for source, target in ((binaries / 'launchd', dst / 'sbin/launchd'),
                       (binaries / 'pixelios-dynamic', dst / 'bin/pixelios-dynamic')):
    def digest(p):
        h = hashlib.sha256()
        with p.open('rb') as f:
            while chunk := f.read(1 << 20):
                h.update(chunk)
        return h.hexdigest()
    if digest(source) != digest(target):
        raise SystemExit(f'STOP: Mach-O changed while installing {target}')
    target.chmod(0o755)

with (dst_cache / 'dyld_shared_cache_arm64').open('rb') as f:
    if not f.read(16).startswith(b'dyld_v'):
        raise SystemExit('STOP: Copied main dyld cache header invalid')

print('PASS: /usr/lib/dyld, /sbin/launchd, /bin/pixelios-dynamic', flush=True)
print('PASS: Full 43-file dyld shared cache with cryptex hardlink mirror', flush=True)
print('NOTE: libSystem cache image index and actual dyld execution remain hardware-unverified', flush=True)
PY

printf '\n=== VERIFY NEW EXTERNAL ROOT AND UNMOUNT ALL LOOPS ===\n'
sudo umount "$DST_MNT"
sudo umount "$SRC_MNT"
sudo losetup -d "$DST_LOOP"
sudo losetup -d "$SRC_LOOP"
DST_LOOP=""
SRC_LOOP=""

fsck.hfsplus -fn "$IMAGE"
ROOT_SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"
printf '%s  %s\n' "$ROOT_SHA" "$FINAL/usbroot-phase7a.hfs" > "$WORK/ROOT_SHA256SUMS"

printf '\n=== PRESERVE KNOWN-GOOD PHASE 6B AND PHASE 6D ROOTS ===\n'
B_ROOT="$BASE/PixelIOS-Phase6B-Root/usbroot-phase6b.hfs"
printf '%s  %s\n' '583ef0c16116b376e69cfcfe3b3ad091a9d1aebae0f5bc930e1d3c72ed66a819' "$B_ROOT" | sha256sum -c -
if [[ -f "$BASE/PixelIOS-Phase6D-Root/ROOT_SHA256SUMS" ]]; then
    sha256sum -c "$BASE/PixelIOS-Phase6D-Root/ROOT_SHA256SUMS"
fi

mv -- "$WORK" "$FINAL"
sha256sum -c "$FINAL/ROOT_SHA256SUMS"

printf '\n=== PHASE 7A SEPARATE ROOT STAGED ===\n'
printf 'Image: %s/usbroot-phase7a.hfs\n' "$FINAL"
printf 'Root SHA256: %s\n' "$ROOT_SHA"
printf 'Physical disk use: '
du -h "$FINAL/usbroot-phase7a.hfs" | awk '{print $1}'
printf 'No fastboot, flash, reboot or internal UFS modification.\n'
printf 'Do not boot yet: Phase 7A kernel/loader safety audit comes next.\n'
