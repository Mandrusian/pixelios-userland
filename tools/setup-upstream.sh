#!/bin/bash
# Fetch ios-sweet at the pinned commit and apply PixeliOS's changes to it.
#
#   tools/setup-upstream.sh
#
# ios-sweet has no license, so its files are not part of this repository. This script clones it
# from its own repository (into .upstream/, git-ignored), copies the files we build on
# (listed in upstream-files.txt) into the tree, and applies the diffs
# in upstream-patches/ to the ones we modified. Run it once after cloning; it is idempotent.
# UPSTREAM_REPO can point at a local clone (used by the tests).
set -euo pipefail
cd "$(dirname "$0")/.."
repo=${UPSTREAM_REPO:-https://github.com/dipa-studio/ios-sweet}
sha=11da58bd050672960c0a83b5bef2176047eea479

if [[ -e .upstream/.applied ]]; then
	echo "already set up (remove .upstream/ and re-checkout the patched files to redo)"
	exit 0
fi

rm -rf .upstream
git init -q .upstream
git -C .upstream fetch -q --depth 1 "$repo" "$sha"
git -C .upstream checkout -q FETCH_HEAD
[[ $(git -C .upstream rev-parse HEAD) == "$sha" ]] || { echo "unexpected upstream commit" >&2; exit 1; }

# 1. upstream files we build on and did not modify, listed in upstream-files.txt: copy if absent (never overwrite ours).
if [[ -f upstream-files.txt ]]; then
	while IFS= read -r f; do
		[[ -e $f ]] || { mkdir -p "$(dirname "$f")"; cp -p ".upstream/$f" "$f"; }
	done < upstream-files.txt
fi

# 2. upstream files we modified: start from upstream's copy, apply our diff.
shopt -s nullglob
for p in upstream-patches/*.patch; do
	f=$(sed -n '1s/^--- a\///p' "$p")
	[[ -n $f && -e .upstream/$f ]] || { echo "bad patch header in $p" >&2; exit 1; }
	mkdir -p "$(dirname "$f")"
	cp -p ".upstream/$f" "$f"
	patch -p1 -s --no-backup-if-mismatch < "$p"
done

touch .upstream/.applied
echo "ok: ios-sweet $sha fetched and patched"
