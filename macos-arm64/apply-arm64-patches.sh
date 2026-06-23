#!/usr/bin/env bash
# =============================================================================
# apply-arm64-patches.sh
# Idempotent source patch needed to build the cuckoo plugins on Apple Silicon.
#
# Why: cuckoo/src/crypto/siphashxN.h does `#include <immintrin.h>` UNCONDITIONALLY.
# That header is x86-only and does not exist on arm64, so the compile fails before
# it even reaches the (correctly guarded) AVX2/SSE2 code. We wrap the include so it
# is x86-only. On arm64 the lean solver is built with NSIPHASH=1 (scalar siphash),
# which never touches the SIMD paths, so nothing else in this header is needed.
#
# This lives in a build-time script (not an edited submodule file) so it survives
# a fresh `git clone --recursive` on the Mac, which would otherwise reset the
# submodule to tromp/cuckoo's pristine source. Safe to run repeatedly.
#
# Called automatically by build-macos-arm64.sh and benchmark-c32.sh. You normally
# don't run it by hand.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIPX="$REPO_ROOT/cuckoo-miner/src/cuckoo_sys/plugins/cuckoo/src/crypto/siphashxN.h"

[[ -f "$SIPX" ]] || { echo "apply-arm64-patches: $SIPX not found (submodule missing?)"; exit 1; }

# Already patched? (sentinel left by this script)
if grep -q "ARM64_IMMINTRIN_GUARD" "$SIPX"; then
	echo "apply-arm64-patches: siphashxN.h already guarded — nothing to do."
	exit 0
fi

# Wrap the immintrin include in an x86-only guard. perl ships with macOS and
# handles the 1-line -> multi-line rewrite cleanly (BSD sed newline handling does not).
perl -i -pe '
	if (/^\s*#include\s*<immintrin\.h>/ && !$g) {
		$_ = "#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86) // ARM64_IMMINTRIN_GUARD\n"
		   . $_
		   . "#endif\n";
		$g = 1;
	}
' "$SIPX"

if grep -q "ARM64_IMMINTRIN_GUARD" "$SIPX"; then
	echo "apply-arm64-patches: guarded <immintrin.h> in siphashxN.h (x86-only)."
else
	echo "apply-arm64-patches: FAILED to patch siphashxN.h — its #include line may have changed."
	echo "  Manually wrap line  '#include <immintrin.h>'  in:"
	echo "    $SIPX"
	echo "  with  #if defined(__x86_64__)||defined(__i386__) ... #endif"
	exit 1
fi
