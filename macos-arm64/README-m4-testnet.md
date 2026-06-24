# Mine Grin testnet on a Mac (Apple Silicon) — beginner's guide

**What this is:** a step-by-step way to run a **CPU miner on an Apple Silicon Mac**
(M1/M2/M3/M4) that solves Grin's real proof-of-work (**Cuckatoo32**) and submits
shares to a **testnet mining pool**, so you can test the pool end to end.

**What to expect:** it's **slow** (CPU, not GPU) and uses **~1 GB RAM**. That's the
point — it fits a normal Mac and submits *real* shares on testnet's low difficulty.
It will **not** earn meaningful coin. If that's your goal, this is the right tool.

> New to the terminal? Every step below is copy-paste. Run the commands in the
> macOS **Terminal** app, one block at a time, from inside this project folder.

---

## Step 0 — Install the tools (one time)

Open Terminal and run these. Each line installs one prerequisite.

```bash
# 1. Apple's compiler (clang). A popup will appear — click Install.
xcode-select --install

# 2. Homebrew (the macOS package manager), if you don't already have it:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. cmake (builds the C/C++ solver), pkg-config + OpenSSL 3.x (a Rust dep links
#    against it), and Rust (builds the miner):
brew install cmake pkg-config openssl@3
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

> **Why OpenSSL here?** one of the miner's Rust deps links OpenSSL. Homebrew's
> `openssl@3` is *keg-only* (not on the default path), so if the build later can't
> find it, point it there explicitly and rebuild:
> ```bash
> export OPENSSL_DIR="$(brew --prefix openssl@3)"
> ```

After Rust installs, **close and reopen Terminal** (so `cargo` is on your PATH),
then check everything is present:

```bash
clang --version   # any version
cmake --version   # any version
cargo --version   # any version
```

---

## Step 1 — Get this project onto the Mac

You need this exact folder (it contains the Apple-Silicon patch). Two ways:

- **Easiest — copy the folder.** Copy the whole `grin-miner` folder from your PC to
  the Mac (USB drive, AirDrop, network share). Make sure the
  `cuckoo-miner/src/cuckoo_sys/plugins/cuckoo` subfolder is **not empty**.
- **Or clone it** (if you pushed it to a git remote):
  ```bash
  git clone --recursive <your-remote-url> grin-miner
  ```
  The `--recursive` is important — it pulls the `cuckoo` solver source.

Then move into the folder (all later steps run from here):

```bash
cd grin-miner
```

---

## Step 2 — Quick test: can this Mac solve Cuckatoo32, and how fast? (no pool yet)

Before dealing with the pool or the full miner, prove the solver works on your Mac
and see its speed. This builds a tiny standalone program and solves a few graphs:

```bash
bash macos-arm64/benchmark-c32.sh
```

You'll see lines like `Time: 41000 ms` (one per graph) and a summary:

```
  RESULT (warm avg over 4 graph(s), 11 threads):
    avg per graph    : 41000 ms
    throughput       : 0.0244 graphs/sec (g/s)
```

That `graphs/sec` number is your real CPU speed. **If you got here, the hard part
works** — the solver compiles and runs on your Mac. (Tune it: `bash
macos-arm64/benchmark-c32.sh 8 6` = 8 graphs, 6 threads.)

> Expect something like **0.01–0.03 g/s** on an M4 Max. That's normal for CPU lean
> mining and is plenty to test a pool (more on speed below).

---

## Step 3 — Build the full miner

This builds the actual `grin-miner` program that talks to the pool:

```bash
bash macos-arm64/build-macos-arm64.sh
```

The script runs in two stages and tells you clearly if one fails:
- **Stage 1** builds just the C32 solver plugin (fast; should pass — Step 2 already proved it).
- **Stage 2** builds the Rust miner. Because this is a 2020-era codebase on a modern
  toolchain + Homebrew's OpenSSL 3.x, the script **automatically** pins Rust `1.69.0`
  and the `openssl` / `openssl-sys` crates before building (the same fixes the Linux/WSL
  path needs — they're platform-independent, so a Mac hits the identical errors without
  them). If it still fails, see **Troubleshooting → Stage 2** below.

When it finishes you'll have `target/release/grin-miner`.

---

## Step 4 — Point it at your testnet pool

Copy the ready-made config to where the miner looks for it, then edit two lines:

```bash
cp macos-arm64/grin-miner-testnet-pool.toml ./grin-miner.toml
open -e ./grin-miner.toml      # opens in TextEdit; or use: nano ./grin-miner.toml
```

Change exactly these two lines:

```toml
# your testnet pool's public stratum host (testnet port is 13333):
stratum_server_addr = "YOUR_POOL_HOST:13333"

