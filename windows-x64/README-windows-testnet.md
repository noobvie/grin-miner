# Mine Grin testnet on Windows — beginner's guide (via WSL2)

**What this is:** a step-by-step way to run grin-miner **on a Windows 10/11 PC** that
solves Grin's real proof-of-work (**Cuckatoo32**) against a **testnet node** (or a
pool), so you can mine end to end — on **GPU** (NVIDIA, fast) or **CPU** (slow, any
machine).

**Why WSL2 and not a native `.exe`?** grin-miner has **no official Windows build** —
its CI only produces Linux/macOS binaries, and the C/C++ solver uses GCC/clang compiler
flags (`-march=native`, `-mavx2`, `-pthread`) that Microsoft's MSVC compiler rejects.
Rather than fight that toolchain, we run the **exact Linux build that already works**
inside **WSL2** (Windows Subsystem for Linux). It's the supported, reliable path and it
covers **both** GPU and CPU mining.

> New to the terminal? Every step below is copy-paste. After Step 0 you'll be inside an
> **Ubuntu** shell — run the commands there, one block at a time.

---

## Step 0 — Install WSL2 + Ubuntu (one time)

Open **PowerShell as Administrator** (Start → type "PowerShell" → right-click → Run as
administrator) and run:

```powershell
wsl --install -d Ubuntu-24.04
```

We pin **Ubuntu 24.04 LTS** (rather than the generic `-d Ubuntu` alias) so every tester
lands on the same supported version. See `wsl --list --online` for all available distros.

Reboot if prompted. When Ubuntu first launches it asks you to create a username +
password (this is your Linux login — remember the password, you'll need it for `sudo`).

> **If `wsl --install` fails or WSL still doesn't start** (some editions ship with the
> feature switched off): press **Win**, type **`optionalfeatures.exe`** and hit **Enter** to
> open *Turn Windows features on or off*. Scroll down and tick the box for **Windows Subsystem
> for Linux** (and **Virtual Machine Platform**, needed for WSL2), click **OK**, then reboot.
> After the reboot, run `wsl --install -d Ubuntu-24.04` again and `wsl --set-default-version 2`.

From here on, work inside the **Ubuntu** terminal (Start → "Ubuntu"), **not** PowerShell.

---

## Step 1 — GPU only: install the NVIDIA CUDA driver path

**Skip this whole step if you're mining on CPU (no usable GPU).**

CUDA-on-WSL needs the **NVIDIA driver installed on Windows** (the normal GeForce/Studio
driver — already present if you game) and the **CUDA toolkit installed inside WSL**. Do
**not** install a Linux NVIDIA driver inside WSL — only the toolkit.

Inside the Ubuntu shell, first confirm the GPU is visible:

```bash
nvidia-smi      # should list your GPU. If "command not found", update your Windows NVIDIA driver.
```

Then install the CUDA toolkit (this provides `nvcc`, needed to build the CUDA solver):

```bash
sudo apt update
sudo apt install -y nvidia-cuda-toolkit
nvcc --version  # confirms the compiler is present
```

---

## Step 2 — Install the build tools (one time)

Inside the Ubuntu shell:

```bash
sudo apt update
sudo apt install -y git build-essential cmake pkg-config libssl-dev libncurses-dev curl

# Rust (the miner is a Rust program):
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

# sanity check
gcc --version && cmake --version && cargo --version
```

---

## Step 3 — Get the code

> **⚠️ Clone into your Linux home, NOT into `/mnt/c/...` (your Windows drive).** Cloning
> under `/mnt/c` (e.g. `C:\Users\you\grin-miner`) puts the repo on the Windows `drvfs` mount,
> which can't do Unix file permissions. git then fails with:
> ```
> error: chmod on .../.git/config.lock failed: Operation not permitted
> fatal: could not set 'core.filemode' to 'false'
> ```
> and the build is also **several times slower** there. Always work from the WSL native
> filesystem (`~`, i.e. `/home/<you>/`). The commands below already `cd ~` first.

```bash
cd ~                                # WSL native filesystem — do NOT use /mnt/c
git clone --recursive https://github.com/<your-fork>/grin-miner.git
cd grin-miner
git checkout macos-arm64-c32-lean   # this branch adds the C32 lean CPU plugin
git submodule update --init --recursive
```

