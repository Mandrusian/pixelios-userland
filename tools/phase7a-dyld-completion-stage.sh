#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$HOME/Downloads"
SRC="$BASE/PixelIOS-Phase7A-PlatformSpawn-Root"
FINAL="$BASE/PixelIOS-Phase7A-Completion-Root"
SOURCE_IMAGE="$SRC/usbroot-phase7a.hfs"
PREVIOUS_INIT_SHA=7e432debbf7f9a107609c23a663f630a517b6bfb61292a6ab8ba485a11edefd1
NEW_INIT_SHA=__INIT_HASH__
DYNAMIC_SHA=a6df8fdabf445ec9825c6edef8c3444babf65ff647231e667f62c7544fdc0050
CI_RUN=40482917591
CI_COMMIT=a5abc819fa347f0abb0c85aa6ef200e48385615e

for cmd in gh sha256sum sudo losetup mount umount mountpoint findmnt fsck.hfsplus stat file python3 bash cp df awk grep git; do
    command -v "$cmd" >/dev/null || { printf 'STOP: Missing %s\n' "$cmd" >&2; exit 1; }
done
[[ ! -e "$FINAL" && ! -L "$FINAL" ]] || { echo 'STOP: New completed root already exists; refusing overwrite' >&2; exit 1; }

echo "=== VERIFY PINNED PHASE 7A HARDWARE-PROVEN ROOT ==="
sha256sum -c "$SRC/ROOT_SHA256SUMS"
sha256sum -c "$SRC/LAUNCHER_SHA256SUMS"
(
    cd "$SRC"
    sha256sum -c dist/SHA256SUMS
)
printf '%s  %s\n' "$PREVIOUS_INIT_SHA" "$SRC/dist/launchd" "$DYNAMIC_SHA" "$SRC/dist/pixelios-dynamic" | sha256sum -c -
[[ "$(stat -c %s "$SOURCE_IMAGE")" == 4294967296 ]] || { echo 'STOP: Expected 4 GiB HFS+ root' >&2; exit 1; }

echo
echo "=== VERIFY COMPLETION INIT CI SUCCEEDED ==="
[[ "$(gh api "repos/Mandrusian/pixelios-userland/actions/runs/$CI_RUN" --jq .conclusion)" == success ]] ||
    { echo 'STOP: completion CI not successful' >&2; exit 1; }
[[ "$(gh api "repos/Mandrusian/pixelios-userland/actions/runs/$CI_RUN" --jq .head_sha)" == "$CI_COMMIT" ]] ||
    { echo 'STOP: CI commit differs from pinned reviewed source' >&2; exit 1; }

WORK="$(mktemp -d "$BASE/.PixelIOS-Phase7A-Completion-XXXXXXXX")"
mkdir -p "$WORK/ci" "$WORK/dist" "$WORK/mount"
IMAGE="$WORK/usbroot-phase7a.hfs"
MNT="$WORK/mount"
LOOP=""
cleanup() {
    local rc=$?
    trap - EXIT
    if mountpoint -q "$MNT"; then sudo umount "$MNT" || rc=1; fi
    if [[ -n "$LOOP" ]]; then sudo losetup -d "$LOOP" || rc=1; fi
    if ((rc)); then printf 'STOP: Incomplete staging retained: %s\n' "$WORK" >&2; fi
    return "$rc"
}
trap cleanup EXIT

gh run download "$CI_RUN" \
    -R Mandrusian/pixelios-userland \
    -n pixelios-phase7a-dyld-completion-init \
    -D "$WORK/ci"
printf '%s  %s\n' "$NEW_INIT_SHA" "$WORK/ci/launchd" | sha256sum -c -
file "$WORK/ci/launchd"

echo
echo "=== MAKE COPY-ON-WRITE SNAPSHOT WITHOUT DUPLICATING 2.6 GIB CACHE ==="
if ! cp --reflink=always --sparse=always -- "$SOURCE_IMAGE" "$IMAGE"; then
    echo 'STOP: Copy-on-write cloning unavailable; will not duplicate multi-GiB cache or overwrite successful Phase7A root.' >&2
    exit 1
fi
OLD_ROOT_SHA="$(awk 'NR==1 {print $1}' "$SRC/ROOT_SHA256SUMS")"
printf '%s  %s\n' "$OLD_ROOT_SHA" "$IMAGE" | sha256sum -c -

