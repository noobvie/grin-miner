# Mine Grin testnet on Windows — beginner's guide (via WSL2)

**What this is:** a step-by-step way to run grin-miner **on a Windows 10/11 PC** that
solves Grin's real proof-of-work (**Cuckatoo32**) and submits shares to a **testnet
mining pool**, so you can test the pool end to end — on **GPU** (NVIDIA, fast) or
**CPU** (slow, any machine).

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
wsl --install -d Ubuntu
```

Reboot if prompted. When Ubuntu first launches it asks you to create a username +
password (this is your Linux login — remember the password, you'll need it for `sudo`).

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
sudo apt install -y git build-essential cmake pkg-config libssl-dev curl

# Rust (the miner is a Rust program):
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

# sanity check
gcc --version && cmake --version && cargo --version
```

---

## Step 3 — Get the code

```bash
git clone --recursive https://github.com/<your-fork>/grin-miner.git
cd grin-miner
git checkout macos-arm64-c32-lean   # this branch adds the C32 lean CPU plugin
git submodule update --init --recursive
```

> `--recursive` matters: the cuckoo solver is a git **submodule**. If you forgot it,
> the second command above fetches it.

---

## Step 4 — Build

```bash
cargo build --release
```

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
cp windows-x64/grin-miner-testnet-pool.toml ./grin-miner.toml
nano grin-miner.toml     # or: code grin-miner.toml  (opens VS Code)
```

Edit:

1. **`stratum_server_addr`** → `YOUR_POOL_HOST:13333` (your testnet pool's public
   stratum host; `13333` is the testnet default port).
2. **`stratum_server_login`** → `tgrin1youraddress.worker` — your **testnet** Grin
   address (starts with `tgrin1`) + a worker name. The pool uses the address as your
   identity (no account/signup).

Then pick **one** solver block in the file:

- **GPU:** leave **Option A** (`cuckatoo_mean_cuda_rtx_32`) active — fast, the live PoW.
- **CPU:** comment out Option A and uncomment **Option B** (`cuckatoo_lean_cpu_compat_32`)
  — slow (~1 GB RAM), but works on any machine.

---

## Step 6 — Run

```bash
./target/release/grin-miner
```

You should see it connect to the pool and start submitting graphs. A pool **share**
needs a found 42-cycle (rare per graph), so on CPU shares are infrequent — that's
expected and is fine for testing the pool. On GPU shares come much faster.

Check your address on the pool's web stats page to confirm shares are landing.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `nvidia-smi: command not found` (GPU) | Update the **Windows** NVIDIA driver (GeForce/Studio). WSL passthrough needs a recent driver; you do **not** install a Linux GPU driver. |
| CUDA plugin missing after build | `nvcc` absent at build time → finish Step 1, then `cargo clean && cargo build --release`. |
| GPU plugin loads then errors / out-of-memory | mean C32 needs a lot of VRAM. Fall back to CPU (Option B). |
| `lean.cpp` / submodule errors | You skipped `--recursive`. Run `git submodule update --init --recursive`. |
| Pool won't connect | Wrong `stratum_server_addr`/port. Testnet is `13333`. Bump `stdout_log_level = "Debug"` in the toml. |
| Very slow on CPU | Expected — lean CPU is for *testing* the pool, not earning. Use GPU if you have one. |

---

## Native Windows (not recommended)

A true `grin-miner.exe` is possible but unsupported here: you'd need MinGW-w64 or
clang-cl to satisfy the GCC-style plugin flags, plus `nvcc` on Windows for the CUDA
`.cu` files. It's a fragile toolchain fight with no upstream support. **WSL2 above is
the recommended path** — same speed (CUDA passthrough is near-native), far less pain.
