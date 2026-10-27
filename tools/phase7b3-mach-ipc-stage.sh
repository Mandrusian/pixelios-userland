#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$HOME/Downloads"
SOURCE="$BASE/PixelIOS-Phase7A-Completion-Root"
DEST="$BASE/PixelIOS-Phase7B3-MachIPC-Root"
SOURCE_IMG="$SOURCE/usbroot-phase7a.hfs"
RUN=40492667611
CI_COMMIT=a6de0c24b8e30d2aaaf76e246cca42caa9d62c19
CHILD_SHA=843e34fb3c9a5dd5c3b1022ddc6e283d2e65feca4166b0deadb66948a35417e7
INIT_SHA=b151698297940a450dc02249d7457f0022efdf240c25ad166ffb49b606932c3e

for cmd in gh sha256sum sudo losetup mount umount mountpoint findmnt fsck.hfsplus stat file python3 bash cp df awk grep cmp install git; do
    command -v "$cmd" >/dev/null || { printf 'STOP: Missing %s\n' "$cmd" >&2; exit 1; }
done

[[ ! -e "$DEST" && ! -L "$DEST" ]] || { echo 'STOP: Target Mach IPC root already exists' >&2; exit 1; }
[[ -f "$SOURCE_IMG" && ! -L "$SOURCE_IMG" ]] || { echo 'STOP: Proven completion root is missing or symlinked' >&2; exit 1; }
[[ "$(stat -c %s "$SOURCE_IMG")" == 4294967296 ]] || { echo 'STOP: Proven completion root not exactly 4 GiB' >&2; exit 1; }

echo '=== VERIFY PHASE 7B.2 HARDWARE-PROVEN BASELINE ==='
sha256sum -c "$SOURCE/ROOT_SHA256SUMS"
sha256sum -c "$SOURCE/LAUNCHER_SHA256SUMS"
(
    cd "$SOURCE"
    sha256sum -c dist/SHA256SUMS
)
printf '%s  %s\n' "$INIT_SHA" "$SOURCE/dist/launchd" | sha256sum -c -

echo
echo '=== VERIFY PINNED 7B.3 CI SUCCESS ==='
[[ "$(gh api "repos/Mandrusian/pixelios-userland/actions/runs/$RUN" --jq .conclusion)" == success ]] ||
    { echo 'STOP: Phase7B3 CI not successful' >&2; exit 1; }
[[ "$(gh api "repos/Mandrusian/pixelios-userland/actions/runs/$RUN" --jq .head_sha)" == "$CI_COMMIT" ]] ||
    { echo 'STOP: Phase7B3 CI artifact came from an unexpected commit' >&2; exit 1; }

WORK="$(mktemp -d "$BASE/.PixelIOS-Phase7B3-MachIPC-XXXXXXXX")"
mkdir "$WORK/ci" "$WORK/dist" "$WORK/mount"
IMAGE="$WORK/usbroot-phase7b3.hfs"
MNT="$WORK/mount"
LOOP=""
cleanup() {
    local rc=$?
    trap - EXIT
    if mountpoint -q "$MNT"; then sudo umount "$MNT" || rc=1; fi
    if [[ -n "$LOOP" ]]; then sudo losetup -d "$LOOP" || rc=1; fi
    if ((rc)); then echo "STOP: Unfinished test retained at $WORK" >&2; fi
    return "$rc"
}
trap cleanup EXIT

echo
echo '=== DOWNLOAD SIGNED MACH IPC EXECUTABLE ==='
gh run download "$RUN" -R Mandrusian/pixelios-userland \
    -n pixelios-phase7b3-mach-ipc-child -D "$WORK/ci"
printf '%s  %s\n' "$CHILD_SHA" "$WORK/ci/pixelios-dynamic" | sha256sum -c -
file "$WORK/ci/pixelios-dynamic"

echo
echo '=== CLONE COMPLETED HFS+ ROOT WITHOUT DUPLICATING SHARED CACHE ==='
if ! cp --reflink=always --sparse=auto -- "$SOURCE_IMG" "$IMAGE"; then
    echo 'STOP: CoW clone failed; no full multi-gigabyte copy attempted' >&2
    exit 1
fi
OLD_SHA="$(awk 'NR == 1 {print $1}' "$SOURCE/ROOT_SHA256SUMS")"
printf '%s  %s\n' "$OLD_SHA" "$IMAGE" | sha256sum -c -