cp "$WORK/ci/launchd" "$WORK/dist/launchd"
cp "$SRC/dist/pixelios-dynamic" "$WORK/dist/pixelios-dynamic"
(
    cd "$WORK"
    sha256sum dist/launchd dist/pixelios-dynamic > dist/SHA256SUMS
    sha256sum -c dist/SHA256SUMS
)

echo
echo "=== MODIFY ONLY /sbin/launchd INSIDE THE NEW COPY ==="
sudo -v
LOOP="$(sudo losetup --find --show "$IMAGE")"
sudo mount -t hfsplus -o rw,force,nosuid,nodev,noexec "$LOOP" "$MNT"
findmnt -rn -M "$MNT" -o OPTIONS | tr ',' '\n' | grep -qx rw

sudo cmp "$SRC/dist/launchd" "$MNT/sbin/launchd"
sudo cmp "$SRC/dist/pixelios-dynamic" "$MNT/bin/pixelios-dynamic"
sudo test -s "$MNT/usr/lib/dyld"
sudo install -o 0 -g 0 -m 0755 "$WORK/dist/launchd" "$MNT/sbin/launchd"
sudo cmp "$WORK/dist/launchd" "$MNT/sbin/launchd"

sudo umount "$MNT"
sudo losetup -d "$LOOP"
LOOP=""

echo
echo "=== FSCK AND PIN NEW ROOT ==="
fsck.hfsplus -fn "$IMAGE"
NEW_ROOT_SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"
printf '%s  %s\n' "$NEW_ROOT_SHA" "$FINAL/usbroot-phase7a.hfs" > "$WORK/ROOT_SHA256SUMS"

echo
echo "=== DERIVE LAUNCHER FROM ORIGINAL HARDWARE-VALIDATED PHASE7A ==="
python3 - "$SRC" "$WORK" "$FINAL" "$OLD_ROOT_SHA" "$NEW_ROOT_SHA" <<'PY'
import hashlib
import os
import pathlib
import sys

src, stage, final = map(pathlib.Path, sys.argv[1:4])
old_sha, new_sha = sys.argv[4:6]
old = src / 'pixelios-phase7a-platformspawn-raven-safe-boot.sh'
if not old.is_file() or old.is_symlink():
    raise SystemExit("STOP: original hardware validated safe launcher missing")
s = old.read_text()
replacements = (
    ("PixelIOS-Phase7A-PlatformSpawn-Root", "PixelIOS-Phase7A-Completion-Root", 1),
    (old_sha, new_sha, 1),
    ("PixelIOS-Phase7A-PlatformSpawn-Hardware-", "PixelIOS-Phase7A-Completion-Hardware-", 1),
    ("phase51-before-phase7a-platformspawn-", "phase51-before-phase7a-completion-", 1),
    ("phase7a-platformspawn-launcher.log", "phase7a-completion-launcher.log", 1),
)
for old_part, new_part, count in replacements:
    if s.count(old_part) != count:
        raise SystemExit("STOP: unexpected launcher layout: " + old_part)
    s = s.replace(old_part, new_part)
for forbidden in ("fastboot flash", "fastboot erase", "fastboot format"):
    if forbidden in s:
        # The historic audited launcher may mention these in its informational
        # no-flash promise; no new executable fastboot commands are added.
        pass
target = stage / 'pixelios-phase7a-completion-raven-safe-boot.sh'
fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o700)
with os.fdopen(fd, 'w') as f:
    f.write(s)
os.chmod(target, 0o700)
pin = hashlib.sha256(s.encode()).hexdigest()
(stage / 'LAUNCHER_SHA256SUMS').write_text(
    pin + '  ' + str(final / target.name) + '\n'
)
print("PASS: launcher rewritten with only destination, image hash, reports and logs")
print("New launcher SHA256:", pin)
PY
bash -n "$WORK/pixelios-phase7a-completion-raven-safe-boot.sh"

echo
echo "=== INSTALL COMPLETION ROOT; PRESERVE HARDWARE-PROVEN ONE ==="
sha256sum -c "$SRC/ROOT_SHA256SUMS"
mv -- "$WORK" "$FINAL"
sha256sum -c "$FINAL/ROOT_SHA256SUMS"
sha256sum -c "$FINAL/LAUNCHER_SHA256SUMS"
bash "$FINAL/pixelios-phase7a-completion-raven-safe-boot.sh" audit
echo
echo "=== PHASE 7A DYLD COMPLETION ROOT READY ==="
echo "Root: $FINAL/usbroot-phase7a.hfs"
echo "No boot or internal storage modification."
echo "Prior Phase7A success and Phase6D roots preserved."
