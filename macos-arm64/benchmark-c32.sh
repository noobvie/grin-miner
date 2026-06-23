#!/usr/bin/env bash
# =============================================================================
# benchmark-c32.sh
# Measure how fast THIS Mac solves Cuckatoo32 with the lean CPU solver, BEFORE
# you bother with the pool. It builds a tiny standalone binary straight from the
# cuckoo source (no Rust, no plugin wrapper), solves a few graphs, and prints the
# measured ms/graph and the implied graphs/sec.
#
# Usage (from the repo root):
#     bash macos-arm64/benchmark-c32.sh [num_graphs] [nthreads]
#     bash macos-arm64/benchmark-c32.sh 5 8        # 5 graphs, 8 threads
# Defaults: num_graphs=5, nthreads = (CPU cores - 1).
#
# This is the SAME solver (cuckatoo/lean.cpp, EDGEBITS=32, scalar siphash) that
# the pool plugin uses, so the speed it reports is representative.
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
OUT="$REPO_ROOT/macos-arm64/lean32_bench"

[[ -f "$LEAN_CPP" ]] || { echo "${RED}xx${NC} $LEAN_CPP not found — run: git submodule update --init --recursive"; exit 1; }
command -v cc >/dev/null || { echo "${RED}xx${NC} no compiler — run: xcode-select --install"; exit 1; }

# 1. ensure the arm64 immintrin guard is applied (idempotent)
bash "$REPO_ROOT/macos-arm64/apply-arm64-patches.sh" || exit 1

# 2. compile the standalone solver.
#    NOTE: we deliberately DO NOT define C_CALL_CONVENTION / SQUASH_OUTPUT — that
#    keeps lean.cpp's main() and its "Time: N ms" prints, which the plugin build
#    suppresses. NSIPHASH=1 = scalar siphash (arm64-safe).
COMMON_FLAGS=( -O3 -std=c++11 -DPREFETCH -DATOMIC -DEDGEBITS=32 -DNSIPHASH=1
               -Wno-format -Wno-deprecated-declarations -pthread )

echo "${GREEN}==>${NC} compiling standalone C32 lean solver..."
if c++ -mcpu=native "${COMMON_FLAGS[@]}" "$LEAN_CPP" "$BLAKE_C" -o "$OUT" 2>/dev/null; then
	echo "    (built with -mcpu=native)"
elif c++ "${COMMON_FLAGS[@]}" "$LEAN_CPP" "$BLAKE_C" -o "$OUT"; then
	echo "    (built without -mcpu=native — your clang rejected it; fine)"
else
	echo "${RED}xx${NC} compile failed. This is the C32 lean solver itself; capture the error above."
	exit 1
fi

# 3. run it. nonce 0..NGRAPHS-1 on a zero header. Each graph prints "Time: N ms".
echo "${GREEN}==>${NC} solving $NGRAPHS Cuckatoo32 graphs with $NTHREADS threads (nonces 0..$((NGRAPHS-1)))..."
echo "    (first graph is cold — memory faulting in; it is excluded from the average)"
echo "    -------------------------------------------------------------------"
LOG="$(mktemp)"
"$OUT" -n 0 -r "$NGRAPHS" -t "$NTHREADS" 2>&1 | tee "$LOG"
echo "    -------------------------------------------------------------------"

# 4. summarise: average the per-graph "Time: N ms" lines, skip the first (cold).
awk -v ng="$NGRAPHS" -v nt="$NTHREADS" '
	/Time:.*ms/ { n++; t=$2+0; if (n>1){ sum+=t; cnt++ } else cold=t }
	/Solution/  { sols++ }
	END {
		if (cnt<1){ print "    (not enough timed graphs to average — try more graphs)"; exit }
		avg = sum/cnt;
		gps = (avg>0) ? 1000.0/avg : 0;
		printf "\n  RESULT (warm avg over %d graph(s), %d threads):\n", cnt, nt;
		printf "    cold first graph : %d ms\n", cold;
		printf "    avg per graph    : %.0f ms\n", avg;
		printf "    throughput       : %.4f graphs/sec (g/s)\n", gps;
		printf "    42-cycles found  : %d  (cycles are rare ~2-3%% of graphs; shares track this, not raw g/s)\n", sols+0;
	}
' "$LOG"
rm -f "$LOG"

cat <<EOF

  Interpreting this:
   - This g/s is the lean CPU rate. Expect it well below a GPU mean solver.
   - A pool SHARE needs a found 42-cycle (rare), so share cadence is much slower
     than g/s — fine for testing the pool, not for earning coin.
   - Want it faster? A NEON 4-way siphash path could give ~2-4x (not built yet).

  Happy with the speed? Next: build the full miner and point it at your pool:
     bash macos-arm64/build-macos-arm64.sh
EOF