cp -- "$SOURCE/dist/launchd" "$WORK/dist/launchd"
cp -- "$WORK/ci/pixelios-dynamic" "$WORK/dist/pixelios-dynamic"
(
    cd "$WORK"
    sha256sum dist/launchd dist/pixelios-dynamic > dist/SHA256SUMS
    sha256sum -c dist/SHA256SUMS
)

echo
echo '=== INSTALL ONLY /bin/pixelios-dynamic INTO ISOLATED ROOT ==='
sudo -v
LOOP="$(sudo losetup --find --show "$IMAGE")"
sudo mount -t hfsplus -o rw,force,nosuid,nodev,noexec "$LOOP" "$MNT"
findmnt -rn -M "$MNT" -o OPTIONS | tr ',' '\n' | grep -qx rw

sudo cmp "$SOURCE/dist/launchd" "$MNT/sbin/launchd"
sudo cmp "$SOURCE/dist/pixelios-dynamic" "$MNT/bin/pixelios-dynamic"
sudo test -s "$MNT/usr/lib/dyld"
sudo install -o 0 -g 0 -m 0755 "$WORK/dist/pixelios-dynamic" "$MNT/bin/pixelios-dynamic"
sudo cmp "$WORK/dist/pixelios-dynamic" "$MNT/bin/pixelios-dynamic"
sudo cmp "$WORK/dist/launchd" "$MNT/sbin/launchd"

sudo umount "$MNT"
sudo losetup -d "$LOOP"
LOOP=""

echo
echo '=== CHECK FILESYSTEM AND CREATE PINNED MANIFEST ==='
fsck.hfsplus -fn "$IMAGE"
NEW_SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"
printf '%s  %s\n' "$NEW_SHA" "$DEST/usbroot-phase7b3.hfs" > "$WORK/ROOT_SHA256SUMS"

echo
echo '=== DERIVE NEW LAUNCHER FROM VERIFIED 7B.2 LAUNCHER ==='
python3 - "$SOURCE" "$WORK" "$DEST" "$OLD_SHA" "$NEW_SHA" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

source, stage, destination = map(Path, sys.argv[1:4])
old_sha, new_sha = sys.argv[4:6]
old_path = source / "pixelios-phase7a-completion-raven-safe-boot.sh"
if old_path.is_symlink() or not old_path.is_file():
    raise SystemExit("STOP: Expected audited Phase7B2 launcher unavailable")
old = old_path.read_text()
changes = (
    ("PixelIOS-Phase7A-Completion-Root", "PixelIOS-Phase7B3-MachIPC-Root", 1),
    ("usbroot-phase7a.hfs", "usbroot-phase7b3.hfs", 1),
    (old_sha, new_sha, 1),
    ("PixelIOS-Phase7A-Completion-Hardware-", "PixelIOS-Phase7B3-MachIPC-Hardware-", 1),
    ("phase51-before-phase7a-completion-", "phase51-before-phase7b3-machipc-", 1),
    ("phase7a-completion-launcher.log", "phase7b3-machipc-launcher.log", 1),
)
new = old
for previous, replacement, count in changes:
    if new.count(previous) != count:
        raise SystemExit(f"STOP: Audited launcher diverged: {previous}")
    new = new.replace(previous, replacement)
assert new != old
launcher = stage / "pixelios-phase7b3-machipc-raven-safe-boot.sh"
fd = os.open(launcher, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
with os.fdopen(fd, "w") as out:
    out.write(new)
os.chmod(launcher, 0o700)
pin = hashlib.sha256(new.encode()).hexdigest()
(stage / "LAUNCHER_SHA256SUMS").write_text(pin + "  " + str(destination / launcher.name) + "\n")
print("PASS: Root, hash, report and log paths are the only launcher differences")
print("Launcher SHA256:", pin)
PY
bash -n "$WORK/pixelios-phase7b3-machipc-raven-safe-boot.sh"

echo
echo '=== PRESERVE PHASE7B2 AND FINALIZE PHASE7B3 ==='
sha256sum -c "$SOURCE/ROOT_SHA256SUMS"
mv -- "$WORK" "$DEST"
sha256sum -c "$DEST/ROOT_SHA256SUMS"
sha256sum -c "$DEST/LAUNCHER_SHA256SUMS"
bash "$DEST/pixelios-phase7b3-machipc-raven-safe-boot.sh" audit
echo
echo '=== PHASE 7B.3 MACH IPC ROOT STAGED AND AUDITED ==='
echo "Image: $DEST/usbroot-phase7b3.hfs"
echo "SHA256: $NEW_SHA"
echo 'No phone boot, flash, internal storage access, kernel or existing root modification.'