# address-as-identity login:  <your tgrin1... address>.<any worker name>
stratum_server_login = "tgrin1youraddress.m4worker"
```

Everything else is already set (the C32 lean plugin, thread count, logging). The
password line can stay `"x"` — the pool ignores it.

---

## Step 5 — Run it

```bash
./target/release/grin-miner
```

A text dashboard appears. **What success looks like:**
1. It connects to the pool and logs in (no auth errors in the log).
2. It loads the `cuckatoo_lean_cpu_compat_32` plugin at **edge_bits 32**.
3. It starts solving graphs (slowly) and shows a graphs/sec figure.
4. When it finds a valid share, your **pool/node log** shows
   `Got share at height H` — that round trip (connect → job → solve → accepted
   share) is the pool test you wanted.

Stop it with `Ctrl-C`. Logs are written to `grin-miner.log`.

---

## How fast / how many shares? (set expectations)

- **Speed:** lean CPU C32 is roughly **0.01–0.03 g/s** on an M4 Max — far below a
  GPU. Slowness is expected and fine for testing.
- **Shares are rarer than graphs:** a valid 42-cycle exists in only ~2–3% of graphs,
  so at ~0.02 g/s expect an **accepted share every ~20–40 minutes** on testnet.
  Enough to exercise the share → credit → maturity → payout pipeline overnight; not
  enough to accumulate coin.
- **Speed:** the arm64 build uses a **NEON 4-way siphash** (`NSIPHASH=4`, injected by
  `apply-arm64-patches.sh`), ~2–4× the old scalar path. `benchmark-c32.sh` verifies the
  NEON hash matches the scalar hash bit-for-bit before timing, so a mismatch aborts
  rather than mining bad shares. To force the old scalar path, set `LEAN_NSIPHASH=1` in
  `CMakeLists.txt`. (The g/s figures above predate NEON; expect them ~2–4× higher.)

---

## Troubleshooting

### Step 2 / Stage 1 — the C++ solver won't compile
- **`'immintrin.h' file not found`** — the arm64 patch didn't apply. Run it manually:
  `bash macos-arm64/apply-arm64-patches.sh`, then retry.
- **`unsupported option '-mcpu=native'`** — your clang is older than that flag. The
  benchmark auto-retries without it. For the plugin build, edit
  `cuckoo-miner/src/cuckoo_sys/plugins/CMakeLists.txt`, arm64 branch: change
  `set (ARCH_FLAGS "-mcpu=native")` to `set (ARCH_FLAGS "-mcpu=apple-m1")` or
  `set (ARCH_FLAGS "")`, then rerun.
- **`lean.cpp not found` / submodule empty** — `git submodule update --init --recursive`.

### Stage 2 — the Rust build (`cargo`) fails — the likeliest snag
grin-miner is v4.0.0 (Sep 2020); its dependencies predate today's Rust **and**
Homebrew's OpenSSL 3.x. The build script already applies the fixes below
automatically — this table is for when one still bites (e.g. you ran `cargo build`
by hand, or `rustup` wasn't installed when the script ran). These are the **same
fixes proven on the Linux/WSL path**, because the failures are platform-independent.

| Symptom | Cause / fix |
|---|---|
| `rustc-serialize` fails: `error[E0310]: the parameter type T may not live long enough` | Current Rust is too new for this old dep. Pin the era toolchain **for this folder**: `rustup install 1.69.0 && rustup override set 1.69.0`, then rebuild. **Use 1.69.0 — not 1.51.** Older toolchains fail other deps; 1.69 is the sweet spot that builds the whole tree. |
| `lock file version 4 was found ... Cargo needs to be updated` | You built on stable Rust before pinning 1.69, which rewrote `Cargo.lock` to v4. Restore it: `git checkout Cargo.lock`, then re-pin 1.69 (above) and rebuild. The build script restores it for you. |
| `openssl-sys` build fails: *"Failed to find OpenSSL development headers"* / `expando.c` macro error | The original `openssl-sys 0.9.58` is too old for OpenSSL 3.x (Homebrew ships 3.x). Apply the pins: `cargo update -p openssl --precise 0.10.48 && cargo update -p openssl-sys --precise 0.9.92`. This is the crate, not your headers. |
| `openssl` fails: `cannot find function ERR_put_error / FIPS_mode / SSL_get_peer_certificate in crate ffi` | Same root cause — the high-level `openssl 0.10.30` is too old for OpenSSL 3.x. Apply both pins above (bump `openssl` *with* its `-sys` crate). |
| `openssl-sys` still can't find OpenSSL on a Mac | Homebrew's `openssl@3` is keg-only. Point at it: `export OPENSSL_DIR="$(brew --prefix openssl@3)"` (and make sure `pkg-config` is installed — `brew install pkg-config openssl@3`), then rebuild. |
| `openssl-sys vX cannot be built because it requires rustc 1.80.0 or newer` | A bare `cargo update` pulled too-new an `openssl-sys` for the 1.69 pin. Pin it down: `cargo update -p openssl-sys --precise 0.9.92`. |
| A dependency won't compile (often the `cursive` TUI / `ncurses`) | `brew install ncurses`, then retry. Or capture the exact error and send it over. |

**Good news:** Step 2 already gave you a working solver, so even if Stage 2 needs
fiddling, the C32/Apple-Silicon work is proven — only the Rust wrapper is left.

---

## Reference — what was changed, and what's verified

**The whole change is one patched file + this folder.** Stock grin-miner already
contains a working lean Cuckatoo CPU solver; it just lacked a **C32** build target
and used **x86-only** build settings.

- **`cuckoo-miner/src/cuckoo_sys/plugins/CMakeLists.txt`** — detect arm64; swap x86
  flags (`-march=native -m64` → `-mcpu=native`, blank `-mno-avx2`); add the
  `cuckatoo_lean_cpu_compat_32` target; on arm64 use `NSIPHASH=4` (NEON, see below) and
  skip the x86-SIMD targets. x86 Linux builds are untouched.
- **`macos-arm64/apply-arm64-patches.sh`** — two idempotent source patches: (1) guards
  the unconditional `#include <immintrin.h>` in `siphashxN.h` (x86-only header) so arm64
  compiles; (2) injects a **NEON 2-way/4-way siphash** (`uint64x2_t`) into `siphashxN.h`
  mirroring the SSE2 `__m128i` path, enabling `NSIPHASH=4` on arm64. Run automatically
  by the build + benchmark scripts.
