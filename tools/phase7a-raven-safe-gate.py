#!/usr/bin/env python3
"""Guarded Phase 7A setup/audit/temporary boot. No internal Pixel storage writes."""
import argparse
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HOME = pathlib.Path.home()
BASE = HOME / "Downloads"
STAGE = BASE / "PixelIOS-Phase7A-DynamicRoot"
IMG = STAGE / "usbroot-phase7a.hfs"
DIST = STAGE / "dist"
SAFE = STAGE / "pixelios-phase7a-raven-safe-boot.sh"
PIN = STAGE / "PHASE7A-LAUNCHER-SHA256"
SIXB = BASE / "PixelIOS-Phase6B-Root/pixelios-phase6b-raven-safe-boot.sh"
SIXD = BASE / "PixelIOS-Phase6D-Root/pixelios-phase6d-raven-safe-boot.sh"
SIXD_MANIFEST = BASE / "PixelIOS-Phase6D-Root/ROOT_SHA256SUMS"
KERNEL = BASE / "PixelIOS-Raven-Phase5-Probe-20261027-053452-673647/raven-rootless-phase5.img"
HOST = HOME / "pixelios-raven/tools/usbroot-host.py"
SHA = {
    "7a_root": "d8b38ca2f428a01bfb57b2ca53f5d7c3f93fd29c590d43d2de2d6a98b390981f",
    "6b_root": "583ef0c16116b376e69cfcfe3b3ad091a9d1aebae0f5bc930e1d3c72ed66a819",
    "6b_launcher": "1d63f48c2e660bc20582e93c7ec967bfc3f395308e80d517ddf4c682950aaa5d",
    "init": "84d845ddbdf96ceae54e8f0242df067ea5c9f0d314fea2be20dae474cb4ef7fe",
    "child": "a6df8fdabf445ec9825c6edef8c3444babf65ff647231e667f62c7544fdc0050",
    "kernel": "33a6461baf2c069226d6903bb0a10a8b608f44776551f135511baa2ee85d65ef",
    "host": "fa4f8d25491982da3b25e791bba05029a40086ac086a42a93dbfb54baa8873ae",
}


def fail(message):
    raise SystemExit("STOP: " + message)


def run(*argv):
    print("+", " ".join(str(x) for x in argv), flush=True)
    subprocess.run([str(x) for x in argv], check=True)


def digest(path):
    if not path.is_file() or path.is_symlink():
        fail("missing, invalid or symlinked file: " + str(path))
    h = hashlib.sha256()
    with path.open("rb") as f:
        for part in iter(lambda: f.read(1 << 20), b""):
            h.update(part)
    return h.hexdigest()


def verify(path, expected):
    actual = digest(path)
    if actual != expected:
        fail("hash mismatch: " + str(path) + " expected=" + expected + " actual=" + actual)
    print("PASS SHA256:", path)


def expected_scripts():
    src = SIXB.read_bytes()
    if hashlib.sha256(src).hexdigest() != SHA["6b_launcher"]:
        fail("Phase 6B launcher changed from reviewed baseline")
    if not SIXD_MANIFEST.is_file():
        fail("Phase 6D root manifest missing")
    parts = SIXD_MANIFEST.read_text().split()
    if len(parts) != 2 or len(parts[0]) != 64:
        fail("Phase 6D manifest malformed")
    sh6d = parts[0]
    text7 = src.decode()
    text6 = src.decode()
    replacements = (
        ("PixelIOS-Phase6B-Root", "PixelIOS-Phase7A-DynamicRoot", "PixelIOS-Phase6D-Root", 1),
        ("usbroot-phase6b.hfs", "usbroot-phase7a.hfs", "usbroot-phase6d.hfs", 1),
        (SHA["6b_root"], SHA["7a_root"], sh6d, 1),
        ("PixelIOS-Phase6B-Hardware-", "PixelIOS-Phase7A-Hardware-", "PixelIOS-Phase6D-Hardware-", 1),
        ("phase51-before-phase6b-", "phase51-before-phase7a-", "phase51-before-phase6d-", 1),
        ("phase6b-launcher.log", "phase7a-launcher.log", "phase6d-launcher.log", 1),
        ("PHASE 6B", "PHASE 7A", "PHASE 6D", 2),
    )
    for old, new7, new6, count in replacements:
        if text7.count(old) != count or text6.count(old) != count:
            fail("unexpected proven launcher format for: " + old)
        text7 = text7.replace(old, new7)
        text6 = text6.replace(old, new6)
    if not SIXD.is_file() or SIXD.read_bytes() != text6.encode():
        fail("proven Phase 6D launcher cannot be reproduced from pinned Phase 6B source")
    return text7.encode()


