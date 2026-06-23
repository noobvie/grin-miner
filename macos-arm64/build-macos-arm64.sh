#!/usr/bin/env bash
# =============================================================================
# build-macos-arm64.sh
# Build grin-miner + the C32 lean CPU plugin on Apple Silicon (M1/M2/M3/M4).
#
# Run this ON THE MAC, from the repo root:
#     bash macos-arm64/build-macos-arm64.sh
#
# It runs in two stages so failures are easy to localise:
#   STAGE 1 — build ONLY the C++ cuckoo plugins via cmake. This validates the
#             arm64 + C32 CMakeLists patch in isolation (no Rust involved).
#             Success here => cuckatoo_lean_cpu_compat_32.cuckooplugin exists.
#   STAGE 2 — build the full grin-miner binary with cargo (the Rust wrapper +
#             stratum client + TUI). This is the part most likely to need
#             dependency wrangling on a modern toolchain; see README-m4-testnet.md.
#
# Nothing here needs sudo. CUDA is never built (no NVIDIA on a Mac).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
say()  { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}!!${NC} $*"; }
die()  { echo "${RED}xx${NC} $*"; exit 1; }

# ----------------------------------------------------------------------------
# 0. Sanity + prerequisites
# ----------------------------------------------------------------------------
ARCH="$(uname -m)"
[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS. Detected: $(uname -s)"
[[ "$ARCH" == "arm64" ]] || warn "uname -m = '$ARCH' (expected arm64). Continuing, but this script targets Apple Silicon."

say "Checking prerequisites..."
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools missing. Run: xcode-select --install"
command -v cmake >/dev/null 2>&1 || die "cmake missing. Install with: brew install cmake"
command -v cargo >/dev/null 2>&1 || die "Rust/cargo missing. Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"

say "clang   : $(cc --version | head -1)"
say "cmake   : $(cmake --version | head -1)"
say "rustc   : $(rustc --version)"

# The submodule must be present or build.rs panics.
if [[ ! -e cuckoo-miner/src/cuckoo_sys/plugins/cuckoo/src/cuckatoo/lean.cpp ]]; then
	warn "cuckoo submodule looks empty; fetching..."
	git submodule update --init --recursive || die "git submodule update failed"
fi

# ----------------------------------------------------------------------------
# STAGE 1 — build the C++ plugins only (isolates the CMakeLists patch)
# ----------------------------------------------------------------------------
PLUGIN_SRC="cuckoo-miner/src/cuckoo_sys/plugins"
PLUGIN_BUILD="$PLUGIN_SRC/build-arm64"

say "STAGE 1: building cuckoo plugins (cmake, CUDA off)..."
cmake -S "$PLUGIN_SRC" -B "$PLUGIN_BUILD" -DBUILD_CUDA_PLUGINS=FALSE \
	|| die "cmake configure failed (STAGE 1). See README 'STAGE 1 troubleshooting'."
cmake --build "$PLUGIN_BUILD" -j"$(sysctl -n hw.ncpu)" \
	|| die "plugin compile failed (STAGE 1). See README 'STAGE 1 troubleshooting'."

C32_PLUGIN="$PLUGIN_BUILD/plugins/cuckatoo_lean_cpu_compat_32.cuckooplugin"
if [[ -f "$C32_PLUGIN" ]]; then
	say "${GREEN}C32 lean plugin built:${NC} $C32_PLUGIN"
	echo "    ----- plugins produced -----"
	ls -1 "$PLUGIN_BUILD/plugins/"*.cuckooplugin 2>/dev/null | sed 's/^/    /'
else
	die "Expected $C32_PLUGIN but it is missing. The C32 target did not build."
fi

echo
warn "STAGE 1 passed. This already proves the C32 lean solver compiles on your Mac."
warn "If STAGE 2 (the Rust wrapper) fights the toolchain, you still have a working"
warn "plugin and the standalone solver source to fall back on."
echo

# ----------------------------------------------------------------------------
# STAGE 2 — build the full grin-miner binary (Rust)
# ----------------------------------------------------------------------------
say "STAGE 2: building grin-miner (cargo build --release)..."
say "This re-builds the plugins again via build.rs and links the miner binary."
if cargo build --release; then
	say "${GREEN}BUILD COMPLETE.${NC}"
	echo
	echo "    Binary : $REPO_ROOT/target/release/grin-miner"
	echo "    Plugins: $REPO_ROOT/target/release/plugins/"
	echo
	echo "    Next: copy macos-arm64/grin-miner-testnet-pool.toml to ./grin-miner.toml,"
	echo "    edit stratum_server_addr + stratum_server_login, then run:"
	echo "        ./target/release/grin-miner"
else
	warn "cargo build failed. STAGE 1 succeeded, so the C++/C32 side is fine —"
	warn "this is the known 2020-era Rust dependency risk. See README-m4-testnet.md"
	warn "section 'STAGE 2 troubleshooting' for the tiered fixes (pinned toolchain, etc.)."
	exit 1
fi
