# Building the iOS root image without root

`tools/build-ios-root-rootless.sh IPSW_DIR OUT.img` makes the same HFS+ image as `tools/build-ios-root.sh`, with no sudo, no loop
mount, no `hfsplus` kernel module and nothing to `apt install`. Host needs (all normal-user): `apfs-fuse` (as before), `mkfs.hfsplus`/`fsck.hfsplus`
(they work on image files), `qemu-system-aarch64`, `tar`, `cpio`, `gzip`, `xz`, `dpkg-deb`, `curl`, `depmod`, `python3`. `--selftest` also wants `fakeroot`.

## How it works (read from source, then observed: see the results)
The only root-only steps of the old build are: mounting HFS+ read-write (kernel driver), `rsync -aH --numeric-ids` into it, `ln`/`install -o`
and `tools/sweet-root-tweaks.py` (chown to 501 etc.). They now run in a tiny aarch64 Linux guest (Debian trixie 6.12.107 arm64 kernel +
busybox-static 1.37, downloaded once to `~/pixelios-artifacts/vm`, sha256 pinned in `tools/rootless/vm.sh`; qemu TCG, no KVM):

| where | step |
|---|---|
| host | `mkfs.hfsplus -s -J -v iOSRoot` on the image file; `apfs-fuse` (as you) mounts the three dmgs |
| host | `tools/ios-root-plan.py` + `tools/sweet-root-tweaks.py --plan`: read the apfs-fuse trees, write `ops.sh` (mkdir/ln/cp -P/mv/chown/chmod/rm) and `overlay.tar` (new and replaced files with explicit uid/gid/mode: launchd.plist, prefs, keybag, .migrated, PNG twins) |
| host | `ios-root-plan.py` scans the three trees, cuts them into ~equal-cost disjoint directory subtrees and GNU-tars them (`--numeric-owner`; the SystemOS root renamed to `private/preboot/Cryptexes/OS`, AppOS to `.../App`) into `shell.tar` (the directories above the cuts) and `s1.tar`..`s6.tar` (`ROOTLESS_STREAMS`, default 6; ~12 GB in total). One reader per apfs-fuse mount at a time: concurrent readers got I/O errors (observed) |
| guest | `/dev/vda` = volume, `vdb` = `shell.tar`, then the streams, last = overlay (raw tars on virtio disks, no network, no 9p). `mount -t hfsplus -o rw,force`, `tar -x -p --numeric-owner` of the shell, then all streams in parallel (one vCPU each; hfsplus serialises on its catalog lock, so more than ~6 gains nothing), `sh -e ops.sh`, `tar -x` overlay, `sync`, `umount`, poweroff |
| host | `fsck.hfsplus -fy` (rewrites the non-ASCII names Linux decomposes), `fsck.hfsplus -fn` must be clean, `tools/check-ios-root.py`, then `OUT.img.partial` -> `OUT.img` and the `.sha256` file written last, atomically |

`sweet-root-tweaks.py` keeps its legacy CLI (`sudo ... MOUNTED_ROOT`); both modes run the same functions through a small file-system class
(`Live` edits in place, `Plan` only reads the source and records ops). `tools/test_sweet_root_tweaks.py` (in the gate's unit step, needs
fakeroot) runs both on a synthetic tree and requires identical listings (mode, uid, gid, type, link target) and file hashes.

Pitfalls found while building it (all fixed): (1) the OS root symlinks some directories into `/System/Cryptexes/OS`, so "does this cryptex
file already exist in the root" must be answered inside the finished volume layout (`Volume` in `ios-root-plan.py`), not on the host mount:
resolving on the host planned 2338 links instead of 63 and `ln` failed after 17 minutes; (2) apfs-fuse breaks under concurrent readers of one mount (the tar threads take a lock per mount); (3) GNU tar `--transform` also rewrites relative
symlink targets unless the flag is `xS`; (4) `tar -p` in busybox keeps setuid/modes; hard links survive across the one-stream payload.

## Commands
- `tools/build-ios-root-rootless.sh --selftest` : whole pipeline on a synthetic tree (owners 0/80/501/272/33, symlinks, hard links, a >100 char path, a stub `heif-convert`), then `check-ios-root.py` on the result and a guest listing checked against explicit expectations. No IPSW needed.
- `tools/build-ios-root-rootless.sh ~/pixelios-artifacts/ipsw /tank/pixelios/ios-root3.img` : full build. `IOS_ROOT_SIZE` (default 16G). Scratch (payload ~12 GB + the 16 GB sparse volume) in a `.rootless-build.*` dir next to OUT.img, or in `$ROOTLESS_SCRATCH` (put it on a fast disk; the image is copied sparse to OUT at the end), removed on every exit including Ctrl-C/TERM (the qemu guest is killed too; `VM_TIMEOUT` seconds, default 7200, is a watchdog).
- `tools/rootless/compare-images.sh A.img B.img [--deep]` : both images read-only in the guest; diffs the sorted `find` listing (mode uid gid type path), the hard link counts and the sha256 of `tools/rootless/keys.txt`. `--deep` hashes every file.
- `tools/rootless/vm.sh fetch|run` : the guest itself. Download dir `PIXELIOS_VM`, mirror `DEBIAN_MIRROR`.

## Results (observed on the dev host, 2026-10-22; Debian 13, 16 cores, no KVM)
- `--selftest`: 8 s (kernel/busybox already downloaded; the first run adds a ~93 MB download + 6 s unpack). Guest RAM 512 MiB.
- Full build of `/tank/pixelios/ios-root-rootless.img` (16 GiB, sha256 `6cf01696...e3e9`): **21 min 33 s** = staging 184 s (apfs-fuse mounts, plan incl. 80 wallpaper PNGs through the real `heif-convert`, 12 GB `payload.tar`) + guest 1029 s (almost all of it extracting the payload; ops.sh 1 s) + fsck/check. 63 cryptex links, 152 ops. Guest RAM 1400 MiB (qemu RSS ~1.5 GiB), one vCPU-bound qemu thread plus tar/apfs-fuse on the host. `check-ios-root.py`: 12 checks pass; `fsck.hfsplus -fn` clean.
- Compared with the sudo-built `/tank/pixelios/ios-root2.img` (`tools/rootless/compare-images.sh`, both attached read-only to the guest):
  all 321,352 listing entries (mode uid gid type path), all 122 hard link counts, the sha256 of the 29 key files (launchd.plist, dyld caches in both places, systembag.kb, migration sentinel, ExtensionKit.plist, prefs, MediaToolbox configs, a wallpaper main.caml, ...) and **the sha256 of all 181,819 regular files are identical**. The first comparison found one difference, `/var` (symlink, root:wheel gid 80): busybox `tar` does not give symlinks their owner; `ios-root-plan.py` now emits `chown -h` for every symlink not owned by 0:0, and the rebuilt image matches. Not compared: timestamps, the volume UUID/dates (they differ by construction).
- Listing one image takes ~7 min in the guest, `--deep` ~20 min per image (4 hashing shards; the single-threaded first attempt was still on image 2 after 45 min; busybox `xargs -P` with `-0` mangles arguments, do not use it). `find` prints "No such file" for the WorkflowKit Thai-named shortcuts in both images (Linux hfsplus decomposes those names differently, the same names fsck rewrites): harmless, identical in both.
- Not done / caveats: the image has not been flashed or booted (this task never touches a phone); the reference is the previous root build, not Apple's tree, so "identical" means identical to what the sudo script produces from the same dmgs.