> `--recursive` matters: the cuckoo solver is a git **submodule**. If you forgot it,
> the last command above fetches it.
>
> **Already cloned under `/mnt/c` and hit the `chmod`/`core.filemode` error?** Easiest fix is
> to re-clone into `~` as above. If you must keep it on the Windows drive, tell git to stop
> tracking the executable bit — `git config --global core.filemode false` — and enable mount
> metadata: add the following to `/etc/wsl.conf`, then run `wsl --shutdown` from PowerShell and
> reopen Ubuntu:
> ```ini
> [automount]
> options = "metadata"
> ```

---

## Step 4 — Build

grin-miner is a **2020-era project**, so on modern Ubuntu (22.04 / 24.04) it needs a pinned
Rust toolchain and two dependency pins **before** the first build. Run these four commands, in
order, from the repo directory:

```bash
# 1. Pin Rust 1.69 for this repo — MUST be done before the first build (see note below)
rustup install 1.69.0 && rustup override set 1.69.0

# 2. Make the OpenSSL bindings compatible with Ubuntu's OpenSSL 3.x
cargo update -p openssl     --precise 0.10.48
cargo update -p openssl-sys --precise 0.9.92

# 3. Build
cargo build --release
```

**Why each step** (this is the squeeze that makes the versions specific):

