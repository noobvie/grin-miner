# grin-miner on Apple Silicon (M4) — CPU lean Cuckatoo32 → Grin testnet pool

Goal: run a **CPU** miner on a **Mac M4 Max (36 GB)** that solves the live Grin
PoW (**Cuckatoo32**) and submits real shares to your **testnet public pool**, to
test the pool end-to-end. Speed is not a goal — fitting in 36 GB and submitting
valid shares is.

This folder adds that capability to a stock `mimblewimble/grin-miner` checkout:

| File | Purpose |
|------|---------|
| `build-macos-arm64.sh` | Two-stage build (plugins-only, then full miner) for Apple Silicon |
| `grin-miner-testnet-pool.toml` | Ready config: C32 lean CPU plugin → testnet pool stratum |
| `README-m4-testnet.md` | This document |

Plus one patched file: **`cuckoo-miner/src/cuckoo_sys/plugins/CMakeLists.txt`**
(see "What I changed" below).

---

## TL;DR (do this on the Mac)

```bash
# 1. prerequisites
xcode-select --install                 # Xcode command line tools (clang)
brew install cmake                     # build system
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # rust, if not present

# 2. get this exact tree onto the Mac (it has the patch + this folder)
#    e.g. push this repo to a remote and clone --recursive on the Mac,
#    or copy the folder over. The cuckoo submodule MUST be present.

# 3. build (two stages, with clear pass/fail at each)
bash macos-arm64/build-macos-arm64.sh

# 4. configure
cp macos-arm64/grin-miner-testnet-pool.toml ./grin-miner.toml
#    edit ./grin-miner.toml:  stratum_server_addr + stratum_server_login

# 5. run
./target/release/grin-miner
```

---

## Why this works (and why the fancy Metal miner didn't)

Cuckatoo32 solvers come in two families:

