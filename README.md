# FLOC — Fast Lines Of Code Counter

A **production-quality, cloc-compatible** source-code line counter written in
Fortran 90/2003 with OpenMP parallelism. Designed to scan repositories with
millions of files **orders of magnitude faster** than the Perl-based `cloc`
tool by eliminating per-line overhead, using single-call buffered I/O, and
parallelising across all available CPU cores.

---

## Table of Contents

1. [Quick start](#quick-start)
2. [Performance design](#performance-design)
3. [Language detection](#language-detection)
4. [Comment & code-line detection](#comment--code-line-detection)
5. [Parallelism](#parallelism)
6. [Build instructions](#build-instructions)
7. [Usage & options](#usage--options)
8. [Supported languages](#supported-languages)
9. [Accuracy notes](#accuracy-notes)

---

## Quick start

```bash
# Linux / macOS
make
./floc .

# Scan a specific directory
./floc ~/repos/linux-kernel

# Only Python and Go
./floc --include-lang=Python,Go .

# Skip test directories
./floc --exclude-dir=test,tests,spec .
```

Sample output (cloc-compatible format):

```
------------------------------------------------------------------------
Language              files        blank    comment       code
------------------------------------------------------------------------
Python                   33         1226       1026       3017
JavaScript               18          834        512       8204
TypeScript                9          321        198       4110
Go                        6          215         87       2033
------------------------------------------------------------------------
SUM:                     66         2596       1823      17364
------------------------------------------------------------------------
```

---

## Performance design

### Why is FLOC much faster than cloc?

| Factor | cloc (Perl) | FLOC (Fortran) |
|---|---|---|
| I/O model | `readline()` — one syscall per line | `READ(STREAM)` — one syscall per file |
| Concurrency | Single-threaded | OpenMP: N files in parallel |
| Pattern matching | Perl regex engine | Hand-rolled state machine (integer opcodes) |
| Memory | String objects per line | Pre-allocated byte buffer, reused |
| Extension lookup | Hash lookup | Sorted array + binary search |
| Comment detection | Regex | Explicit state transitions |

#### Buffered single-call file read

```fortran
OPEN(NEWUNIT=lu, FILE=TRIM(path), ACCESS='STREAM', FORM='UNFORMATTED', ...)
INQUIRE(UNIT=lu, SIZE=fsize)
READ(lu) buf(1:nbytes)      ! entire file in ONE READ call
```

A single `read()` syscall is typically 50–200× faster than N `readline()`
calls for an N-line file because:
- No repeated kernel↔userspace transitions per line
- No memory allocation per line
- No UTF-8/newline scanning by the runtime

#### State machine vs regex

The counting hot loop is a `SELECT CASE` on a small integer (`state`).
Modern CPUs predict the dominant case (usually "normal code, state=0") after
the first few hundred iterations. A Perl regex engine has fixed overhead per
match regardless of pattern length.

#### Zero allocation inside the hot loop

`count_*_style` routines take a `CHARACTER(LEN=1), INTENT(IN) :: buf(:)`
slice. No Fortran string temporaries are created. The line-flag register `lf`
is a 2-bit INTEGER on the stack.

---

## Language detection

Language detection is done **by file extension** (with special-case
whole-file-name recognition for `Makefile`, `Dockerfile`, etc.).

### Extension table

All ~130 extensions are stored in two parallel arrays
(`EXT_TABLE`, `EXT_LANG`) that are **insertion-sorted alphabetically** at
startup (once). Every call to `get_language_id()` performs an **O(log N)
binary search** — typically ~7 comparisons for 130 entries.

```fortran
FUNCTION binary_search_ext(ext) RESULT(lang_id)
  lo = 1;  hi = NUM_EXT
  DO WHILE (lo <= hi)
    mid = (lo + hi) / 2
    IF (TRIM(EXT_TABLE(mid)) == ext) THEN
      lang_id = EXT_LANG(mid);  RETURN
    ELSE IF (TRIM(EXT_TABLE(mid)) < ext) THEN
      lo = mid + 1
    ELSE
      hi = mid - 1
    END IF
  END DO
END FUNCTION
```

### Special filenames (no extension)

`Makefile`, `GNUmakefile`, `Dockerfile`, `Gemfile`, `Vagrantfile`, etc. are
matched before the extension search.

---

## Comment & code-line detection

### Line classification rules (identical to cloc)

| Line content | Classification |
|---|---|
| Only whitespace | **blank** |
| Comment text with no code | **comment** |
| Any non-whitespace outside a comment | **code** (even if it also has a comment) |

This means `x = 1; // set x` counts as **1 code line**, not a comment line.

### Per-style state machines

Each comment style maps to a dedicated counting routine. The state variable
`state` transitions on individual bytes; `lf` is a 2-bit "line flags" register:

```
bit 0 (HAS_CODE)    ← set when any non-ws char is seen outside a comment
bit 1 (HAS_COMMENT) ← set when a comment marker or comment body is seen
```

On every `\n`, `flush_line(lf, res)` classifies the line and resets `lf`.

#### CS_C (C, C++, Java, JavaScript, TypeScript, Go, Rust, …)

```
States:
  0  normal code
  1  line comment   (//)
  2  block comment  (/* … */)
  3  double-quoted string  ("…")
  4  single-quoted string  ('…')
  5  escape in "string"
  6  escape in 'string'
```

Strings (states 3–6) suppress comment detection — `"/*"` is not a comment.

#### CS_PYTHON

```
States:
  0  normal
  1  # line comment
  2  """ triple-double block
  3  ''' triple-single block
  4  "string"
  5  'string'
```

Triple-quoted strings used as docstrings are counted as comment lines when
they appear on their own lines (cloc behaviour).

#### CS_HTML

Scans for the literal four-byte prefix `<!--` to enter block-comment state,
and `-->` to leave it. All other content is code.

#### CS_RUBY / CS_PERL

`#` for inline, `=begin` / `=end` for block comments. Both markers must
appear at the start of a line (column 0).

#### CS_LUA

`--` for line comments, `--[[` / `]]` for block comments.

#### CS_FORTRAN90

`!` anywhere on a line (after code) marks the rest as a comment. Lines
starting with `!` are comment lines.

#### CS_SQL

`--` line + `/* */` block. No string suppression (SQL strings rarely contain
comment-like text).

#### CS_HASKELL

`--` line + `{- -}` block.

#### CS_NONE (JSON, Markdown, plain text)

No comment syntax. Every non-blank line is a code line. Blank lines are
counted as blank. This matches cloc's behaviour for JSON and Markdown.

---

## Parallelism

FLOC uses **OpenMP task parallelism** at the file level. The key design choice
is using OpenMP `REDUCTION` instead of `CRITICAL` sections:

```fortran
!$OMP PARALLEL DEFAULT(NONE) SHARED(...) &
!$OMP   REDUCTION(+: lang_files, lang_blank, lang_comment, lang_code) &
!$OMP   SCHEDULE(DYNAMIC, 32)
!$OMP DO
DO i = 1, flist%n
  ...
  lang_files(lid) = lang_files(lid) + 1
END DO
!$OMP END DO
!$OMP END PARALLEL
```

- **`REDUCTION(+: …)`**: OpenMP automatically creates thread-private copies of
  the accumulation arrays and merges them after the loop. This gives each
  thread a private write buffer with zero synchronisation overhead.
- **`SCHEDULE(DYNAMIC, 32)`**: Files are handed to threads in chunks of 32.
  Dynamic scheduling ensures large files (e.g. a 50k-line C file) don't create
  stragglers that delay the barrier.
- **No `CRITICAL`**: The counting state machines in `floc_counter.f90` are
  entirely free of shared mutable state.

### Thread count

OpenMP defaults to the number of logical CPUs. Override with:
```bash
export OMP_NUM_THREADS=8
./floc .
```

---

## Build instructions

### Prerequisites

| Platform | Requirement |
|---|---|
| Linux | `gfortran` ≥ 9, `gcc`, GNU `make` |
| macOS | `gfortran` (via Homebrew: `brew install gcc`), `brew install libomp` |
| Windows | MinGW-w64 with gfortran, or WSL2 using the Linux instructions |

### Linux / macOS

```bash
# Clone / download the source
git clone https://github.com/your-org/floc && cd floc

# Build (optimised, OpenMP enabled)
make

# Optional: install to /usr/local/bin
sudo make install

# Or custom prefix
make install PREFIX=~/.local
```

### macOS (Apple Silicon / Intel)

```bash
# Install dependencies
brew install gcc libomp

# Force GNU gfortran (not AppleClang)
FC=gfortran-14 CC=gcc-14 make
```

### Windows (MinGW-w64 via MSYS2)

```batch
# In an MSYS2 MINGW64 shell:
pacman -S mingw-w64-x86_64-gcc-fortran mingw-w64-x86_64-openmp

cd floc
make

floc.exe --help
```

### Windows (WSL2)

Follow the Linux instructions inside a WSL2 terminal. The resulting binary
runs natively in the WSL environment.

### Disable OpenMP (single-threaded build)

```bash
make OPENMP_FLAGS=""
```

### Verify the build

```bash
# Self-test: count FLOC's own source
make test

# Or manually
./floc src/
```

---

## Usage & options

```
floc [OPTIONS] <path> [<path> ...]
```

| Option | Description |
|---|---|
| `--exclude-dir=D[,D2,…]` | Skip directories matching these names (default: `.git`, `node_modules`, `vendor`, `__pycache__`, `dist`, `build`, `target`, …) |
| `--include-lang=L[,L2,…]` | Count only the listed languages |
| `--exclude-lang=L[,L2,…]` | Skip the listed languages |
| `--max-file-size=N` | Skip files larger than N bytes (default: 10 MB) |
| `--quiet` / `-q` | Suppress progress and timing output |
| `--by-file` | Print per-file breakdown |
| `--version` / `-v` | Print version string |
| `--help` / `-h` | Print help |

### Examples

```bash
# Count entire repo
./floc ~/repos/linux

# Count only backend languages
./floc --include-lang=Python,Go,Rust src/

# Exclude generated and vendor directories
./floc --exclude-dir=generated,vendor,.next .

# Quiet mode for scripting
lines=$(./floc --quiet . | grep SUM | awk '{print $5}')

# Multiple paths
./floc backend/ frontend/ scripts/
```

---

## Supported languages

40 languages and 130+ extensions:

C, C++, C/C++ Header, Java, JavaScript, TypeScript, Go, Python, Ruby, Perl,
Bourne Shell, Bash, HTML, XML, CSS, SCSS, SASS, LESS, JSON, YAML, TOML,
Markdown, SQL, Rust, Kotlin, Swift, PHP, C#, Fortran 90, make, Dockerfile,
Lua, Scala, R, Haskell, OCaml, Assembly, Terraform, Dart, Elixir, Groovy, Vue

---

## Accuracy notes

FLOC aims for identical output to `cloc 2.08` on all well-formed source files.
Known intentional differences:

1. **Binary file detection**: FLOC skips files with `\0` bytes by default
   (added in `count_file` via early return on binary markers).
2. **Shebang lines** (`#!/usr/bin/env python3`): Counted as code, same as
   cloc.
3. **Windows CRLF**: The state machine treats `\r` as whitespace, so Windows
   line endings are handled transparently.
4. **Files > `--max-file-size`**: Skipped entirely (cloc also has a limit).
5. **Symlinks**: Not followed (avoids infinite recursion), matching cloc.

---

## Architecture diagram

```
floc_main.f90  ─── parse_args()
                ─── collect_files()  ←── floc_cdir.f90  (C interop)
                │                    └── dir_helper.c   (opendir/readdir)
                └── OMP parallel DO
                      └── count_file()  ←── floc_counter.f90
                                        │    count_c_style()
                                        │    count_python_style()
                                        │    count_html_style()
                                        │    … (11 style routines)
                                        └── floc_lang_defs.f90
                                             get_language_id()   (binary search)
                                             LANG_CS[]           (style dispatch)
```

---

## License

MIT — do whatever you want with this code. Contributions welcome.
