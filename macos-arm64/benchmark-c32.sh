#!/usr/bin/env bash
# =============================================================================
# benchmark-c32.sh
# Measure how fast THIS Mac solves Cuckatoo32 with the lean CPU solver, BEFORE
# you bother with a node or the full miner. It builds a tiny standalone binary
# straight from the cuckoo source (no Rust, no plugin wrapper), solves a few
# graphs, and prints the measured ms/graph and the implied graphs/sec.
#
# Usage (from the repo root):
#     bash macos-arm64/benchmark-c32.sh [num_graphs] [nthreads]
#     bash macos-arm64/benchmark-c32.sh 5 8        # 5 graphs, 8 threads
# Defaults: num_graphs=5, nthreads = (CPU cores - 1).
#
# This is the SAME solver (cuckatoo/lean.cpp, EDGEBITS=32) the full miner uses,
# so the speed it reports is representative. On arm64 it builds with NSIPHASH=4
# (NEON 4-way siphash, injected by apply-arm64-patches.sh).
#
# CORRECTNESS SELF-CHECK: because the NEON siphash is hand-ported, this script
# first builds a scalar (NSIPHASH=1) reference AND the NEON (NSIPHASH=4) binary,
# solves the SAME nonce with both, and aborts if their (fully deterministic)
# graph output differs. Identical output == the NEON hash is bit-for-bit correct.
# Only then does it run the timed benchmark. Do not mine real shares until this
# check has passed at least once on your machine.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'

NGRAPHS="${1:-5}"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
NTHREADS="${2:-$(( NCPU > 1 ? NCPU - 1 : 1 ))}"

CUCKOO="cuckoo-miner/src/cuckoo_sys/plugins/cuckoo"
LEAN_CPP="$CUCKOO/src/cuckatoo/lean.cpp"
BLAKE_C="$CUCKOO/src/crypto/blake2b-ref.c"
OUT_NEON="$REPO_ROOT/macos-arm64/lean32_bench"          # NSIPHASH=4 (NEON), timed
OUT_SCALAR="$REPO_ROOT/macos-arm64/lean32_bench_scalar" # NSIPHASH=1, reference only

[[ -f "$LEAN_CPP" ]] || { echo "${RED}xx${NC} $LEAN_CPP not found — run: git submodule update --init --recursive"; exit 1; }
command -v cc >/dev/null || { echo "${RED}xx${NC} no compiler — run: xcode-select --install"; exit 1; }

# 1. ensure the arm64 patches are applied (immintrin guard + NEON siphash). idempotent.
bash "$REPO_ROOT/macos-arm64/apply-arm64-patches.sh" || exit 1

# 2. compile a standalone solver for a given NSIPHASH.
#    NOTE: we deliberately DO NOT define C_CALL_CONVENTION / SQUASH_OUTPUT — that
#    keeps lean.cpp's main() and its "Time: N ms" prints, which the plugin build
#    suppresses. NSIPHASH=4 -> the injected NEON path; NSIPHASH=1 -> scalar.
compile_variant() { # $1=NSIPHASH  $2=output path  -> echoes the flag note
	local ns="$1" out="$2"
	local flags=( -O3 -std=c++11 -DPREFETCH -DATOMIC -DEDGEBITS=32 -DNSIPHASH="$ns"
	              -Wno-format -Wno-deprecated-declarations -pthread )
	if c++ -mcpu=native "${flags[@]}" "$LEAN_CPP" "$BLAKE_C" -o "$out" 2>/dev/null; then
		echo "-mcpu=native"
	elif c++ "${flags[@]}" "$LEAN_CPP" "$BLAKE_C" -o "$out"; then
		echo "no -mcpu=native (your clang rejected it; fine)"
	else
		return 1
	fi
}

echo "${GREEN}==>${NC} compiling NEON C32 lean solver (NSIPHASH=4)..."
NOTE_NEON="$(compile_variant 4 "$OUT_NEON")" \
	|| { echo "${RED}xx${NC} NEON compile failed. Capture the error above — this is the injected NEON siphash."; exit 1; }
echo "    ($NOTE_NEON)"

echo "${GREEN}==>${NC} compiling scalar reference solver (NSIPHASH=1)..."
NOTE_SCALAR="$(compile_variant 1 "$OUT_SCALAR")" \
	|| { echo "${RED}xx${NC} scalar compile failed (unexpected — this path always built before)."; exit 1; }
echo "    ($NOTE_SCALAR)"