def write_launcher(expected):
    pin = hashlib.sha256(expected).hexdigest()
    if SAFE.exists() or SAFE.is_symlink():
        if SAFE.is_symlink() or SAFE.read_bytes() != expected:
            fail("Phase 7A safe launcher exists with unexpected content")
    else:
        fd = os.open(SAFE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
        with os.fdopen(fd, "wb") as f:
            f.write(expected)
        os.chmod(SAFE, 0o700)
    if PIN.exists() or PIN.is_symlink():
        if PIN.is_symlink() or PIN.read_text().strip() != pin:
            fail("Phase 7A launcher pin is different")
    else:
        fd = os.open(PIN, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(pin + "\n")
    verify(SAFE, pin)
    run("bash", "-n", SAFE)
    print("PASS: Phase 7A launcher is a minimal pinned adaptation of proven Phase 6D safe launcher")


def inspect_readonly():
    root_dir = pathlib.Path(tempfile.mkdtemp(prefix="PixelIOS-Phase7A-Audit-", dir=BASE))
    mount_path = root_dir / "mount"
    mount_path.mkdir()
    loop = None
    mounted = False
    try:
        loop = subprocess.check_output(
            ["sudo", "losetup", "--read-only", "--find", "--show", str(IMG)],
            text=True,
        ).strip()
        run("sudo", "mount", "-t", "hfsplus", "-o", "ro,nosuid,nodev,noexec", loop, mount_path)
        mounted = True
        options = subprocess.check_output(
            ["findmnt", "-rn", "-M", str(mount_path), "-o", "OPTIONS"], text=True
        ).strip().split(",")
        if "ro" not in options:
            fail("mounted root is not read-only")

        check = r"""
import hashlib, pathlib, sys
root, dist = map(pathlib.Path, sys.argv[1:3])
for name in ("usr/lib/dyld", "bin/pixelios-dynamic", "sbin/launchd"):
    p = root / name
    if not p.is_file() or p.is_symlink():
        raise SystemExit("STOP: missing in image: " + name)
def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for data in iter(lambda: f.read(1048576), b""):
            h.update(data)
    return h.hexdigest()
for binary, installed in (("launchd", "sbin/launchd"), ("pixelios-dynamic", "bin/pixelios-dynamic")):
    if sha(dist / binary) != sha(root / installed):
        raise SystemExit("STOP: installed Mach-O changed: " + binary)
base = root / "System/Library/Caches/com.apple.dyld"
mirror = root / "System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
files = sorted(p for p in base.glob("dyld_shared_cache_arm64*") if not p.name.endswith(".symbols"))
if len(files) != 43:
    raise SystemExit(f"STOP: expected 43 cache parts, got {len(files)}")
for p in files:
    q = mirror / p.name
    if not q.is_file() or q.stat().st_size != p.stat().st_size:
        raise SystemExit("STOP: missing cache mirror: " + p.name)
with (base / "dyld_shared_cache_arm64").open("rb") as f:
    if not f.read(16).startswith(b"dyld_v"):
        raise SystemExit("STOP: main dyld cache magic missing")
print("PASS: two verified Mach-O binaries, dyld and 43 mirrored cache parts")
"""
        run("sudo", "python3", "-c", check, mount_path, DIST)
    finally:
        failure = False
        if mounted:
            try:
                run("sudo", "umount", mount_path)
            except subprocess.CalledProcessError:
                failure = True
        if loop:
            try:
                run("sudo", "losetup", "-d", loop)
            except subprocess.CalledProcessError:
                failure = True
        if not failure:
            try:
                mount_path.rmdir()
                root_dir.rmdir()
            except OSError:
                pass
        else:
            fail("HFS+ audit mount could not be safely cleaned up: " + str(root_dir))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("audit", "boot"), nargs="?", default="audit")
    args = parser.parse_args()
    print("=== PIXELIOS PHASE 7A — EXTERNAL DYNAMIC ROOT HARDWARE GATE ===", flush=True)
    verify(IMG, SHA["7a_root"])
    if IMG.stat().st_size != 4294967296:
        fail("root image must be exactly 4 GiB")
    verify(DIST / "launchd", SHA["init"])
    verify(DIST / "pixelios-dynamic", SHA["child"])
    verify(SIXB, SHA["6b_launcher"])
    verify(KERNEL, SHA["kernel"])
    verify(HOST, SHA["host"])
    expected_root = (SHA["7a_root"] + "  " + str(IMG))
    if not (STAGE / "ROOT_SHA256SUMS").is_file() or (STAGE / "ROOT_SHA256SUMS").read_text().strip() != expected_root:
        fail("Phase 7A root checksum manifest differs")
    run("sha256sum", "-c", SIXD_MANIFEST)
    expected = expected_scripts()
    write_launcher(expected)

    print("=== HFS+ OFFLINE READ-ONLY CONTENT INSPECTION ===")
    run("fsck.hfsplus", "-fn", IMG)
    inspect_readonly()
    verify(IMG, SHA["7a_root"])

    print("=== PINNED HISTORIC PHASE 5.1 PREFLIGHT ===")
    run("bash", SAFE, "audit")
    verify(IMG, SHA["7a_root"])
    print("PASS: Phase7A offline audit. No Pixel operation performed so far.")

    if args.mode == "boot":
        print("=== TEMPORARY FASTBOOT BOOT THROUGH EXISTING APPROVED RAVEN LAUNCHER ===")
        run("bash", SAFE, "boot")
    else:
        print("Use the same command with 'boot' only after reviewing the audit. No reboot/flash.")
if __name__ == "__main__":
    main()
