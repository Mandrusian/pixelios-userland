#!/bin/bash
# The tiny aarch64 Linux guest of tools/build-ios-root-rootless.sh. Needs no root: qemu-system-aarch64 in TCG mode
# (no KVM), a Debian arm64 kernel and busybox-static downloaded and unpacked as a normal user.
#
#   vm.sh fetch                                   download + sha256-verify + unpack the kernel/busybox (once)
#   vm.sh run MODE [-f NAME=FILE]... [-m MIB] [-s SMP] DISK...
#       MODE   build | list (see tools/rootless/guest-init; list: the last DISK receives the report)
#       -f     put FILE into the initramfs as /NAME (ops.sh, keys.txt)
#       DISK   a raw file, attached in order as /dev/vda, vdb, ...; "ro:FILE" attaches it read-only
#   exit status 0 only if the guest printed IOSROOT-GUEST-OK
#
# Everything lives in $PIXELIOS_VM (default ~/pixelios-artifacts/vm), outside git. RAM: -m (default 1280 MiB).
set -euo pipefail
here=$(dirname "$(realpath "$0")")
VM=${PIXELIOS_VM:-$HOME/pixelios-artifacts/vm}
MIRROR=${DEBIAN_MIRROR:-https://deb.debian.org/debian}

# Debian 13 (trixie) point release 13.7; pinned. If a pool file is gone, bump these (apt-cache policy or Packages.xz).
KVER=6.12.107+deb13-arm64
KDEB=pool/main/l/linux-signed-arm64/linux-image-${KVER}_6.12.107-1_arm64.deb
KSHA=20c92f3f97dd466e0400a6fcb792bde85af842fbb5e8b471370065e3de9d9fc9
BDEB=pool/main/b/busybox/busybox-static_1.37.0-6+b9_arm64.deb
BSHA=c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c
MODULES="drivers/block/virtio_blk fs/nls/nls_utf8 fs/hfsplus/hfsplus"   # + dependencies (depmod)

fetch() {
	[[ -s $VM/vmlinuz && -x $VM/busybox && -s $VM/modules.list ]] && return 0
	command -v depmod >/dev/null || PATH=$PATH:/usr/sbin:/sbin
	mkdir -p "$VM/dl"
	local deb sha
	for p in "$KDEB:$KSHA" "$BDEB:$BSHA"; do
		deb=$VM/dl/$(basename "${p%%:*}") sha=${p##*:}
		[[ -s $deb ]] || { curl -fsSL -o "$deb.part" "$MIRROR/${p%%:*}" && mv -f "$deb.part" "$deb"; }
		echo "$sha  $deb" | sha256sum -c --quiet - || { echo "error: $deb does not match the pinned sha256" >&2; rm -f "$deb"; exit 1; }
	done
	local x=$VM/x
	rm -rf "$x" "$VM/modules"
	mkdir -p "$x/k" "$x/b"
	dpkg-deb -x "$VM/dl/$(basename "$KDEB")" "$x/k"
	dpkg-deb -x "$VM/dl/$(basename "$BDEB")" "$x/b"
	cp "$x/k/boot/vmlinuz-$KVER" "$VM/vmlinuz"
	install -m 755 "$x/b/usr/bin/busybox" "$VM/busybox"
	# depmod wants <base>/lib/modules/<ver>; the deb has usr/lib/modules (merged /usr)
	ln -sfn usr/lib "$x/k/lib"
	/sbin/depmod -b "$x/k" "$KVER" 2>/dev/null || PATH=$PATH:/usr/sbin:/sbin depmod -b "$x/k" "$KVER"
	mkdir -p "$VM/modules"
	local m f
	: >"$VM/modules.list"
	for m in $MODULES; do
		for f in $(PATH=$PATH:/usr/sbin:/sbin modprobe -d "$x/k" -S "$KVER" --show-depends "$(basename "$m")" | awk '$1=="insmod"{print $2}'); do
			f=${f#"$x/k"}
			n=$(basename "${f%.xz}")
			grep -qx "$n" "$VM/modules.list" || { xz -dc "$x/k$f" >"$VM/modules/$n"; echo "$n" >>"$VM/modules.list"; }
		done
	done
	rm -rf "$x"
	echo "vm: kernel $KVER + busybox in $VM; modules: $(tr '\n' ' ' <"$VM/modules.list")" >&2
}

run() {
	local mode=$1 mem=1280 smp=4 extra=() drives=() i=0
	shift
	while [[ $# -gt 0 ]]; do
		case $1 in
		-f) extra+=("$2"); shift 2 ;;
		-m) mem=$2; shift 2 ;;
		-s) smp=$2; shift 2 ;;
		*) break ;;
		esac
	done
	fetch
	local rd; rd=$(mktemp -d)
	# qemu is killed (and the scratch removed) on every way out: exit, Ctrl-C, TERM, or the VM_TIMEOUT watchdog
	trap "vm_cleanup '$rd'" EXIT
	trap 'exit 130' INT TERM
	mkdir -p "$rd/bin" "$rd/lib/modules" "$rd/dev" "$rd/proc" "$rd/sys"
	install -m 755 "$VM/busybox" "$rd/bin/busybox"
	install -m 755 "$here/guest-init" "$rd/init"
	cp "$VM"/modules/*.ko "$rd/lib/modules/"
	sed 's,^,/lib/modules/,' "$VM/modules.list" >"$rd/modules.list"
	for e in "${extra[@]}"; do cp "${e#*=}" "$rd/${e%%=*}"; done
	(cd "$rd" && find . | cpio -o -H newc --owner=0:0 --quiet | gzip -1) >"$rd.cpio.gz"
	for d in "$@"; do
		local ro=off file=$d
		[[ $d == ro:* ]] && ro=on file=${d#ro:}
		drives+=(-drive "if=none,id=d$i,file=$file,format=raw,cache=unsafe,readonly=$ro" -device "virtio-blk-pci,drive=d$i")
		i=$((i + 1))
	done
	local n=$((${#drives[@]} / 4)) log; log=$(mktemp)
	[[ $mode != list ]] || n=$((n - 1))
	# pauth-impdef: the kernel signs every return address; the default QARMA5 emulation is many times slower
	# Background + wait: a TERM/INT trap runs at once instead of after the guest ends.
	timeout -k 10 "${VM_TIMEOUT:-7200}" qemu-system-aarch64 -pidfile "$rd.pid" -M virt -cpu max,pauth-impdef=on -smp "$smp" -m "$mem" -nographic -no-reboot \
		-kernel "$VM/vmlinuz" -initrd "$rd.cpio.gz" \
		-append "console=ttyAMA0 panic=-1 loglevel=3 ios.mode=$mode ios.n=$n ${IOS_APPEND:-}" \
		"${drives[@]}" 2>&1 | tee "$log" | sed -u 's/\r$//' &
	wait $! || true
	grep -q '^IOSROOT-GUEST-OK' "$log" && { rm -f "$log"; return 0; }
	echo "error: the guest did not finish (log kept: $log)" >&2
	return 1
}

vm_cleanup() {
	local p
	[[ -s $1.pid ]] && kill "$(cat "$1.pid")" 2>/dev/null
	for p in $(jobs -p); do kill "$p" 2>/dev/null; done
	rm -rf "$1" "$1.cpio.gz" "$1.pid"
}

case ${1:-} in
fetch) fetch ;;
run) shift; run "$@" ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
