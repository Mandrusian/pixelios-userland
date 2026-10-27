#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "pixelios_launchd_7c12", ROOT / "phase7c12-launchd-inventory.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

MACHO = bytes.fromhex("cffaedfe0c00000100000000") + b"\0" * 128


def fixture(root, included=("notifyd", "logd", "configd")):
    (root / "sbin").mkdir()
    (root / "sbin/launchd").write_bytes(MACHO + b"GENUINE-TEST-FIXTURE")
    (root / "System/Library/xpc").mkdir(parents=True)
    (root / "usr/libexec").mkdir(parents=True)
    jobs = {}
    for name in included:
        path = "usr/libexec/" + name
        (root / path).write_bytes(MACHO + name.encode())
        label = "com.apple." + name
        jobs[label] = {
            "Label": label,
            "ProgramArguments": ["/" + path, "-d"],
            "RunAtLoad": True
        }
    jobs["com.apple.backboardd"] = {
        "Label": "com.apple.backboardd",
        "ProgramArguments": ["/usr/libexec/backboardd"],
        "RunAtLoad": True,
    }
    with (root / mod.PLIST).open("wb") as out:
        plistlib.dump({"LaunchDaemons": jobs, "SomeOriginalMetadata": 42}, out)


def run():
    with tempfile.TemporaryDirectory() as parent:
        home = Path(parent)
        source = home / "source"
        target = home / "target"
        source.mkdir()
        target.mkdir()
        fixture(source)
        plist, report, assets = mod.discover(source)
        assert report["original_launchd_job_count"] == 4
        assert len(report["selected"]) == 3
        assert report["missing"] == ["securityd"]
        assert "com.apple.backboardd" not in report["selected"]
        assert report["copy_bytes"] < mod.MAX_BYTES
        with patch.object(mod.os, "chown", return_value=None):
            mod.stage(source, target, report, assets, plist)
        assert report["staging_verified"]
        assert report["staged_job_count"] == 3
        with (target / mod.PLIST).open("rb") as f:
            new = plistlib.load(f)
        assert new["SomeOriginalMetadata"] == 42
        assert len(new["LaunchDaemons"]) == 3
        assert (target / mod.INIT).read_bytes() == (source / mod.INIT).read_bytes()
        assert (target / "usr/libexec/notifyd").read_bytes() == \
            (source / "usr/libexec/notifyd").read_bytes()
        for item in report["selected"].values():
            assert item["sha256"] == mod.sha256(source / item["program"])
        assert not (target / "usr/libexec/backboardd").exists()
        assert mod.mach_o(target / mod.INIT)
        print("PASS: 7C.1+7C.2 staging genuine-shaped launchd and 3 selected daemons")
        print("PASS: plist semantics preserved, 3/4 jobs selected, others omitted")
        print("PASS: SHA256 checksums and directory safety")

    with tempfile.TemporaryDirectory() as parent:
        home = Path(parent)
        source = home / "source"
        target = home / "target"
        source.mkdir()
        target.mkdir()
        fixture(source, included=("notifyd",))
        plist, report, assets = mod.discover(source)
        try:
            mod.stage(source, target, report, assets, plist)
            raise AssertionError("stage incorrectly accepted one available daemon")
        except RuntimeError as exc:
            assert "fewer than two" in str(exc)
        assert not (target / "sbin/launchd").exists()
        print("PASS: fails closed with insufficient service binaries")

    with tempfile.TemporaryDirectory() as parent:
        home = Path(parent)
        source = home / "source"
        source.mkdir()
        fixture(source)
        (source / "sbin/launchd").unlink()
        (source / "sbin/launchd").symlink_to("/bin/ls")
        try:
            mod.discover(source)
            raise AssertionError("escaped symlink accepted")
        except RuntimeError as exc:
            assert "escapes source root" in str(exc)
        print("PASS: rejects source symlink escaping mounted root")


if __name__ == "__main__":
    run()