- **Rust 1.69, and pinned first.** A dependency (`rustc-serialize`) is unmaintained and won't
  compile on current Rust (`error[E0310]: the parameter type T may not live long enough`), so
  the toolchain must stay old. Pin it *first*: if you build on the latest stable even once,
  Cargo rewrites `Cargo.lock` to format **v4**, which 1.69 then can't read (`lock file version
  4 ... Cargo needs to be updated`). If that already happened, run `git checkout Cargo.lock`.
- **The OpenSSL pins.** The repo's original `openssl 0.10.30` / `openssl-sys 0.9.58` predate
  **OpenSSL 3.0** (Ubuntu 22.04/24.04 ship 3.x), so the build fails with a confusing
  *"Failed to find OpenSSL development headers"* / `expando.c` error — even though `libssl-dev`
  is installed. The headers are fine; the old crates can't speak OpenSSL 3.x. `0.10.48` /
  `0.9.92` (early/mid 2023) are the sweet spot: new enough for OpenSSL 3.x, old enough to still
  build on Rust 1.69. (The *latest* openssl-sys now requires Rust 1.80, which would re-break
  `rustc-serialize` — hence the precise pins rather than a bare `cargo update`.)

> **Note:** these are local-build commands; nothing is committed. The toolchain override lives
> in `rustup`'s state for this directory, and the dependency pins land in your working
> `Cargo.lock`.

This compiles the C/C++ solver plugins **and** the miner binary. First build takes a
while. On success you'll have:

- the binary at `target/release/grin-miner`
- the solver plugins in `target/release/plugins/` — confirm yours is there:

```bash
ls target/release/plugins/ | grep cuckatoo_
# GPU testers want:  cuckatoo_mean_cuda_rtx_32.cuckooplugin
# CPU testers want:  cuckatoo_lean_cpu_compat_32.cuckooplugin
```

If the CUDA plugin is missing, `nvcc` wasn't found at build time — revisit Step 1, then
`cargo clean && cargo build --release`.

---

## Step 5 — Configure

Copy the ready-made testnet config and edit two lines:

```bash
cp windows-x64/grin-miner-wsl2.toml ./grin-miner.toml
nano grin-miner.toml     # or: code grin-miner.toml  (opens VS Code)
```

By default it mines to a **local testnet node's built-in stratum** —
`stratum_server_addr = "127.0.0.1:13416"` (Grin's native stratum port; mainnet is
`3416`). That needs a grin node running with `enable_stratum_server = true` and a
wallet listening so the node can build the coinbase. If the node runs in the same
WSL2, `127.0.0.1` is correct; otherwise use the node's host.

**To mine to a pool instead**, set `stratum_server_addr` to the pool's public
`host:port` and uncomment `stratum_server_login` with the login the pool documents
(many use address-as-identity, `<grin_address>.<worker>`, e.g.
`tgrin1youraddress.worker`).

Then pick **one** solver block in the file:

- **GPU:** leave **Option A** (`cuckatoo_mean_cuda_rtx_32`) active — fast, the live PoW.
- **CPU:** comment out Option A and uncomment **Option B** (`cuckatoo_lean_cpu_compat_32`)
  — slow (~1 GB RAM), but works on any machine.

---

## Step 6 — Run

```bash
./target/release/grin-miner
```

You should see it connect to your node (or pool) and start submitting graphs. A
valid **solution** needs a found 42-cycle (rare per graph), so on CPU they're
infrequent — that's expected. On GPU they come much faster. At testnet's low
difficulty, mining to your own node, found solutions become real testnet blocks
(against a pool you'll see the share credited on its stats page).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `nvidia-smi: command not found` (GPU) | Update the **Windows** NVIDIA driver (GeForce/Studio). WSL passthrough needs a recent driver; you do **not** install a Linux GPU driver. |
| CUDA plugin missing after build | `nvcc` absent at build time → finish Step 1, then `cargo clean && cargo build --release`. |
| GPU plugin loads then errors / out-of-memory | mean C32 needs a lot of VRAM. Fall back to CPU (Option B). |
| `chmod ... config.lock failed: Operation not permitted` / `could not set 'core.filemode'` | You cloned under `/mnt/c` (Windows drive). Re-clone into `~` (Step 3), or `git config --global core.filemode false` + add `[automount]\noptions="metadata"` to `/etc/wsl.conf` and `wsl --shutdown`. |
| `openssl-sys` build fails: *"Failed to find OpenSSL development headers"* / `expando.c` macro error | The original `openssl-sys 0.9.58` is too old for Ubuntu's OpenSSL 3.x. Apply the Step 4 pins (`cargo update -p openssl --precise 0.10.48 && cargo update -p openssl-sys --precise 0.9.92`). `libssl-dev` is already installed — this is the crate, not the headers. |
| `openssl` fails: `cannot find function ERR_put_error / FIPS_mode / SSL_get_peer_certificate in crate ffi` | The high-level `openssl 0.10.30` is too old for OpenSSL 3.x. Bump it *with* its `-sys` crate: `cargo update -p openssl --precise 0.10.48 && cargo update -p openssl-sys --precise 0.9.92`. |
| `openssl-sys vX cannot be built because it requires rustc 1.80.0 or newer` | `cargo update` pulled too new an `openssl-sys` for the 1.69 pin. Pin it down: `cargo update -p openssl-sys --precise 0.9.92`. |
| `ncurses` build fails: `fatal error: ncurses.h: No such file or directory` | Missing ncurses headers. Run `sudo apt install -y libncurses-dev`, then rebuild (Step 4). |
| `rustc-serialize` fails: `error[E0310]: the parameter type T may not live long enough` | Current Rust is too new for this old dep. Pin an older toolchain in the repo: `rustup install 1.69.0 && rustup override set 1.69.0`, then rebuild (Step 4). |
| `lock file version 4 was found ... Cargo needs to be updated` | You built on stable before pinning 1.69, which upgraded `Cargo.lock`. Restore it: `git checkout Cargo.lock`, then re-run the Step 4 commands. |
| `cmake --build` prints its usage text then build-script exits 1 (`cuckoo_miner`) | Newer CMake (3.28 on Ubuntu 24.04) rejects the empty `--target ""` in `cuckoo-miner/src/build.rs`. Fixed in this branch (`build_target("all")`); if on an older checkout: `sed -i 's/\.build_target("")/.build_target("all")/' cuckoo-miner/src/build.rs`. |
| `lean.cpp` / submodule errors | You skipped `--recursive`. Run `git submodule update --init --recursive`. |
| Stratum won't connect | Wrong `stratum_server_addr`/port. The node's built-in stratum is `13416` testnet / `3416` mainnet (a pool uses its own port). Confirm the node has `enable_stratum_server = true`. Bump `stdout_log_level = "Debug"` in the toml. |
| Very slow on CPU | Expected — lean CPU is for *testing*, not earning. Use GPU if you have one. |

---

## Native Windows (not recommended)

A true `grin-miner.exe` is possible but unsupported here: you'd need MinGW-w64 or
clang-cl to satisfy the GCC-style plugin flags, plus `nvcc` on Windows for the CUDA
`.cu` files. It's a fragile toolchain fight with no upstream support. **WSL2 above is
the recommended path** — same speed (CUDA passthrough is near-native), far less pain.
