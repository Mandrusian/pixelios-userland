#!/usr/bin/env python3
import argparse
import datetime
import json
import os
import pathlib
import stat

def classify(name):
    n = name.lower()
    if n == "dyld" or n.startswith("dyld-") or n.startswith("dyld_") and not "cache" in n:
        return "dyld-loader"
    if n.startswith("dyld_shared_cache") or n.startswith("dyld_cache") or n.endswith(".dsc"):
        return "dyld-shared-cache"
    if n in ("libsystem.b.dylib", "libsystem.dylib", "libsystem_kernel.dylib") or n.startswith("libsystem_") and n.endswith(".dylib"):
        return "libsystem"
    if n == "systemversion.plist" or n == "buildmanifest.plist":
        return "system-version"
    if n.endswith(".ipsw"):
        return "ipsw"
    if n.endswith((".dmg", ".aea", ".hfs", ".img", ".sparseimage")) and any(x in n for x in ("ios", "iphone", "root", "cryptex", "system", "os.")):
        return "image"
    if n.endswith(".zip") and any(x in n for x in ("ios", "iphone", "ipsw", "cryptex")):
        return "archive"
    return None

def main():
    parser = argparse.ArgumentParser(description="Read-only local iOS dyld and userspace asset inventory")
    parser.add_argument("--output", help="New JSON report destination; refuses overwrite")
    parser.add_argument("--max-entries", type=int, default=200000)
    args = parser.parse_args()
    home = pathlib.Path.home()
    roots = [
        (home / "pixelios-artifacts", 9),
        (home / "pixelios-userland", 7),
        (home / "Downloads", 7),
        (home / "pixelios-raven", 4),
    ]
    selected = []
    seen = set()
    visited = 0
    truncated = False
    for root, depth_limit in roots:
        if not root.is_dir() or root.is_symlink():
            continue
        for directory, dirs, files in os.walk(root, topdown=True, followlinks=False):
            depth = len(pathlib.Path(directory).relative_to(root).parts)
            dirs[:] = [d for d in dirs if not (pathlib.Path(directory) / d).is_symlink() and d not in (".git", ".venv", "node_modules", "__pycache__", "Steam", "venv")]
            if depth >= depth_limit:
                dirs.clear()
            visited += len(files) + len(dirs)
            if visited > args.max_entries:
                truncated = True
                break
            for name in files:
                kind = classify(name)
                if not kind:
                    continue
                item = pathlib.Path(directory) / name
                try:
                    st = item.lstat()
                    if not stat.S_ISREG(st.st_mode):
                        continue
                    identity = (st.st_dev, st.st_ino)
                    if identity in seen:
                        continue
                    seen.add(identity)
                    with item.open("rb") as f:
                        magic = f.read(24)
                    selected.append({
                        "kind": kind,
                        "path": str(item),
                        "size_bytes": st.st_size,
                        "magic_hex": magic[:16].hex(),
                        "looks_macho": magic[:4] in (bytes.fromhex("cffaedfe"), bytes.fromhex("cefaedfe"), bytes.fromhex("cafebabe"), bytes.fromhex("bebafeca")),
                        "looks_dyld_cache": magic.startswith(b"dyld_v"),
                    })
                except (PermissionError, OSError):
                    continue
        if truncated:
            break
    report = {
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "roots_checked": [str(r) for r, _ in roots],
        "entries_inspected_approx": visited,
        "truncated": truncated,
        "assets": sorted(selected, key=lambda x: (x["kind"], x["path"])),
    }
    output = pathlib.Path(args.output).expanduser() if args.output else home / "Downloads" / ("PixelIOS-Phase7A-Assets-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    with output.open("x", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    from collections import Counter
    print("=== PIXELIOS PHASE 7A — READ-ONLY USERLAND ASSET INVENTORY ===")
    print("Examined:", visited, "directory entries")
    print("Truncated:", truncated)
    for kind, count in sorted(Counter(x["kind"] for x in selected).items()):
        print(f"{kind}: {count}")
    for item in selected[:70]:
        print(f'{item["kind"]:18} {item["size_bytes"] / 1048576:9.1f} MiB  {item["path"]}')
    if len(selected) > 70:
        print("Additional matches:", len(selected) - 70)
    print("Saved:", output)
    print("No files modified; no phone operation.")

if __name__ == "__main__":
    main()
