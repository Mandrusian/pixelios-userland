#!/bin/bash
# Compare two iOS root images (e.g. the sudo build vs the rootless one) without root: both are attached read-only to
# the tools/rootless/vm.sh guest, which lists every entry (mode, uid, gid, type, path), every hard linked entry with
# its link count and the sha256 of the files in tools/rootless/keys.txt; this script diffs the sorted reports.
#
#   tools/rootless/compare-images.sh A.img B.img [--deep]
#
# --deep also hashes every regular file of both images (slow: the guest hashes ~8 GB per image under TCG).
# Timestamps and the volume UUID are not compared. Exit 0 = no difference. Report files stay in $OUT
# (default: a new temp dir, printed).
set -euo pipefail
cd "$(dirname "$0")/../.."
a=$(realpath "$1") b=$(realpath "$2") deep=
[[ ${3:-} != --deep ]] || deep=ios.deep=1
out=${OUT:-$(mktemp -d)}
mkdir -p "$out"
truncate -s "${REPORT_SIZE:-4G}" "$out/report.bin"          # sparse; the guest writes the report raw
SECONDS=0
IOS_APPEND=$deep tools/rootless/vm.sh run list -f keys.txt=tools/rootless/keys.txt -m "${RAM:-1024}" "ro:$a" "ro:$b" "$out/report.bin" >"$out/guest.log"
echo "guest: ${SECONDS}s"
tr -d '\0' <"$out/report.bin" | awk -v d="$out" '
	/^== IMAGE /{img=$3; next}
	/^== END/{ended=1; exit}
	/^== /{sec=$2; next}
	{print > (d "/" sec "." img ".raw")}
	END{if(!ended){print "error: report is truncated" > "/dev/stderr"; exit 1}}'
rc=0
for s in LISTING LINKS HASHES DEEP; do
	[[ -e $out/$s.0.raw ]] || continue
	for i in 0 1; do LC_ALL=C sort "$out/$s.$i.raw" >"$out/$s.$i"; done
	n=$(wc -l <"$out/$s.0")
	if diff -u "$out/$s.0" "$out/$s.1" >"$out/$s.diff"; then
		echo "$s: identical ($n lines)"
	else
		rc=1
		echo "$s: $(grep -c '^[-+][^-+]' "$out/$s.diff") differing lines (see $out/$s.diff):"
		grep '^[-+][^-+]' "$out/$s.diff" | head -${SHOW:-40}
	fi
done
echo "reports in $out"
exit $rc
