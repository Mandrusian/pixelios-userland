#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MODE="${1:-audit}"
if [[ "$MODE" != audit && "$MODE" != stage ]]; then
    echo 'Usage: phase7c12-launchd-and-daemons-stage.sh audit|stage' >&2
    false
fi

BASE="$HOME/Downloads"
PREVIOUS="$BASE/PixelIOS-Phase7C0-ServiceBroker-Root"
FINAL="$BASE/PixelIOS-Phase7C12-RealLaunchd-Daemons-Root"
SOURCE="${PIXELIOS_FULL_ROOT:-$HOME/pixelios-artifacts/work/dsc/raven-hfs-cow-20261025T074420Z-oHbZ6T/ios-root-with-dyld.hfs}"
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
AUDITOR="$SCRIPT_DIR/phase7c12-launchd-inventory.py"
BASE_IMAGE="$PREVIOUS/usbroot-phase7c0.hfs"
NEW_IMAGE_NAME="usbroot-phase7c12.hfs"
CI_SOURCE_SHA="8479512eacd768ef66255a19afd241b42292be764bea3c7025664c8ef61f4c63"
BASE_INIT_SHA="b151698297940a450dc02249d7457f0022efdf240c25ad166ffb49b606932c3e"

for cmd in sha256sum sudo losetup mount umount mountpoint findmnt stat file python3 bash cp df awk cmp install git fsck.hfsplus; do
    command -v "$cmd" >/dev/null || { printf 'STOP: required command not found: %s\n' "$cmd" >&2; false; }
done

[[ -f "$AUDITOR" && ! -L "$AUDITOR" ]] || { echo 'STOP: verified audit Python companion missing' >&2; false; }
[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || { echo "STOP: Full iOS source image missing: $SOURCE" >&2; false; }
[[ -f "$BASE_IMAGE" && ! -L "$BASE_IMAGE" ]] || { echo "STOP: Hardware-verified Phase7C0 baseline missing: $BASE_IMAGE" >&2; false; }
[[ "$(stat -c %s "$BASE_IMAGE")" == 4294967296 ]] || { echo 'STOP: baseline is not exactly 4 GiB' >&2; false; }

echo '=== VERIFY THE EXISTING HARDWARE-PROVEN 7C.0 ROOT ==='
sha256sum -c "$PREVIOUS/ROOT_SHA256SUMS"
sha256sum -c "$PREVIOUS/LAUNCHER_SHA256SUMS"
(
    cd "$PREVIOUS"
    sha256sum -c dist/SHA256SUMS
)
printf '%s  %s\n' "$BASE_INIT_SHA" "$PREVIOUS/dist/launchd" \
   "$CI_SOURCE_SHA" "$PREVIOUS/dist/pixelios-dynamic" | sha256sum -c -

if [[ "$MODE" == stage && ( -e "$FINAL" || -L "$FINAL" ) ]]; then
    echo 'STOP: target real-launchd test root already exists; refusing overwrite' >&2
    false
fi

WORK="$(mktemp -d "$BASE/.PixelIOS-Phase7C12-Launchd-XXXXXXXX")"
SRC_MNT="$WORK/source"
DST_MNT="$WORK/target"
IMAGE="$WORK/$NEW_IMAGE_NAME"
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
    if (( rc )); then printf 'STOP: staging preserved for inspection: %s\n' "$WORK" >&2; fi
    return "$rc"
}
trap cleanup EXIT

echo
echo '=== MOUNT ORIGINAL FULL IOS ROOT STRICTLY READ ONLY ==='
sudo -v
SRC_LOOP="$(sudo losetup --read-only --find --show "$SOURCE")"
sudo mount -t hfsplus -o ro,nosuid,nodev,noexec "$SRC_LOOP" "$SRC_MNT"
findmnt -rn -M "$SRC_MNT" -o OPTIONS | tr ',' '\n' | grep -qx ro

echo
echo '=== REAL LAUNCHD + ESSENTIAL DAEMON INVENTORY ==='
sudo python3 "$AUDITOR" --source "$SRC_MNT" --report "$WORK/launchd-audit.json"

if [[ "$MODE" == audit ]]; then
    sudo umount "$SRC_MNT"
    sudo losetup -d "$SRC_LOOP"
    SRC_LOOP=""
    echo
    echo '=== COMBINED PHASE 7C.1+7C.2 AUDIT COMPLETE ==='
    echo "Report: $WORK/launchd-audit.json"
    echo "No filesystem image was modified. To stage: bash $0 stage"
