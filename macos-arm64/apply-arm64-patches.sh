#!/usr/bin/env bash
# =============================================================================
# apply-arm64-patches.sh
# Idempotent source patches needed to build the cuckoo plugins on Apple Silicon.
#
# Two independent, idempotent steps (each guarded by its own sentinel so this
# script is safe to run repeatedly and survives a fresh `git clone --recursive`,
# which would otherwise reset the submodule to tromp/cuckoo's pristine source):
#
#   STEP 1 — guard the x86-only <immintrin.h> include in siphashxN.h.
#     Why: that header does `#include <immintrin.h>` UNCONDITIONALLY. The header
#     is x86-only and does not exist on arm64, so the compile fails before it
#     even reaches the (correctly guarded) AVX2/SSE2 code. We wrap the include so
#     it is x86-only.
#
#   STEP 2 — inject a NEON 2-way/4-way siphash-2-4 into siphashxN.h.
#     Why: upstream siphashxN.h only has SIMD siphash for x86 (SSE2/AVX2). With no
#     arm64 path the lean solver fell back to NSIPHASH=1 (scalar siphash). NEON
#     gives ~2-4x on Apple Silicon. The injected functions mirror the SSE2
#     __m128i path 1:1 using uint64x2_t (two 64-bit lanes per vector), so they are
#     bit-for-bit identical to the scalar hash (verified by benchmark-c32.sh,
#     which compares NSIPHASH=1 vs NSIPHASH=4 solver output before timing).
#     Paired with CMakeLists.txt setting LEAN_NSIPHASH=4 on arm64.
#
# These patches live in this build-time script (not edited submodule files) so
# they survive a fresh recursive clone on the Mac. Safe to run repeatedly.
#
# Called automatically by build-macos-arm64.sh and benchmark-c32.sh. You normally
# don't run it by hand.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIPX="$REPO_ROOT/cuckoo-miner/src/cuckoo_sys/plugins/cuckoo/src/crypto/siphashxN.h"

[[ -f "$SIPX" ]] || { echo "apply-arm64-patches: $SIPX not found (submodule missing?)"; exit 1; }

# ---------------------------------------------------------------------------
# STEP 1 — wrap the unconditional <immintrin.h> include in an x86-only guard.
# ---------------------------------------------------------------------------
if grep -q "ARM64_IMMINTRIN_GUARD" "$SIPX"; then
	echo "apply-arm64-patches: siphashxN.h <immintrin.h> already guarded — skipping step 1."
else
	# perl ships with macOS and handles the 1-line -> multi-line rewrite cleanly
	# (BSD sed newline handling does not).
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
		echo "apply-arm64-patches: FAILED to patch <immintrin.h> in siphashxN.h — its #include line may have changed."
		echo "  Manually wrap line  '#include <immintrin.h>'  in:"
		echo "    $SIPX"
		echo "  with  #if defined(__x86_64__)||defined(__i386__) ... #endif"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# STEP 2 — inject the NEON siphash24x2 / siphash24x4 implementations.
# Inserted just before the `#ifndef NSIPHASH` block so that:
#   - SIPROUNDXN / SIPROUNDX2N macros (defined earlier in the file) are visible;
#   - the functions are defined BEFORE siphash24xN() dispatches to them.
# ---------------------------------------------------------------------------
if grep -q "ARM64_NEON_SIPHASH" "$SIPX"; then
	echo "apply-arm64-patches: siphashxN.h NEON siphash already injected — skipping step 2."
else
	if ! grep -q "^#ifndef NSIPHASH" "$SIPX"; then
		echo "apply-arm64-patches: FAILED to find the '#ifndef NSIPHASH' anchor in siphashxN.h."
		echo "  The header layout changed; cannot inject the NEON path automatically."
		exit 1
	fi

	export NEON_BLOCK_FILE="$(mktemp)"
	cat > "$NEON_BLOCK_FILE" <<'NEON_EOF'
// ARM64_NEON_SIPHASH: NEON 2-way/4-way siphash-2-4 for Apple Silicon (arm64).
// Injected by macos-arm64/apply-arm64-patches.sh. Mirrors the SSE2 __m128i path
// using uint64x2_t (two 64-bit lanes per vector), so results are bit-for-bit
// identical to the scalar keys->siphash24(). Active when CMakeLists.txt sets
// -DNSIPHASH=4 on arm64. Verified by benchmark-c32.sh (NSIPHASH=1 vs 4 compare).
#if defined(__ARM_NEON) && !defined(__SSE2__) && !defined(__AVX2__)
#include <arm_neon.h>

