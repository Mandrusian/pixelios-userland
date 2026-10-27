#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="$HOME/Downloads"
WORK="${1:-}"
FINAL="$BASE/PixelIOS-Phase7C12-RealLaunchd-Daemons-Root"
PREVIOUS="$BASE/PixelIOS-Phase7C0-ServiceBroker-Root"
OLD_LAUNCHER="$PREVIOUS/pixelios-phase7c0-servicebroker-raven-safe-boot.sh"
IMAGE_NAME="usbroot-phase7c12.hfs"
IMAGE="$WORK/$IMAGE_NAME"
EXPECTED_APPLE_LAUNCHD_SHA="12370e5ee35bf28ae479b6c4b4455f4f4693ab803e37c5eb3032537c18cac61c"
EXPECTED_CHILD_SHA="8479512eacd768ef66255a19afd241b42292be764bea3c7025664c8ef61f4c63"

if [[ -z "$WORK" ]]; then
    echo 'Usage: bash phase7c12-resume-staged-root.sh ~/Downloads/.PixelIOS-Phase7C12-Launchd-XXXXXXXX' >&2
    false
fi

for cmd in bash python3 sha256sum sudo chmod chown git fsck.hfsplus mountpoint losetup awk mv mktemp; do
    command -v "$cmd" >/dev/null || { echo "STOP: $cmd missing" >&2; false; }
done

[[ -d "$WORK" && ! -L "$WORK" && ! -e "$FINAL" && ! -L "$FINAL" ]] || {
    echo 'STOP: Staged directory missing, symlinked or final destination already exists' >&2
    false
}

python3 - "$BASE" "$WORK" "$FINAL" <<'PYPATH'
import pathlib,sys
base,stage,final = map(pathlib.Path,sys.argv[1:4])
if stage.parent.resolve() != base.resolve() or not stage.name.startswith(".PixelIOS-Phase7C12-Launchd-"):
    raise SystemExit("STOP: staging directory is not an expected child of Downloads")
for p in (stage, stage/"dist", stage/"usbroot-phase7c12.hfs"):
    if p.is_symlink():
        raise SystemExit("STOP: symlink in critical staging path: "+str(p))
if final.exists() or final.is_symlink():
    raise SystemExit("STOP: refuses to overwrite existing final destination")
print("PASS: isolated failed staging directory verified")
PYPATH

for path in \
    "$WORK/dist/launchd" "$WORK/dist/pixelios-dynamic" \
    "$WORK/launchd-stage.json" "$WORK/ROOT_SHA256SUMS" "$IMAGE" \
    "$PREVIOUS/ROOT_SHA256SUMS" "$PREVIOUS/LAUNCHER_SHA256SUMS" "$OLD_LAUNCHER"; do
    [[ -f "$path" && ! -L "$path" ]] || {
        echo "STOP: Staging or baseline file missing/symlinked: $path" >&2
        false
    }
done

if [[ -n "$(losetup -j "$IMAGE")" ]]; then
    echo 'STOP: Staged image is still attached to a loop device; leave it untouched' >&2
    false
fi

echo '=== VERIFY HARDWARE-PROVEN 7C.0 BASELINE ==='
sha256sum -c "$PREVIOUS/ROOT_SHA256SUMS"
sha256sum -c "$PREVIOUS/LAUNCHER_SHA256SUMS"
(
    cd "$PREVIOUS"
    sha256sum -c dist/SHA256SUMS
)

echo
echo '=== RECOVER ROOT-OWNED DIST COPY PERMISSIONS ONLY ==='
sudo chown "$(id -u):$(id -g)" "$WORK/dist/launchd" "$WORK/launchd-stage.json"
chmod u+r "$WORK/dist/launchd" "$WORK/launchd-stage.json"

python3 - "$WORK" "$FINAL" "$EXPECTED_APPLE_LAUNCHD_SHA" "$EXPECTED_CHILD_SHA" <<'PYVERIFY'
import hashlib,json,pathlib,sys
work, final = map(pathlib.Path,sys.argv[1:3])
apple_sha, child_sha = sys.argv[3:5]
report=json.loads((work/"launchd-stage.json").read_text())
assert report.get("staging_verified") is True, "no successful staging confirmation"
assert report.get("staged_job_count") == 4, "unexpected daemon count"
assert len(report.get("selected",{})) == 4, "unexpected selection"
assert report.get("source_launchd_sha256") == apple_sha, "Apple launchd source differs"
assert report.get("root_read_only_on_phone") is True, "read-only invariants missing"
for fn,expected in (("dist/launchd",apple_sha),("dist/pixelios-dynamic",child_sha)):
    actual=hashlib.sha256((work/fn).read_bytes()).hexdigest()
    assert actual == expected, f"staged file SHA mismatch: {fn}"
