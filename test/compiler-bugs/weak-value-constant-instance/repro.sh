#!/usr/bin/env bash
# The app's `main` satisfies a platform requirement (`[Model : model] for
# main`), so checking never generalizes it: it is a weak value, one value
# whose type keeps a variable nothing fixes (the type of the items of `seen`).
# `init` reads the polymorphic constant `empty` at that variable. The
# platform (platform/main.roc) reads `main` in the functions it provides; the
# platform builds an archive, so no host is needed.
#
# On upstream main (bec95b9f4a) and on rocx-fixes-5 the boxy builds (the
# default --opt=dev, --opt=interpreter, a fresh cache) crash the compiler in
# boxy_lowering: a release compiler segfaults; a debug one stops at "Boxy
# lowering invariant violated: an edge's 0 literal arguments do not cover its
# callee's 1 literal requirements (caller read_for_host, callee a template of
# an imported module)". --specialize=yes builds. On rocx-fixes-4 (the nightly
# 890d6c8 plus the fork's fixes, before polymorphic constants) every build
# passes. With the fix every build passes.
#
#     ROC=…/roc ./repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
[ -x "$roc" ] || { echo "set ROC to a roc binary"; exit 2; }
cd "$here"
"$roc" version
out_dir=$(mktemp -d "${TMPDIR:-/tmp}/roc-out.XXXXXX")
run() {
	out=$("$roc" build --output="$out_dir/app.a" "$@" app.roc 2>&1)
	code=$?
	said=$(printf '%s\n' "$out" | grep -aoE 'successfully building|invariant violated: .*|Segmentation fault \(SIGSEGV\)|Segmentation fault|panic: .*' | head -1)
	stage=$(printf '%s\n' "$out" | grep -aoE '^ +post-check +[a-z_]+' | sed -E 's/ +/ /g' | head -1)
	printf '%-40s exit %-3s %s%s\n' "$*" "$code" "$said" "${stage:+ (in$stage)}"
}
run --no-cache --opt=dev
run --no-cache --opt=dev --specialize=no
run --no-cache --opt=interpreter --specialize=no
run --no-cache --opt=dev --specialize=yes
cache=$(mktemp -d "${TMPDIR:-/tmp}/roc-cache.XXXXXX")
ROC_CACHE_DIR=$cache run --opt=dev --specialize=no
rm -rf "$cache" "$out_dir"