#define ADD(a, b) vaddq_u64((a), (b))
#define XOR(a, b) veorq_u64((a), (b))
#define ROT13(x) vorrq_u64(vshlq_n_u64((x), 13), vshrq_n_u64((x), 51))
#define ROT16(x) vorrq_u64(vshlq_n_u64((x), 16), vshrq_n_u64((x), 48))
#define ROT17(x) vorrq_u64(vshlq_n_u64((x), 17), vshrq_n_u64((x), 47))
#define ROT21(x) vorrq_u64(vshlq_n_u64((x), 21), vshrq_n_u64((x), 43))
#define ROT23(x) vorrq_u64(vshlq_n_u64((x), 23), vshrq_n_u64((x), 41))
#define ROT25(x) vorrq_u64(vshlq_n_u64((x), 25), vshrq_n_u64((x), 39))
#define ROT32(x) vorrq_u64(vshlq_n_u64((x), 32), vshrq_n_u64((x), 32))

// 2-way sipHash-2-4 (one uint64x2_t = 2 lanes), mirrors the SSE2 siphash24x2.
void siphash24x2(const siphash_keys *keys, const uint64_t *indices, uint64_t *hashes) {
  uint64x2_t v0, v1, v2, v3, mi;
  v0 = vdupq_n_u64(keys->k0);
  v1 = vdupq_n_u64(keys->k1);
  v2 = vdupq_n_u64(keys->k2);
  v3 = vdupq_n_u64(keys->k3);
  mi = vld1q_u64(indices);

  v3 = XOR(v3, mi);
  SIPROUNDXN; SIPROUNDXN;
  v0 = XOR(v0, mi);
  v2 = XOR(v2, vdupq_n_u64(0xffULL));
  SIPROUNDXN; SIPROUNDXN; SIPROUNDXN; SIPROUNDXN;
  mi = XOR(XOR(v0, v1), XOR(v2, v3));

  vst1q_u64(hashes, mi);
}

// 4-way sipHash-2-4 (two uint64x2_t = 4 lanes), mirrors the SSE2 siphash24x4.
void siphash24x4(const siphash_keys *keys, const uint64_t *indices, uint64_t *hashes) {
  uint64x2_t v0, v1, v2, v3, mi, v4, v5, v6, v7, m2;
  v4 = v0 = vdupq_n_u64(keys->k0);
  v5 = v1 = vdupq_n_u64(keys->k1);
  v6 = v2 = vdupq_n_u64(keys->k2);
  v7 = v3 = vdupq_n_u64(keys->k3);

  mi = vld1q_u64(indices);
  m2 = vld1q_u64(indices + 2);

  v3 = XOR(v3, mi);
  v7 = XOR(v7, m2);
  SIPROUNDX2N; SIPROUNDX2N;
  v0 = XOR(v0, mi);
  v4 = XOR(v4, m2);
  v2 = XOR(v2, vdupq_n_u64(0xffULL));
  v6 = XOR(v6, vdupq_n_u64(0xffULL));
  SIPROUNDX2N; SIPROUNDX2N; SIPROUNDX2N; SIPROUNDX2N;
  mi = XOR(XOR(v0, v1), XOR(v2, v3));
  m2 = XOR(XOR(v4, v5), XOR(v6, v7));

  vst1q_u64(hashes, mi);
  vst1q_u64(hashes + 2, m2);
}
#endif // ARM64_NEON_SIPHASH

NEON_EOF

	perl -0777 -i -pe '
		BEGIN { local $/; open(my $f, "<", $ENV{NEON_BLOCK_FILE}) or die $!; our $blk = <$f>; close($f); }
		s/(\n)(#ifndef NSIPHASH\b)/$1 . $blk . $2/e;
	' "$SIPX"
	rm -f "$NEON_BLOCK_FILE"
	unset NEON_BLOCK_FILE

	if grep -q "ARM64_NEON_SIPHASH" "$SIPX"; then
		echo "apply-arm64-patches: injected NEON siphash24x2/x4 into siphashxN.h."
	else
		echo "apply-arm64-patches: FAILED to inject NEON siphash into siphashxN.h."
		exit 1
	fi
fi
