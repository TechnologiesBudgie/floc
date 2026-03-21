# FLOC — Build & Install Guide

## Prerequisites

| Platform | Package manager command |
|----------|------------------------|
| Ubuntu/Debian | `sudo apt install gfortran gcc make` |
| Fedora/RHEL | `sudo dnf install gcc-gfortran gcc make` |
| Arch Linux | `sudo pacman -S gcc-fortran gcc make` |
| macOS (Homebrew) | `brew install gcc libomp` |
| Windows (MSYS2) | `pacman -S mingw-w64-x86_64-gcc-fortran` |

OpenMP is included with gfortran on Linux. On macOS it requires `libomp`
from Homebrew (see macOS section below).

---

## Linux (Ubuntu / Debian / Fedora / Arch)

```bash
# 1. Install toolchain (Ubuntu example)
sudo apt update && sudo apt install -y gfortran gcc make

# 2. Build
cd floc/
make

# 3. Test
./floc --help
./floc src/

# 4. (Optional) Install to /usr/local/bin
sudo make install

# 5. Or install to user home
make install PREFIX=~/.local
export PATH="$HOME/.local/bin:$PATH"
```

---

## macOS

```bash
# 1. Install Homebrew toolchain
brew install gcc libomp

# gfortran from Homebrew is typically gfortran-14 (or -13, -12)
# Find the version:
ls /opt/homebrew/bin/gfortran*

# 2. Build specifying the compiler explicitly
FC=gfortran-14 CC=gcc-14 make

# 3. Test
./floc --help
./floc .

# Install
sudo make install PREFIX=/usr/local
```

**Apple Silicon note:** The default clang on macOS does not support OpenMP.
You must use GNU gfortran from Homebrew. The Makefile auto-detects macOS and
passes the correct `-Xpreprocessor -fopenmp -lomp` flags.

---

## Windows (MSYS2 / MinGW-w64)

```bash
# 1. Install MSYS2 from https://www.msys2.org/
# 2. Open "MSYS2 MINGW64" shell and install compiler:
pacman -S mingw-w64-x86_64-gcc-fortran mingw-w64-x86_64-make

# 3. Build
cd /path/to/floc
mingw32-make

# 4. Run
./floc.exe --help
./floc.exe C:/path/to/your/repo
```

---

## Windows (WSL 2)

Run inside WSL2 using the Linux instructions above. The binary runs
natively in the Linux subsystem and can scan Windows filesystem paths
mounted under `/mnt/c/`.

---

## Build options

```bash
# Default optimised build (OpenMP enabled)
make

# Debug build (bounds checking, backtraces)
make debug

# Single-threaded (no OpenMP)
make OPENMP_FLAGS=""

# Verbose output during compilation
make V=1

# Clean build artifacts
make clean

# Self-test: count FLOC's own source
make test
```

---

## Verifying the build

```bash
# Should print version
./floc --version

# Should count the FLOC source files
./floc src/

# Expected output (approximate):
# -----------------------------------------------------------------------
# Language          files    blank  comment     code
# -----------------------------------------------------------------------
# Fortran 90            5      182      325     1336
# C                     1       12       33       48
# -----------------------------------------------------------------------
# SUM:                  6      194      358     1384
# -----------------------------------------------------------------------
```

---

## Thread count tuning

FLOC uses all logical CPU cores by default. Override with:

```bash
# Use exactly 4 threads
OMP_NUM_THREADS=4 ./floc .

# Check how many threads are being used
OMP_DISPLAY_ENV=TRUE ./floc . 2>&1 | grep NUM_THREADS
```

---

## Troubleshooting

**Error: `libgomp.so.1: cannot open shared object file`**
→ Install `libgomp`: `sudo apt install libgomp1`

**Error: `ld: library not found for -lomp`** (macOS)
→ Install libomp: `brew install libomp`
→ Then rebuild: `FC=gfortran-14 CC=gcc-14 make`

**Wrong gfortran version on macOS**
→ Check: `which gfortran` and `gfortran --version`
→ If it points to Apple's stub, use `FC=gfortran-14 make` (or whichever
  version you installed)

**Segfault on very large repos**
→ Increase stack size: `ulimit -s unlimited && ./floc /big/repo`
→ Or reduce parallelism: `OMP_NUM_THREADS=1 ./floc /big/repo`
