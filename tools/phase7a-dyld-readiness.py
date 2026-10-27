#!/usr/bin/env python3
"""Read-only Phase 7A dyld/ABI/cache readiness check for a mounted iOS 16 HFS+ root."""
import argparse
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import struct

CPU_ARM64 = 0x0100000c
MH_EXECUTE = 2
LC_LOAD_DYLINKER = 0xE
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
DYLIB_CMDS = {0xC, 0x18, 0x1F, 0x80000018, 0x8000001F}
IOS_PLATFORM = 2


def fmt_version(v):
    return f"{v >> 16}.{(v >> 8) & 255}.{v & 255}"


def macho(path):
    result = {"path": str(path), "exists": path.is_file()}
    if not result["exists"]:
        return result
    with path.open("rb") as f:
        hdr = f.read(32)
        if len(hdr) < 32 or hdr[:4] != b"\xcf\xfa\xed\xfe":
            result["error"] = "not a thin little-endian 64-bit Mach-O"
            return result
        _, cpu, subtype, filetype, ncmds, cmds_size, flags, reserved = struct.unpack("<8I", hdr)
        result.update(cpu=f"0x{cpu:08x}", subtype=subtype, filetype=filetype,
                      arm64=(cpu == CPU_ARM64), executable=(filetype == MH_EXECUTE),
                      signature=False, dyld=None, libraries=[], min_os=None, platform=None)
        if not 0 < ncmds < 256 or not 0 < cmds_size < (1 << 20):
            result["error"] = "suspicious Mach-O command count or size"
            return result
        cmds = f.read(cmds_size)
    off = 0
    for _ in range(ncmds):
        if off + 8 > len(cmds):
            result["error"] = "truncated Mach-O load commands"
            return result
        cmd, size = struct.unpack_from("<II", cmds, off)
        if size < 8 or off + size > len(cmds):
            result["error"] = "invalid Mach-O load command"
            return result
        blob = cmds[off:off+size]
        if cmd == LC_CODE_SIGNATURE:
            result["signature"] = True
        elif cmd == LC_BUILD_VERSION and size >= 24:
            platform, minos = struct.unpack_from("<II", blob, 8)
            result["platform"] = platform
            result["min_os"] = fmt_version(minos)
        elif cmd == LC_VERSION_MIN_IPHONEOS and size >= 16:
            result["platform"] = IOS_PLATFORM
            result["min_os"] = fmt_version(struct.unpack_from("<I", blob, 8)[0])
        elif cmd == LC_LOAD_DYLINKER or cmd in DYLIB_CMDS:
            if size >= 12:
                nameoff, = struct.unpack_from("<I", blob, 8)
                if 8 <= nameoff < len(blob):
                    name = blob[nameoff:].split(b"\0")[0].decode("utf-8", "replace")
                    if cmd == LC_LOAD_DYLINKER:
                        result["dyld"] = name
                    else:
                        result["libraries"].append(name)
        off += size
    return result


