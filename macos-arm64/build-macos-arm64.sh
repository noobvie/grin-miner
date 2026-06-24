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

# Apply the arm64 source patches (guards the x86-only <immintrin.h> AND injects
# the NEON 4-way siphash into siphashxN.h). Idempotent + survives a fresh
# recursive clone. See apply-arm64-patches.sh. CMakeLists sets NSIPHASH=4 on arm64
# to use the NEON path; benchmark-c32.sh verifies it matches the scalar hash.
say "Applying arm64 source patches (immintrin guard + NEON siphash)..."
bash "$REPO_ROOT/macos-arm64/apply-arm64-patches.sh" || die "arm64 source patches failed"

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
# grin-miner is a 2020-era project; on a modern toolchain + Homebrew's OpenSSL 3.x
# it needs a pinned Rust and two dependency pins BEFORE the first cargo build.
# These are the exact fixes proven on the Linux/WSL path (README-windows-testnet.md
# Step 4) — they are platform-independent (pure-Rust dep + OpenSSL 3.x), so a Mac
# hits the identical errors without them. Applied here automatically.
#
#   - Rust 1.69.0: `rustc-serialize` (unmaintained dep) won't compile on current
#     Rust (error[E0310]). Pinned FIRST so stable never rewrites Cargo.lock to v4
#     (which 1.69 then can't read).
#   - openssl 0.10.48 / openssl-sys 0.9.92: the repo's openssl-sys 0.9.58 predates
#     OpenSSL 3.0 (Homebrew ships 3.x) -> "Failed to find OpenSSL headers"/expando.c
#     / ERR_put_error. These pins speak OpenSSL 3.x yet still build on Rust 1.69.

if command -v rustup >/dev/null 2>&1; then
	say "Pinning Rust 1.69.0 for this repo (2020-era deps need it)..."
	rustup install 1.69.0 >/dev/null 2>&1 || warn "rustup install 1.69.0 failed; continuing with $(rustc --version)"
	rustup override set 1.69.0 >/dev/null 2>&1 || warn "rustup override set 1.69.0 failed; continuing with $(rustc --version)"
	# If a prior stable build bumped Cargo.lock to v4, 1.69 can't read it.
	if grep -q '^version = 4' Cargo.lock 2>/dev/null; then
		warn "Cargo.lock is v4 (a newer Rust touched it); restoring the committed lockfile."
		git checkout -- Cargo.lock 2>/dev/null || warn "could not restore Cargo.lock; run: git checkout Cargo.lock"
	fi
else
	warn "rustup not found — cannot pin Rust 1.69.0. If cargo build fails with"
	warn "'rustc-serialize ... E0310' or a Cargo.lock v4 error, install rustup."
fi

say "Pinning OpenSSL crates for OpenSSL 3.x compatibility..."
cargo update -p openssl     --precise 0.10.48 || warn "openssl pin failed (continuing)"
cargo update -p openssl-sys --precise 0.9.92  || warn "openssl-sys pin failed (continuing)"

say "STAGE 2: building grin-miner (cargo build --release)..."
say "This re-builds the plugins again via build.rs and links the miner binary."
if cargo build --release; then
	say "${GREEN}BUILD COMPLETE.${NC}"
	echo
	echo "    Binary : $REPO_ROOT/target/release/grin-miner"
	echo "    Plugins: $REPO_ROOT/target/release/plugins/"
	echo
	echo "    Next: copy macos-arm64/grin-miner-arm64.toml to ./grin-miner.toml,"
	echo "    edit stratum_server_addr + stratum_server_login, then run:"
	echo "        ./target/release/grin-miner"
else
	warn "cargo build failed. STAGE 1 succeeded, so the C++/C32 side is fine —"
	warn "this is the known 2020-era Rust dependency risk. See README-m4-testnet.md"
	warn "section 'STAGE 2 troubleshooting' for the tiered fixes (pinned toolchain, etc.)."
	exit 1
fi
