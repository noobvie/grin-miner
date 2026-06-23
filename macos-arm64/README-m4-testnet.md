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

# 3. cmake (builds the C/C++ solver) and Rust (builds the miner):
brew install cmake
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

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
- **Stage 2** builds the Rust miner. This is the part most likely to need attention
  on a 2020-era codebase — if it fails, see **Troubleshooting → Stage 2** below.

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
- **Could be faster:** a NEON (Apple Silicon SIMD) siphash path could give ~2–4×.
  It's not built yet — ask if you want it after the basics work.

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
grin-miner is pinned at v4.0.0 (Sep 2020); its dependencies predate today's Rust.
Try in order:
1. **Just retry** — current stable Rust may build it as-is.
2. **Use an era-matching Rust** (most reliable):
   ```bash
   rustup toolchain install 1.51.0
   rustup override set 1.51.0     # only affects this folder
   cargo build --release
   ```
   (Try 1.51–1.59 if 1.51 errors on your host.)
3. **A dependency won't compile** (often the `cursive` TUI or `ncurses`): try
   `brew install ncurses`, then retry. Or capture the exact error and send it over.

**Good news:** Step 2 already gave you a working solver, so even if Stage 2 needs
fiddling, the C32/Apple-Silicon work is proven — only the Rust wrapper is left.

---

## Reference — what was changed, and what's verified

**The whole change is one patched file + this folder.** Stock grin-miner already
contains a working lean Cuckatoo CPU solver; it just lacked a **C32** build target
and used **x86-only** build settings.

- **`cuckoo-miner/src/cuckoo_sys/plugins/CMakeLists.txt`** — detect arm64; swap x86
  flags (`-march=native -m64` → `-mcpu=native`, blank `-mno-avx2`); add the
  `cuckatoo_lean_cpu_compat_32` target; on arm64 use scalar `NSIPHASH=1` and skip the
  x86-SIMD targets. x86 Linux builds are untouched.
- **`macos-arm64/apply-arm64-patches.sh`** — guards the unconditional
  `#include <immintrin.h>` in `siphashxN.h` (x86-only header) so arm64 compiles. Run
  automatically by the build + benchmark scripts; idempotent.
- **`macos-arm64/`** — `benchmark-c32.sh`, `build-macos-arm64.sh`,
  `grin-miner-testnet-pool.toml`, this README.

**No Rust changes were needed** — the plugin loader builds the filename from the toml
`plugin_name` (no hardcoded list), so the new plugin loads as-is.

**Verified by reading the source (high confidence):** the lean solver supports
EDGEBITS=32 (`NEDGES` is 64-bit; `graph.hpp`/`lean.hpp` carry explicit `==32`
markers); memory is ~1 GB (`alive` 512 MB + `nonleaf` 512 MB); the lean code path has
no x86 intrinsics once `siphashxN.h` is guarded and `NSIPHASH=1` selects scalar
siphash; `portable_endian.h` has an `__APPLE__` branch; the plugin exports all five
FFI symbols the loader needs.

**Not yet verified (needs your Mac):** the actual arm64 **compile** (Step 2 confirms
it in minutes) and the **Rust build** (Stage 2 — the 2020-era dependency risk). These
scripts were written on a Windows machine, which cannot produce macOS/arm64 binaries.
