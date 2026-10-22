#!/bin/bash
# Build the iOS root image for the Pixel's userdata WITHOUT root (no sudo, no loop mount, no hfsplus module, no apt).
#
#   tools/build-ios-root-rootless.sh IPSW_DIR OUT.img        full build (IOS_ROOT_SIZE, default 16G, sets the volume size)
#   tools/build-ios-root-rootless.sh --selftest              the whole pipeline on a tiny synthetic tree (~2 min, no IPSW)
#
# Same input and result as tools/build-ios-root.sh (which needs sudo). The root-only parts run in a tiny aarch64
# Linux guest under qemu-system-aarch64 (TCG, no KVM; tools/rootless/vm.sh, Debian arm64 kernel + busybox downloaded
# once into ~/pixelios-artifacts/vm and sha256-pinned):
#   host, as you:  mkfs.hfsplus -> OUT.img.partial; apfs-fuse mounts the three IPSW dmgs; GNU tar streams the trees
#                  mkiosroot.sh copies (OS root, cryptexes under private/preboot/Cryptexes/{OS,App}) into shell.tar + s1..sN.tar;
#                  tools/ios-root-plan.py + tools/sweet-root-tweaks.py --plan turn the root-only steps (hard links, chown,
#                  plist edits) into ops.sh + overlay.tar, reading the apfs-fuse tree only
#   guest:         /dev/vda = the volume, vdb = shell.tar, then s1..sN.tar, last overlay.tar; mounts HFS+ (-o rw,force), extracts the
#                  shell, then the streams in parallel, runs ops.sh, extracts the overlay, syncs, powers off
#   host again:    fsck.hfsplus (clean required), tools/check-ios-root.py, then OUT.img.partial -> OUT.img and the sha256 file
#                  (written last, atomically)
# RAM: the guest gets 1400 MiB (selftest 512), the host side is tar + apfs-fuse. Scratch: the payload tars (~the size of
# the unpacked tree, ~8 GB) next to OUT.img. Compare two images (e.g. against the sudo build):
# tools/rootless/compare-images.sh A.img B.img.
set -euo pipefail
cd "$(dirname "$0")/.."
PATH=$PATH:/usr/sbin:/sbin
self=$(realpath "$0")
vm=tools/rootless/vm.sh
PREBOOT=private/preboot/Cryptexes

# Every tool this needs, with what to do about it. apfs-fuse: $APFS_FUSE, PATH, <artifacts>/apfs-src/build/apfs-fuse.
preflight() {
	local bad=0 c t
	apfs=
	for c in "${APFS_FUSE:-}" "$(command -v apfs-fuse || true)" "${PIXELIOS_ARTIFACTS:-$HOME/pixelios-artifacts}/apfs-src/build/apfs-fuse"; do
		if [[ -n $c && -f $c && -x $c ]]; then apfs=$(realpath "$c"); break; fi
	done
	[[ -n $apfs ]] || { bad=1; echo "error: apfs-fuse not found (APFS_FUSE=/path/to/apfs-fuse; see tools/mkiosroot.sh --preflight)" >&2; }
	for t in mkfs.hfsplus fsck.hfsplus qemu-system-aarch64 tar head cpio gzip xz dpkg-deb curl depmod modprobe python3; do
		command -v "$t" >/dev/null || { bad=1; echo "error: $t not found" >&2; }
	done
	[[ -e /dev/fuse ]] || { bad=1; echo "error: no /dev/fuse" >&2; }
	[[ -n $(command -v fusermount3 || command -v fusermount || true) ]] || { bad=1; echo "error: fusermount missing" >&2; }
	return $bad
}

# --stage OS SYSOS APPOS DIR [STREAMS]: shell.tar, s1.tar..sN.tar (the payload, extracted in parallel), ops.sh, overlay.tar.
# Reads the trees only; the selftest runs it under fakeroot.
if [[ ${1:-} == --stage ]]; then
	exec python3 -I tools/ios-root-plan.py "$2" "$3" "$4" "$5" "${6:-${ROOTLESS_STREAMS:-6}}"
fi