- **Mean** (the fast Metal miner, grin-miner's `mean_cuda`): holds the entire
  2³² edge set in memory → **~90 GB**, fixed by the problem size. Cannot be tuned
  down to 36 GB; the memory *is* the data structure.
- **Lean** (this): represents the graph as a **bitmap** and trims it iteratively.
  **~1 GB** for C32. Much slower, but fits 36 GB trivially and submits valid shares.

You asked "can't we downgrade the size requirement?" — the lean solver **is** that
downgrade: it trades speed for memory. Slowness was acceptable to you, so lean is
the right tool.

---

## What I changed, and why it's only one file

Stock grin-miner already contains a fully-working lean Cuckatoo CPU solver
(`cuckoo-miner/.../cuckoo/src/cuckatoo/lean.cpp`). Upstream simply never shipped a
**C32** build target for it (slow C32 CPU mining was never worth packaging) and the
build flags are **x86-only**. The single patched file fixes both:

**`cuckoo-miner/src/cuckoo_sys/plugins/CMakeLists.txt`**
1. **Arch detection.** On `arm64`/`aarch64`, replace the x86 flags
   `-march=native -m64` with `-mcpu=native`, and make the per-target `-mno-avx2`
   an empty string (it's an x86 flag clang rejects on arm64).
2. **New target** `cuckatoo_lean_cpu_compat_32` — the same lean source compiled
   with `-DEDGEBITS=32 -DNSIPHASH=4` (scalar siphash, no SIMD).
3. **Skip x86-SIMD targets on arm64** (mean CPU, cuckaroo/cuckarood CPU, the
   `avx2` lean variant) so the arm64 build only produces the portable lean targets.

x86 Linux builds are unaffected (everything is behind `if (NOT MINER_ARM64)`).

**No Rust changes are needed.** The plugin loader builds the filename directly from
the toml `plugin_name` (`PluginConfig::new` → `format!("{}.cuckooplugin", name)`) —
there is no hardcoded plugin allowlist. Put `cuckatoo_lean_cpu_compat_32` in the
toml and it loads `cuckatoo_lean_cpu_compat_32.cuckooplugin`.

---

## Verified vs. needs-testing-on-the-M4

I built this on a Windows box, so I **could not compile arm64/macOS binaries**.
Here's the honest split.

### Verified by reading the actual source (high confidence)

- **The lean solver supports EDGEBITS=32.** `NEDGES = 1ULL << EDGEBITS` is 64-bit
  (no overflow at 2³²); `word_t` resolves to `u32` (correct — node values fit 32
  bits); the edge-loop counters are bounded below 2³². Upstream even left explicit
  32-bit markers: `graph.hpp` — `const word_t NIL = ~(word_t)0; // NOTE: matches
  last edge when EDGEBITS==32`, and `lean.hpp` has a `#if NONPART_BITS == 32` guard.
- **The lean-compat source set is arm64-clean.** Zero x86 intrinsics
  (`_mm_*`, `immintrin.h`) in any of its files; prefetch uses portable
  `__builtin_prefetch`; the AVX siphash lives in `siphashxN.h`, which the lean
  source set does **not** include (NSIPHASH=4 = scalar path).
- **macOS endian support exists.** `portable_endian.h` has a real `__APPLE__`
  branch (`<libkern/OSByteOrder.h>`).
- **Memory ≈ 1 GB.** `cuckoo_ctx` allocates `alive` (2³² bits = 512 MB) + `nonleaf`
  (512 MB), and the recovery graph reuses that buffer. Fits 36 GB with vast headroom.
- **The plugin exports the required FFI symbols.** `create_solver_ctx`,
  `destroy_solver_ctx`, `run_solver`, `stop_solver`, `fill_default_params` are all
  defined in `lean.cpp` (same as the existing, working `_31` plugin).

### Needs confirming on the M4 (where the real unknowns are)

1. **STAGE 1 (plugin compile).** Expected to pass given the above. The one flag to
   watch is `-mcpu=native`: very recent Apple clang supports it; if yours rejects it,
   see STAGE 1 troubleshooting (one-line fallback).
2. **STAGE 2 (the Rust build).** This is the **main risk**: grin-miner is pinned at
   v4.0.0 (Sep 2020) and its dependencies predate the current Rust toolchain. It may
   build clean, or it may need the fixes in STAGE 2 troubleshooting. STAGE 1 is
   deliberately independent so you get a working plugin even if STAGE 2 needs work.
3. **Live share acceptance.** Once running, the proof is the pool/node log line
   `Got share at height H` (accepted) vs `submitted too late` (stale). Lean is slow,
   so on testnet expect occasional shares, not a stream.

---

## STAGE 1 troubleshooting (C++ plugin build)

`build-macos-arm64.sh` STAGE 1 runs cmake on the plugins only and checks for
`cuckatoo_lean_cpu_compat_32.cuckooplugin`.

- **`clang: error: unsupported option '-mcpu=native'`** — your clang is older than
  the flag. Edit `cuckoo-miner/src/cuckoo_sys/plugins/CMakeLists.txt`, in the arm64
  branch change `set (ARCH_FLAGS "-mcpu=native")` to either
  `set (ARCH_FLAGS "-mcpu=apple-m1")` (safe, forward-compatible — an M4 runs M1-tuned
  code fine) or simply `set (ARCH_FLAGS "")` (rely on clang defaults; fine for a slow
  solver). Re-run.
- **`unknown argument: '-mno-avx2'`** — means the arch detection didn't fire (you're
  not being seen as arm64). Check `cmake` prints the `Apple Silicon / arm64` status
  line; if not, your `CMAKE_SYSTEM_PROCESSOR` is unusual — force it:
  `cmake -S ... -B ... -DCMAKE_SYSTEM_PROCESSOR=arm64 ...`.
- **submodule empty / `lean.cpp` not found** — `git submodule update --init --recursive`.

A STAGE 1 pass alone already proves the C32 lean solver compiles and runs on your M4.

---

## STAGE 2 troubleshooting (Rust / cargo build) — the likely sticking point

grin-miner v4.0.0 is from 2020. On a 2026 toolchain, try these in order:

1. **Just try it first.** `cargo build --release` with current stable may simply work
   (the pinned `Cargo.lock` helps). If it does, you're done.

2. **Pin an era-appropriate Rust** (most reliable fix for old crates):
   ```bash
   rustup toolchain install 1.51.0          # ~grin-miner v4.0.0 era
   rustup override set 1.51.0               # applies to this repo dir only
   cargo build --release
   ```
   (Try 1.51–1.59 if 1.51 itself errors on the host.)

3. **If a specific dependency fails to compile** (common culprits: the TUI crate
   `cursive`/ncurses, `libloading`, `cgmath`), capture the exact error and we fix
   that crate's version. As a quick experiment you can let cargo pick newer compatible
   versions: `cargo update && cargo build --release` (may introduce API breaks — share
   the output and I'll patch).

4. **ncurses/TUI link errors** — the TUI needs ncurses. `brew install ncurses` and
   retry. (Setting `run_tui = false` in the toml changes runtime behaviour but does
   **not** drop the build-time dependency on this version.)

If STAGE 2 proves stubborn, the **fallback** is the standalone lean solver from STAGE 1:
the same `lean.cpp` compiles to a CLI tester via the cuckoo submodule's own Makefile,
which lets you confirm the M4 solves C32 graphs even before the stratum wrapper builds.
That doesn't talk to the pool, but it de-risks the solver independently. Tell me if you
want a thin stratum driver as a Plan B instead of fighting the 2020 Rust tree.

---

## Configure → run

1. `cp macos-arm64/grin-miner-testnet-pool.toml ./grin-miner.toml`
2. Edit two lines:
   - `stratum_server_addr = "YOUR_POOL_HOST:13333"` — your testnet pool's public
     stratum (port **13333** for testnet; a regional gateway host works too).
   - `stratum_server_login = "tgrin1youraddress.m4worker"` — **address-as-identity**:
     `<your tgrin1… address>.<worker name>`. Password is ignored but keep `"x"`.
3. `nthreads` in the plugin block: start at physical-cores − 1 (e.g. 8 on M4 Max).
4. Run `./target/release/grin-miner`. The TUI shows connection status, the loaded
   plugin (`cuckatoo_lean_cpu_compat_32`), edge_bits 32, and graphs/sec.

### What success looks like

- grin-miner connects and logs in (the pool authenticates the `tgrin1….worker`
  username) and starts receiving jobs.
- The miner reports solving C32 graphs (slowly).
- On a solved share at/above pool difficulty, your **pool/node** log shows
  `Got share at height H`. That round-trip — login → job → solve → accepted share —
  is the pool test you wanted.

### Reality check on speed

Lean C32 on CPU is very slow (think a fraction of a graph/sec). On testnet's low
share difficulty you'll still land shares periodically — enough to validate the
share/credit/maturity/payout pipeline, which is the point. It is **not** a way to
accumulate meaningful coin.

---

## If you'd rather just prove connectivity first

You don't even need a working solver to confirm your pool accepts a miner: the Metal
repo's `strat_probe` (or any stratum login probe) connects, logs in with your
`tgrin1….worker`, and prints the pool's job reply — zero solving, zero RAM. That's the
fastest "does my pool talk to a miner" check. This grin-miner build is the next step:
actually submitting accepted shares.
