# Requirements: building the iOS root (pixelios-userland)

Tags: *observed* = measured on the maintainer's machine (Debian 13, 16 cores, 24 GB RAM, no KVM, 2026-10-22); *read* = read from the scripts.

## Host
- Linux x86_64 with FUSE (`/dev/fuse`, `fusermount3` or `fusermount`). *Read* from `tools/build-ios-root-rootless.sh` (preflight).
- Normal user, no root, for the **rootless** build. The classic `tools/build-ios-root.sh` needs root and the `hfsplus` kernel module.
- Tools on `PATH` (the rootless preflight checks them and tells you what is missing): `apfs-fuse` (build it yourself, no Debian package: `sudo apt install fuse libfuse-dev cmake g++ git zlib1g-dev libbz2-dev`, then
  `git clone --recursive https://github.com/sgan81/apfs-fuse`), `mkfs.hfsplus` and `fsck.hfsplus` (Debian package `hfsprogs`, installs into `/usr/sbin`),
  `qemu-system-aarch64`, `tar`, `cpio`, `gzip`, `xz`, `dpkg-deb`, `curl`, `depmod`, `modprobe`, `python3`; `--selftest` also needs `fakeroot`.
  Optional: `heif-convert` (`libheif-examples`) to give the stock wallpapers PNG copies (without it the wallpapers show only their background gradient).
- Disk: about 12 GB of payload tars plus the 16 GB sparse volume, plus the three IPSW disk images (several GB), plus about 100 MB for the guest kernel and busybox. Keep 40 GB free. *Observed*: `/tank/pixelios` on a ZFS pool; scratch next to the output image.
- RAM: the qemu guest gets 1400 MiB (selftest 512 MiB); the host side is tar and apfs-fuse. *Observed* peak not measured; the machine had 10 GB available.
- Network: the first run downloads a Debian arm64 kernel and busybox (about 93 MB, sha256 pinned in `tools/rootless/vm.sh`).

## Inputs you must obtain (not in git, Apple's files)
- The iPhone X (iPhone10,3) iOS 16.7.16 (20H392) restore image: only three disk images are used, `087-86698-044.dmg` (OS), `087-86593-047.dmg` (SystemOS cryptex), `087-86715-047.dmg` (AppOS).
  `tools/remotezip.py URL PATTERN OUTDIR` (in [pixelios-kernel](https://github.com/PixOS-Project/pixelios-kernel), fetched from ios-sweet there) extracts single members from the IPSW over HTTP range requests. Put the three files in one directory (`IPSW_DIR`).

## Steps
```sh
tools/build-ios-root-rootless.sh --selftest          # about 8 s once the guest files are downloaded
tools/build-ios-root-rootless.sh IPSW_DIR OUT.img    # IOS_ROOT_SIZE=16G by default
python3 tools/check-ios-root.py OUT.img              # host check, 12 checks
```
*Observed*: the full rootless build took 599 s (10 min) on the maintainer's machine with six parallel extraction streams; 21 min 33 s before that change.
The result is not bit-identical between runs (HFS+ timestamps); `tools/rootless/compare-images.sh A.img B.img` compares listings, hard-link counts and file hashes.

Flashing the image to a phone is done from the kernel repo (`tools/fflash-userdata.sh`, it erases `userdata`). Read its SAFETY notes first.