# VOLUME RAM_MIB WORKDIR: guest build, then the checks; leaves the volume fsck-clean and checked.
finish() {
	local vol=$1 ram=$2 d=$3 maxmib=${4:-}
	local t0=$SECONDS p=()
	for f in "$d"/shell.tar "$d"/s[0-9]*.tar; do p+=("ro:$f"); done
	# one vCPU per stream (+1): the guest kernel's hfsplus work is the cost, and it scales with parallel tars
	"$vm" run build -f "ops.sh=$d/ops.sh" -m "$ram" -s $((${#p[@]})) "$vol" "${p[@]}" "ro:$d/overlay.tar"
	echo "   guest: $((SECONDS - t0)) s"; t0=$SECONDS
	# Linux hfsplus decomposes some non-ASCII names differently from Apple's tables: let fsck_hfs rewrite them (as mkiosroot.sh)
	fsck.hfsplus -f -y "$vol" | grep -v 'Illegal name' | tail -3 || true
	fsck.hfsplus -f -n "$vol" >/dev/null || { echo "error: $vol is not clean after the build: do NOT flash it" >&2; return 1; }
	echo "   fsck: $((SECONDS - t0)) s"; t0=$SECONDS
	python3 -I tools/check-ios-root.py "$vol" ${maxmib:+--max-mib "$maxmib"} || { echo "error: $vol failed tools/check-ios-root.py: do NOT flash it" >&2; return 1; }
}

if [[ ${1:-} == --selftest ]]; then
	command -v fakeroot >/dev/null || { echo "error: --selftest needs fakeroot (it fakes the 501/272 owners of the synthetic tree)" >&2; exit 1; }
	preflight || exit 1
	t=$(mktemp -d)
	trap 'rm -rf "$t"' EXIT
	SECONDS=0
	mkdir "$t/bin"
	printf '#!/bin/sh\nprintf "PNG of %%s\\n" "$(basename "$1")" >"$2"\n' >"$t/bin/heif-convert"
	chmod +x "$t/bin/heif-convert"
	# fakeroot: the synthetic tree has root/501/272/33 owners; --stage reads them like it reads the apfs-fuse mount
	PATH=$t/bin:$PATH fakeroot -- bash -c 'python3 -I tools/rootless/selftest.py tree "$1" && "$2" --stage "$1/os/root" "$1/sysos/root" "$1/appos/root" "$1/stage" 3' _ "$t" "$self"
	echo "selftest: staged in ${SECONDS}s"
	truncate -s 128M "$t/vol.img"
	mkfs.hfsplus -s -J -v iOSRoot "$t/vol.img" >/dev/null
	finish "$t/vol.img" 512 "$t/stage" 1024
	truncate -s 8M "$t/report.bin"
	python3 -I tools/rootless/selftest.py keys >"$t/keys.txt"
	"$vm" run list -f "keys.txt=$t/keys.txt" -m 512 "ro:$t/vol.img" "$t/report.bin" >/dev/null
	python3 -I tools/rootless/selftest.py verify "$t/report.bin"
	echo "selftest PASS in ${SECONDS}s"
	exit 0
fi

[[ $# -eq 2 ]] || { sed -n '2,6p' "$0"; exit 2; }
dir=$(realpath "$1") out=$2 size=${IOS_ROOT_SIZE:-16G}
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
for f in 087-86698-044 087-86593-047 087-86715-047; do
	[[ -s $dir/$f.dmg ]] || { echo "missing $dir/$f.dmg" >&2; exit 1; }
done
preflight || exit 1
$vm fetch
SECONDS=0

work=$(mktemp -d -p "${ROOTLESS_SCRATCH:-$(dirname "$out")}" .rootless-build.XXXXXX)
fuse_um=$(command -v fusermount3 || command -v fusermount)
mounts=()
done_ok=0
part=$work/vol.img
cleanup() {
	local m busy=0
	pkill -TERM -P $$ 2>/dev/null || true                    # a tar / apfs-fuse / vm.sh still running (Ctrl-C, TERM)
	[[ $done_ok == 1 ]] || rm -f "$out.partial" "$out.sha256.tmp"
	for m in "${mounts[@]}"; do
		mountpoint -q "$m" && { "$fuse_um" -u "$m" 2>/dev/null || "$fuse_um" -uz "$m" 2>/dev/null || true; }
		mountpoint -q "$m" && busy=1
	done
	if [[ $busy == 0 ]]; then rm -rf "$work"; else echo "still mounted under $work: left in place" >&2; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# apfs-fuse splits its options on ',' (iPhone10,3 paths): use links; it only parses UDIF when the name ends in .dmg.
for n in os:087-86698-044 sysos:087-86593-047 appos:087-86715-047; do
	ln -s "$dir/${n#*:}.dmg" "$work/${n%%:*}.dmg"
	mkdir "$work/${n%%:*}"
	"$apfs" "$work/${n%%:*}.dmg" "$work/${n%%:*}"
	mounts+=("$work/${n%%:*}")
done
echo "== staging (tar of the three trees + plan), $SECONDS s"
"$self" --stage "$work/os/root" "$work/sysos/root" "$work/appos/root" "$work/stage"
for m in "${mounts[@]}"; do "$fuse_um" -u "$m"; done          # free apfs-fuse's caches before the guest runs
mounts=()
echo "== guest build, $SECONDS s"
truncate -s "$size" "$part"
mkfs.hfsplus -s -J -v iOSRoot "$part"
finish "$part" 1400 "$work/stage"
# The sha256 is of the scratch copy (read in parallel with the copy): a bad copy is then caught when the image is flashed.
cp --sparse=always "$part" "$out.partial" &                  # scratch may be another (faster) file system
sum=$(sha256sum "$part")
wait $!
mv "$out.partial" "$out"
done_ok=1
# the sha file last and atomically: never an empty or half-written one
printf '%s  %s\n' "${sum%% *}" "$out" >"$out.sha256.tmp"
mv "$out.sha256.tmp" "$out.sha256"
cat "$out.sha256"
echo "built in ${SECONDS}s"
echo "Ready. You run (the phone must be in fastboot and report bluejay):"
echo "  fastboot getvar product            # product: bluejay"
echo "  fastboot flash userdata $out       # erases Android userdata"