else
    echo
    echo '=== CREATE A DISTINCT COPY-ON-WRITE 4-GIB DIAGNOSTIC ROOT ==='
    if ! cp --reflink=always --sparse=auto -- "$BASE_IMAGE" "$IMAGE"; then
        echo 'STOP: CoW cloning unavailable; not duplicating full cache' >&2
        false
    fi
    OLD_SHA="$(awk 'NR==1 {print $1}' "$PREVIOUS/ROOT_SHA256SUMS")"
    printf '%s  %s\n' "$OLD_SHA" "$IMAGE" | sha256sum -c -

    DST_LOOP="$(sudo losetup --find --show "$IMAGE")"
    sudo mount -t hfsplus -o rw,force,nosuid,nodev,noexec "$DST_LOOP" "$DST_MNT"
    findmnt -rn -M "$DST_MNT" -o OPTIONS | tr ',' '\n' | grep -qx rw
    sudo cmp "$PREVIOUS/dist/launchd" "$DST_MNT/sbin/launchd"
    sudo cmp "$PREVIOUS/dist/pixelios-dynamic" "$DST_MNT/bin/pixelios-dynamic"
    sudo test -s "$DST_MNT/usr/lib/dyld"

    echo
    echo '=== STAGE REAL APPLE LAUNCHD AND ESSENTIAL DAEMONS TOGETHER ==='
    sudo python3 "$AUDITOR" --source "$SRC_MNT" --target "$DST_MNT" \
         --report "$WORK/launchd-stage.json"
    sudo test -s "$DST_MNT/sbin/launchd"
    sudo cmp "$PREVIOUS/dist/pixelios-dynamic" "$DST_MNT/bin/pixelios-dynamic"
    sudo install -o "$(id -u)" -g "$(id -g)" -m 0755 \
        "$DST_MNT/sbin/launchd" "$WORK/dist/launchd"
    cp -- "$PREVIOUS/dist/pixelios-dynamic" "$WORK/dist/pixelios-dynamic"
    python3 - "$WORK/dist/launchd" "$WORK/launchd-stage.json" <<'PYVERIFY'
import hashlib
import json
from pathlib import Path
import sys
binary = Path(sys.argv[1])
report = json.loads(Path(sys.argv[2]).read_text())
assert report.get("staging_verified"), "launchd staging report incomplete"
assert hashlib.sha256(binary.read_bytes()).hexdigest() == report["source_launchd_sha256"], "launchd copy differs from Apple source"
print("PASS: Privately staged launchd is readable, with identical bytes to genuine Apple source")
PYVERIFY

    sudo umount "$DST_MNT"
    sudo umount "$SRC_MNT"
    sudo losetup -d "$DST_LOOP"
    sudo losetup -d "$SRC_LOOP"
    DST_LOOP=""
    SRC_LOOP=""

    echo
    echo '=== VERIFY NEW IMAGE AND GENERATE SHA-256 MANIFESTS ==='
    fsck.hfsplus -fn "$IMAGE"
    ROOT_SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"
    printf '%s  %s\n' "$ROOT_SHA" "$FINAL/$NEW_IMAGE_NAME" > "$WORK/ROOT_SHA256SUMS"
    (
        cd "$WORK"
        sha256sum dist/launchd dist/pixelios-dynamic > dist/SHA256SUMS
        sha256sum -c dist/SHA256SUMS
    )

    echo
    echo '=== DERIVE NO-FLASH LAUNCHER FROM THE VERIFIED 7C.0 LAUNCHER ==='
    python3 - "$PREVIOUS" "$WORK" "$FINAL" "$OLD_SHA" "$ROOT_SHA" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

previous, stage, final = map(Path, sys.argv[1:4])
old_sha, new_sha = sys.argv[4:6]
old_script = previous / "pixelios-phase7c0-servicebroker-raven-safe-boot.sh"
if not old_script.is_file() or old_script.is_symlink():
    raise SystemExit("STOP: original safe launcher missing")
old = old_script.read_text()
changes = (
    ("PixelIOS-Phase7C0-ServiceBroker-Root", "PixelIOS-Phase7C12-RealLaunchd-Daemons-Root", 1),
    ("usbroot-phase7c0.hfs", "usbroot-phase7c12.hfs", 1),
    (old_sha, new_sha, 1),
    ("PixelIOS-Phase7C0-ServiceBroker-Hardware-", "PixelIOS-Phase7C12-RealLaunchd-Hardware-", 1),
    ("phase51-before-phase7c0-servicebroker-", "phase51-before-phase7c12-reallaunchd-", 1),
    ("phase7c0-servicebroker-launcher.log", "phase7c12-reallaunchd-launcher.log", 1),
)
new = old
for before, after, count in changes:
    if new.count(before) != count:
        raise SystemExit("STOP: audited launcher differs: " + before)
    new = new.replace(before, after)
target = stage / "pixelios-phase7c12-reallaunchd-raven-safe-boot.sh"
fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o700)
with os.fdopen(fd, "w") as stream:
    stream.write(new)
os.chmod(target, 0o700)
digest = hashlib.sha256(new.encode()).hexdigest()
(stage / "LAUNCHER_SHA256SUMS").write_text(digest + "  " + str(final / target.name) + "\n")
print("PASS: new launcher derived from approved no-flash launcher")
PY
    bash -n "$WORK/pixelios-phase7c12-reallaunchd-raven-safe-boot.sh"
    sha256sum -c "$PREVIOUS/ROOT_SHA256SUMS"
    mv -- "$WORK" "$FINAL"
    sha256sum -c "$FINAL/ROOT_SHA256SUMS"
    sha256sum -c "$FINAL/LAUNCHER_SHA256SUMS"
    bash "$FINAL/pixelios-phase7c12-reallaunchd-raven-safe-boot.sh" audit
    echo
    echo '=== COMBINED 7C.1+7C.2 DIAGNOSTIC ROOT STAGED ==='
    echo "Root: $FINAL/$NEW_IMAGE_NAME"
    echo "Manifest: $FINAL/launchd-stage.json"
    echo 'Genuine launchd + selected essential daemons staged; NOT hardware-verified.'
    echo 'WARNING: Launchd may need writable /var and other system services absent from this root.'
    echo 'No fastboot invocation, internal phone write, or original image modification.'
fi