root_manifest=(work/"ROOT_SHA256SUMS").read_text().strip()
tokens=root_manifest.split(maxsplit=1)
assert len(tokens)==2 and tokens[1] == str(final/"usbroot-phase7c12.hfs")
assert len(tokens[0]) == 64
h=hashlib.sha256()
with (work/"usbroot-phase7c12.hfs").open("rb") as f:
    while chunk:=f.read(2*1024*1024):
        h.update(chunk)
assert h.hexdigest() == tokens[0], "staged image SHA mismatch"
print("PASS: hardware-proven image copied correctly; original Apple launchd SHA matches")
print("PASS: four expected service binaries staged; static init replaced only in isolated image")
print("PASS: original iOS full root and original 7C.0 image were never modified")
PYVERIFY

echo
echo '=== VALIDATE INTACT HFS+ IMAGE ==='
fsck.hfsplus -fn "$IMAGE"

echo
echo '=== GENERATE VERIFIED DISTRIBUTION MANIFEST ==='
MANIFEST="$(mktemp "$WORK/.dist-hashes-XXXXXXXX")"
(
    cd "$WORK"
    sha256sum dist/launchd dist/pixelios-dynamic
) > "$MANIFEST"
mv -f -- "$MANIFEST" "$WORK/dist/SHA256SUMS"
(
    cd "$WORK"
    sha256sum -c dist/SHA256SUMS
)

OLD_SHA="$(awk 'NR==1 {print $1}' "$PREVIOUS/ROOT_SHA256SUMS")"
NEW_SHA="$(awk 'NR==1 {print $1}' "$WORK/ROOT_SHA256SUMS")"

echo
echo '=== DERIVE NEW TEMPORARY-BOOT LAUNCHER FROM PINNED 7C.0 ==='
python3 - "$PREVIOUS" "$WORK" "$FINAL" "$OLD_SHA" "$NEW_SHA" <<'PYLAUNCH'
import hashlib
import os
from pathlib import Path
import sys

previous, stage, final = map(Path,sys.argv[1:4])
old_sha,new_sha=sys.argv[4:6]
old_script=previous/"pixelios-phase7c0-servicebroker-raven-safe-boot.sh"
if old_script.is_symlink() or not old_script.is_file():
    raise SystemExit("STOP: original safe launcher missing")
old=old_script.read_text()
changes=(
    ("PixelIOS-Phase7C0-ServiceBroker-Root","PixelIOS-Phase7C12-RealLaunchd-Daemons-Root",1),
    ("usbroot-phase7c0.hfs","usbroot-phase7c12.hfs",1),
    (old_sha,new_sha,1),
    ("PixelIOS-Phase7C0-ServiceBroker-Hardware-","PixelIOS-Phase7C12-RealLaunchd-Hardware-",1),
    ("phase51-before-phase7c0-servicebroker-","phase51-before-phase7c12-reallaunchd-",1),
    ("phase7c0-servicebroker-launcher.log","phase7c12-reallaunchd-launcher.log",1),
)
new=old
for before,after,n in changes:
    if new.count(before)!=n:
        raise SystemExit("STOP: unexpected verified launcher content: "+before)
    new=new.replace(before,after)
target=stage/"pixelios-phase7c12-reallaunchd-raven-safe-boot.sh"
fd=os.open(target,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o700)
with os.fdopen(fd,"w") as f:
    f.write(new)
os.chmod(target,0o700)
digest=hashlib.sha256(new.encode()).hexdigest()
(stage/"LAUNCHER_SHA256SUMS").write_text(digest+"  "+str(final/target.name)+"\n")
print("PASS: launcher SHA256 pinned",digest)
PYLAUNCH

bash -n "$WORK/pixelios-phase7c12-reallaunchd-raven-safe-boot.sh"

echo
echo '=== FINALIZE ISOLATED REAL LAUNCHD + DAEMONS ROOT ==='
sha256sum -c "$PREVIOUS/ROOT_SHA256SUMS"
mv -T -- "$WORK" "$FINAL"
sha256sum -c "$FINAL/ROOT_SHA256SUMS"
sha256sum -c "$FINAL/LAUNCHER_SHA256SUMS"
bash "$FINAL/pixelios-phase7c12-reallaunchd-raven-safe-boot.sh" audit

echo
echo '=== PHASE 7C.1+7C.2 ROOT SUCCESSFULLY RECOVERED AND AUDITED ==='
echo "Image: $FINAL/$IMAGE_NAME"
echo "Report: $FINAL/launchd-stage.json"
echo 'Next: only TEMPORARY fastboot boot; no flash, internal UFS write, or existing-root modification.'