# 3. CORRECTNESS: solve nonce 0 with BOTH, compare the deterministic graph output.
#    "NN trims completed  M edges left" + the set of "K-cycle found" lines are a
#    pure function of the siphash output and are independent of thread count, so
#    a sorted diff is a clean pass/fail for siphash correctness.
echo "${GREEN}==>${NC} correctness self-check: scalar vs NEON on nonce 0..."
CHK_SCALAR="$(mktemp)"; CHK_NEON="$(mktemp)"
"$OUT_SCALAR" -n 0 -r 1 -t "$NTHREADS" >"$CHK_SCALAR" 2>&1
"$OUT_NEON"   -n 0 -r 1 -t "$NTHREADS" >"$CHK_NEON"   2>&1
SIG_SCALAR="$(grep -E 'edges left|-cycle found' "$CHK_SCALAR" | sort)"
SIG_NEON="$(grep -E 'edges left|-cycle found' "$CHK_NEON"   | sort)"

if [[ -z "$SIG_SCALAR" ]]; then
	echo "${RED}xx${NC} scalar reference produced no comparable output — cannot verify. Output was:"
	sed 's/^/    /' "$CHK_SCALAR"
	rm -f "$CHK_SCALAR" "$CHK_NEON"; exit 1
fi

if [[ "$SIG_SCALAR" == "$SIG_NEON" ]]; then
	echo "    ${GREEN}PASS${NC} — NEON siphash output is identical to scalar (bit-for-bit correct)."
	T_SCALAR="$(awk '/Time:.*ms/{print $2; exit}' "$CHK_SCALAR")"
	T_NEON="$(awk '/Time:.*ms/{print $2; exit}' "$CHK_NEON")"
	if [[ -n "${T_SCALAR:-}" && -n "${T_NEON:-}" && "$T_NEON" -gt 0 ]]; then
		awk -v s="$T_SCALAR" -v n="$T_NEON" 'BEGIN{
			printf "    reference graph time: scalar %d ms vs NEON %d ms (%.2fx)\n", s, n, s/n }'
	fi
else
	echo "${RED}xx${NC} MISMATCH — NEON siphash does NOT match scalar. The NEON port is WRONG."
	echo "    Do NOT mine with this build. Re-run with the scalar fallback by setting"
	echo "    LEAN_NSIPHASH=1 in CMakeLists.txt, and report the diff below:"
	echo "    --- scalar ---"; echo "$SIG_SCALAR" | sed 's/^/    /'
	echo "    --- NEON ---";   echo "$SIG_NEON"   | sed 's/^/    /'
	rm -f "$CHK_SCALAR" "$CHK_NEON"; exit 1
fi
rm -f "$CHK_SCALAR" "$CHK_NEON"

# 4. run the timed NEON benchmark. nonce 0..NGRAPHS-1 on a zero header.
echo "${GREEN}==>${NC} solving $NGRAPHS Cuckatoo32 graphs with $NTHREADS threads (nonces 0..$((NGRAPHS-1)))..."
echo "    (first graph is cold — memory faulting in; it is excluded from the average)"
echo "    -------------------------------------------------------------------"
LOG="$(mktemp)"
"$OUT_NEON" -n 0 -r "$NGRAPHS" -t "$NTHREADS" 2>&1 | tee "$LOG"
echo "    -------------------------------------------------------------------"

# 5. summarise: average the per-graph "Time: N ms" lines, skip the first (cold).
awk -v ng="$NGRAPHS" -v nt="$NTHREADS" '
	/Time:.*ms/ { n++; t=$2+0; if (n>1){ sum+=t; cnt++ } else cold=t }
	/Solution/  { sols++ }
	END {
		if (cnt<1){ print "    (not enough timed graphs to average — try more graphs)"; exit }
		avg = sum/cnt;
		gps = (avg>0) ? 1000.0/avg : 0;
		printf "\n  RESULT (warm avg over %d graph(s), %d threads, NEON 4-way siphash):\n", cnt, nt;
		printf "    cold first graph : %d ms\n", cold;
		printf "    avg per graph    : %.0f ms\n", avg;
		printf "    throughput       : %.4f graphs/sec (g/s)\n", gps;
		printf "    42-cycles found  : %d  (cycles are rare ~2-3%% of graphs; shares track this, not raw g/s)\n", sols+0;
	}
' "$LOG"
rm -f "$LOG"

cat <<EOF

  Interpreting this:
   - This g/s is the lean CPU rate (NEON 4-way siphash). Expect it well below a GPU
     mean solver. NOTE: NEON barely beats scalar here (~2-3%) — the lean solver is
     memory-latency-bound (random ~512MB bitmap access), so faster siphash is mostly
     hidden behind DRAM waits. SIMD siphash only helps the compute-bound mean solver.
   - A valid SOLUTION needs a found 42-cycle (rare), so solution cadence is much
     slower than g/s — fine for testing, not for earning coin.

  Happy with the speed? Next: build the full miner and point it at your node (or pool):
     bash macos-arm64/build-macos-arm64.sh
EOF