- **`macos-arm64/`** — `benchmark-c32.sh`, `build-macos-arm64.sh`,
  `grin-miner-testnet-pool.toml`, this README.

**No Rust changes were needed** — the plugin loader builds the filename from the toml
`plugin_name` (no hardcoded list), so the new plugin loads as-is.

**Verified by reading the source (high confidence):** the lean solver supports
EDGEBITS=32 (`NEDGES` is 64-bit; `graph.hpp`/`lean.hpp` carry explicit `==32`
markers); memory is ~1 GB (`alive` 512 MB + `nonleaf` 512 MB); the lean code path has
no x86 intrinsics once `siphashxN.h` is guarded (the NEON `NSIPHASH=4` path uses only
`<arm_neon.h>`); `portable_endian.h` has an `__APPLE__` branch; the plugin exports all
five FFI symbols the loader needs.

**Verified at runtime by you (must pass before mining):** `benchmark-c32.sh` compiles
both the scalar (`NSIPHASH=1`) and NEON (`NSIPHASH=4`) solvers, solves the same nonce
with each, and aborts unless the deterministic graph output is identical — proving the
hand-ported NEON siphash is bit-for-bit correct on your hardware.

**Not yet verified (needs your Mac):** the actual arm64 **compile** (Step 2 confirms
it in minutes) and the **Rust build** (Stage 2 — the 2020-era dependency risk). These
scripts were written on a Windows machine, which cannot produce macOS/arm64 binaries.