def scan_cache(folder):
    report = {"path": str(folder), "present": folder.is_dir(),
              "parts": [], "runtime_bytes": 0, "optional_symbol_bytes": 0,
              "missing_part_numbers": [], "main_magic_valid": False}
    if not folder.is_dir():
        return report
    prefix = "dyld_shared_cache_arm64"
    used = set()
    for p in sorted(folder.iterdir()):
        if p.is_symlink() or not p.is_file() or not p.name.startswith(prefix):
            continue
        st = p.stat()
        symbol = p.name.endswith(".symbols")
        if symbol:
            report["optional_symbol_bytes"] += st.st_size
        else:
            report["runtime_bytes"] += st.st_size
        if p.name == prefix:
            with p.open("rb") as f:
                magic = f.read(16)
            report["main_magic_valid"] = magic.startswith(b"dyld_v")
            report["main_magic"] = magic.rstrip(b"\0").decode("ascii", "replace")
        match = re.fullmatch(r"dyld_shared_cache_arm64\.(\d+)(?:\.dylddata|\.dyldlinkedit)?", p.name)
        if match:
            used.add(int(match.group(1)))
        report["parts"].append({"name": p.name, "bytes": st.st_size,
                                "inode": st.st_ino, "symbol_only": symbol})
    if used:
        report["missing_part_numbers"] = sorted(set(range(1, max(used)+1)) - used)
    report["runtime_parts"] = sum(not x["symbol_only"] for x in report["parts"])
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="Mounted read-only HFS+ filesystem")
    ap.add_argument("--dynamic", required=True, help="Phase 7A compiled dynamically linked Mach-O")
    ap.add_argument("--init", required=True, help="Phase 7A static PID1 Mach-O")
    ap.add_argument("--free-space-at", default=None)
    ns = ap.parse_args()
    root = pathlib.Path(ns.root).resolve()
    if not root.is_dir():
        raise SystemExit("STOP: mounted iOS root is not a directory")

    version_path = root / "System/Library/CoreServices/SystemVersion.plist"
    version = {}
    if version_path.is_file():
        with version_path.open("rb") as f:
            version = plistlib.load(f)
    dyld = macho(root / "usr/lib/dyld")
    dynamic = macho(pathlib.Path(ns.dynamic))
    init = macho(pathlib.Path(ns.init))
    main_cache = scan_cache(root / "System/Library/Caches/com.apple.dyld")
    cryptex_cache = scan_cache(root / "System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
    libsystem = root / "usr/lib/libSystem.B.dylib"
    libsystem_exists = libsystem.is_file()
    free_path = ns.free_space_at or str(pathlib.Path(ns.dynamic).parent)
    free = shutil.disk_usage(free_path).free

    requirements = {
        "image_ios16": str(version.get("ProductVersion", "")).startswith("16."),
        "dyld_exists_arm64": bool(dyld.get("arm64") and dyld.get("filetype") == 7),
        "static_init_arm64": bool(init.get("arm64") and init.get("executable") and init.get("dyld") is None),
        "dynamic_child_arm64": bool(dynamic.get("arm64") and dynamic.get("executable") and dynamic.get("signature")),
        "dynamic_child_needs_dyld": dynamic.get("dyld") == "/usr/lib/dyld",
        "dynamic_child_needs_libsystem": any("libSystem" in x for x in dynamic.get("libraries", [])),
        "main_cache_valid": bool(main_cache["main_magic_valid"] and main_cache["runtime_parts"] >= 2),
        "main_cache_parts_contiguous": not main_cache["missing_part_numbers"],
    }
    report = {
        "version": {k: version.get(k) for k in ("ProductVersion", "ProductBuildVersion")},
        "dyld": dyld, "static_init": init, "dynamic_child": dynamic,
        "cache": main_cache,
        "cryptex_cache_summary": {k: cryptex_cache[k] for k in ("present", "runtime_parts", "runtime_bytes", "main_magic_valid")},
        "libsystem_standalone_present": libsystem_exists,
        "libsystem_in_cache": "not verified; requires dyld cache image-index or runtime test",
        "host_free_bytes": free,
        "rough_new_root_space_requirement": main_cache["runtime_bytes"] + 512 * 1024 * 1024,
        "requirements": requirements,
        "read_only": True,
        "next_action": "Prepare a separate HFS+ root after confirming ABI and adequate disk space; no hardware boot performed.",
    }
    print("=== PIXELIOS PHASE 7A — DYLD ROOT COMPATIBILITY ===")
    print("iOS:", report["version"])
    for key in ("dyld", "dynamic_child", "static_init"):
        info = report[key]
        print(key + ":", "ARM64" if info.get("arm64") else "UNVERIFIED", "minOS:", info.get("min_os"),
              "platform:", info.get("platform"), "dyld:", info.get("dyld"))
        if info.get("libraries"):
            print("  libraries:", ", ".join(info["libraries"]))
        if info.get("error"):
            print("  problem:", info["error"])
    print("Main cache:", main_cache["runtime_parts"], "runtime files;",
          round(main_cache["runtime_bytes"]/1048576, 1), "MiB;",
          "missing numbered parts:", main_cache["missing_part_numbers"])
    print("Standalone libSystem.B.dylib:", libsystem_exists)
    print("Host free:", round(free/1073741824, 2), "GiB")
    print("Estimated new small-root needs at least:",
          round(report["rough_new_root_space_requirement"]/1073741824, 2),
          "GiB of physical space, before formatting overhead")
    for k, v in requirements.items():
        print(("PASS" if v else "CHECK") + ":", k)
    print("=== JSON REPORT ===")
    print(json.dumps(report, sort_keys=True, indent=2))
    print("READ-ONLY AUDIT DONE. No new root created; no phone operation.")


if __name__ == "__main__":
    main()
