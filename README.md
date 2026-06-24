[![Build Status](https://dev.azure.com/mimblewimble/grin-miner/_apis/build/status/mimblewimble.grin-miner?branchName=master)](https://dev.azure.com/mimblewimble/grin-miner/_build/latest?definitionId=5&branchName=master)

# Grin Miner

A standalone mining implementation intended for mining Grin against a running Grin node (or a pool).

> **⛏️ New to mining? Beginner testnet guides added by this fork:**
>
> - **Mac (Apple Silicon: M1/M2/M3/M4)** — CPU-mine Grin testnet against your own node (or a
>   pool) using this fork's **Cuckatoo32 lean** plugin. 👉 **[`macos-arm64/README-m4-testnet.md`](macos-arm64/README-m4-testnet.md)**
> - **Windows 10/11** — mine Grin testnet against your own node (or a pool) via **WSL2** (the
>   supported Linux build), on **GPU** (NVIDIA CUDA) or **CPU**. 👉 **[`windows-x64/README-windows-testnet.md`](windows-x64/README-windows-testnet.md)**

## Supported Platforms

At present, only mining plugins for linux-x86_64 and MacOS exist. This will likely change over time as the community creates more solvers for different platforms.

## Requirements

- rust 1.30+ (use [rustup]((https://www.rustup.rs/))- i.e. `curl https://sh.rustup.rs -sSf | sh; source $HOME/.cargo/env`)
- cmake 3.2+ (for [Cuckoo mining plugins]((https://github.com/mimblewimble/cuckoo-miner)))
- ncurses and libs (ncurses, ncursesw5)
- zlib libs (zlib1g-dev or zlib-devel)
- linux-headers (reported needed on Alpine linux)

And a [running Grin node](https://github.com/mimblewimble/grin/blob/master/doc/build.md) to mine into!

## Build steps

> These are the **generic upstream** build steps for experienced users on Linux. They clone
> vanilla `mimblewimble/grin-miner`, which does **not** include this fork's Cuckatoo32 lean CPU
> plugin. **New to mining, or on a Mac/Windows?** Use the beginner guides linked at the top of
> this README instead — they install the prerequisites, clone this fork, and walk you all the
> way to mining Grin testnet on your hardware.

```sh
git clone https://github.com/mimblewimble/grin-miner.git
cd grin-miner
git submodule update --init
cargo build
```

### Building the Cuckoo-Miner plugins

Grin-miner automatically builds x86_64 CPU plugins. Cuda plugins are also provided, but are
not enabled by default. To enable them, modify `Cargo.toml` as follows:

```
change:
cuckoo_miner = { path = "./cuckoo-miner" }
to:
cuckoo_miner = { path = "./cuckoo-miner", features = ["build-cuda-plugins"]}
```

The Cuda toolkit 9+ must be installed on your system (check with `nvcc --version`)

### Building the OpenCL plugins
OpenCL plugins are not enabled by default. Run `install_ocl_plugins.sh` script to build and install them.

```
./install_ocl_plugins.sh
```
You must install OpenCL libraries for your operating system before.
If you just need to compile them (for development or testing purposes) build grin-miner the following way:

```
cargo build --features opencl
```

### Build errors

See [Troubleshooting](https://github.com/mimblewimble/docs/wiki/Troubleshooting)

## What was built?

A successful build gets you:

 - `target/debug/grin-miner` - the main grin-miner binary
 - `target/debug/plugins/*` - mining plugins

Make sure you always run grin-miner within a directory that contains a
`grin-miner.toml` configuration file.

While testing, put the grin-miner binary on your path like this:

```
export PATH=/path/to/grin-miner/dir/target/debug:$PATH
```

You can then run `grin-miner` directly.

# Configuration

Grin-miner can be further configured via the `grin-miner.toml` file.
This file contains contains inline documentation on all configuration
options, and should be the first point of reference.

You should always ensure that this file exists in the directory from which you're
running grin-miner.

# Using grin-miner

See the [Grin forum](https://forum.grin.mw) and the [official docs](https://docs.grin.mw) for
further detail on configuring grin-miner and mining Grin's testnet.

**Brand new to this?** The beginner guides above walk through the whole flow end to end:
[macOS (Apple Silicon)](macos-arm64/README-m4-testnet.md) · [Windows (WSL2)](windows-x64/README-windows-testnet.md).
