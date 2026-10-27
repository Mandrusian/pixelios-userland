#!/usr/bin/env python3
"""Read-only inventory and guarded minimal real-launchd/service staging for Raven.

This is a compatibility experiment, not a full iOS root. No security policy changes.
The caller must mount the genuine user-provided iOS root read-only and an isolated
copy-on-write USBROOT image read-write. Never point --target at the original root.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import stat
import sys
import tempfile

JOB_HINTS = ("notifyd", "logd", "configd", "securityd")
PLIST = "System/Library/xpc/launchd.plist"
INIT = "sbin/launchd"
MAX_BYTES = 350 * 1024 * 1024
RESERVE_BYTES = 128 * 1024 * 1024


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fail(message):
    raise RuntimeError("STOP: " + message)


def regular(root, relative):
    rel = pathlib.PurePosixPath(relative)
    if rel.is_absolute() or ".." in rel.parts or not rel.parts:
        fail("invalid root-relative path: " + relative)
    root_abs = root.resolve(strict=True)
    candidate = root / rel
    resolved = candidate.resolve(strict=True)
    if not resolved.is_relative_to(root_abs):
        fail("file escapes source root: " + relative)
    if not resolved.is_file():
        fail("missing regular file: " + relative)
    if not stat.S_ISREG(resolved.stat().st_mode):
        fail("not a regular file: " + relative)
    return resolved


def mach_o(path):
    with path.open("rb") as f:
        header = f.read(12)
    # MH_MAGIC_64 and CPU_TYPE_ARM64, little endian.
    return len(header) == 12 and header[:4] == bytes.fromhex("cffaedfe") and \
        int.from_bytes(header[4:8], "little") == 0x0100000c


def program_of(job):
    path = job.get("Program")
    if not path:
        args = job.get("ProgramArguments")
        if isinstance(args, (list, tuple)) and args:
            path = args[0]
    if not isinstance(path, str) or not path.startswith("/"):
        return None
    return path.lstrip("/")


def discover(source):
    init = regular(source, INIT)
    if not mach_o(init):
        fail("genuine /sbin/launchd is not ARM64 Mach-O")
    launch_plist = regular(source, PLIST)
    with launch_plist.open("rb") as f:
        plist = plistlib.load(f)
    jobs = plist.get("LaunchDaemons")
    if not isinstance(jobs, dict) or not jobs:
        fail("launchd.plist lacks LaunchDaemons dictionary")
    chosen = {}
    absent = []
    for hint in JOB_HINTS:
        matches = [
            (key, job) for key, job in jobs.items()
            if isinstance(job, dict) and (
                str(job.get("Label", key)).lower() == "com.apple." + hint
                or str(key).lower() == "com.apple." + hint
            )
        ]
        if not matches:
            absent.append(hint)
            continue
        key, job = matches[0]
        exe = program_of(job)
        if exe is None:
            absent.append(hint + " (no executable)")
            continue
        try:
            binary = regular(source, exe)
        except (OSError, RuntimeError):
            absent.append(hint + " (executable missing)")
            continue
        if not mach_o(binary):
            absent.append(hint + " (not ARM64 Mach-O)")
            continue
        chosen[key] = {"label": str(job.get("Label", key)), "program": exe,
                       "size": binary.stat().st_size, "sha256": sha256(binary)}
    assets = {INIT: init, PLIST: launch_plist}
    for item in chosen.values():
        assets[item["program"]] = regular(source, item["program"])
    total = sum(f.stat().st_size for f in assets.values())
    result = {
        "phase": "7C.1+7C.2",
        "goal": "first genuine launchd PID 1 and essential-daemon compatibility boot",
        "hardware_verified": False,
        "source_launchd_sha256": sha256(init),
        "source_launchd_size": init.stat().st_size,
        "original_launchd_job_count": len(jobs),
        "selected": chosen, "missing": absent,
        "copy_bytes": total, "max_copy_bytes": MAX_BYTES,
        "root_read_only_on_phone": True,
        "full_root_required_later": True,
        "warning": (
            "Launchd is genuine, but root is deliberately minimal and read-only. "
            "Daemon startup may fail due to missing writable /var, XPC, or filesystem dependencies. "
            "Never treat CI or staging as hardware success."
        ),
    }
    return plist, result, assets


def checked_destination(root, relative):
    rel = pathlib.PurePosixPath(relative)
    if rel.is_absolute() or ".." in rel.parts:
        fail("invalid destination path: " + relative)
    root_abs = root.resolve(strict=True)
    current = root
    for part in rel.parts[:-1]:
        current = current / part
        if current.is_symlink():
            fail("destination has a symlink directory: " + str(current))
        if current.exists() and not current.is_dir():
            fail("destination parent is not a directory: " + str(current))
    result = root / rel
    if result.is_symlink():
        fail("destination file is a symlink: " + str(result))
    if result.parent.exists() and not result.parent.resolve().is_relative_to(root_abs):
        fail("destination escapes target mount")
    return result


def install_file(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pixelios-stage-", dir=dst.parent)
    try:
        with os.fdopen(fd, "wb") as out, src.open("rb") as inp:
            shutil.copyfileobj(inp, out, 1024 * 1024)
        os.chmod(name, stat.S_IMODE(src.stat().st_mode))
        os.chown(name, src.stat().st_uid, src.stat().st_gid)
        os.replace(name, dst)
        if sha256(src) != sha256(dst):
            fail("file hash differs after installation: " + str(dst))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def stage(source, target, plan, assets, plist):
    if len(plan["selected"]) < 2:
        fail("fewer than two essential daemons available; cannot stage combined test")
    if plan["copy_bytes"] > MAX_BYTES:
        fail("daemon binaries exceed 350 MiB limit for small test root")
    usage = shutil.disk_usage(target)
    if usage.free < plan["copy_bytes"] + RESERVE_BYTES:
        fail("isolated root lacks capacity for launchd, services and safety reserve")
    chosen = set(plan["selected"])
    minimal = dict(plist)
    minimal["LaunchDaemons"] = {
        k: v for k, v in plist["LaunchDaemons"].items() if k in chosen
    }
    # Preserve Apple's plist format in a *diagnostic* copy. No relaxation
    # of entitlements, sandbox, AMFI or trust-cache requirements.
    data = plistlib.dumps(minimal, fmt=plistlib.FMT_BINARY)
    for rel, src in sorted(assets.items()):
        if rel == PLIST:
            continue
        dst = checked_destination(target, rel)
        install_file(src, dst)
    plist_dst = checked_destination(target, PLIST)
    plist_dst.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pixelios-plist-", dir=plist_dst.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.chmod(name, 0o644)
        os.chown(name, 0, 0)
        os.replace(name, plist_dst)
    finally:
        if os.path.exists(name):
            os.unlink(name)
    with plist_dst.open("rb") as f:
        check = plistlib.load(f)
    if len(check["LaunchDaemons"]) != len(chosen):
        fail("staged plist daemon count mismatch")
    for rel, src in assets.items():
        if rel == PLIST:
            continue
        dst = checked_destination(target, rel)
        if sha256(src) != sha256(dst):
            fail("installed file checksum mismatch: " + rel)
    plan["staged_launchd_plist_sha256"] = sha256(plist_dst)
    plan["staged_job_count"] = len(chosen)
    plan["staging_verified"] = True


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--source", type=pathlib.Path, required=True)
    p.add_argument("--target", type=pathlib.Path)
    p.add_argument("--report", type=pathlib.Path)
    args = p.parse_args()
    if not args.source.is_dir() or args.source.is_symlink():
        fail("original iOS source mount not found or symlinked")
    plist, result, assets = discover(args.source)
    print("REAL APPLE LAUNCHD:", result["source_launchd_sha256"])
    print("ORIGINAL JOBS:", result["original_launchd_job_count"])
    for key, job in result["selected"].items():
        print("SERVICE:", key, job["program"], "bytes=", job["size"])
    for name in result["missing"]:
        print("NOT AVAILABLE:", name)
    if args.target:
        if not args.target.is_dir() or args.target.is_symlink():
            fail("isolated destination is not a directory")
        if args.target.resolve() == args.source.resolve():
            fail("source and destination must be separate")
        stage(args.source, args.target, result, assets, plist)
        print("PASS: Genuine launchd +", len(result["selected"]), "daemon binaries staged in isolated root")
    else:
        print("PASS: Original iOS root inspected READ ONLY")
    if args.report:
        if args.report.exists() or args.report.is_symlink():
            fail("report path already exists")
        args.report.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print("NOTE: Hardware still unverified; read-only root may block launchd/daemon runtime")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, plistlib.InvalidFileException, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
