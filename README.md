![Antelope](https://git.spectoria.dev/repo-avatars/9921718997d5fba2504ffe1e7dbf17d1a549a95ee0e2cd05e5a7d8ec0fe4e171)

# Antelope

**A ground-up replacement for GNU Make and GNU Autotools, written in D.**

Antelope offers direct, high-fidelity compatibility with existing Makefiles
while providing a modern, fast, and correct build system. It targets
99th-percentile GNU Make compatibility — every quirk, feature, and bug that
real-world Makefiles depend on is catalogued and emulated.

## Why Antelope?

- **Compatibility first** — runs real-world Makefiles, especially those generated
  by GNU Autotools. This is the #1 design constraint.
- **Single binary** — no m4, no shell scripts, no generated intermediates.
  One `antelope` binary replaces `make`, `autoconf`, `automake`, and `libtool`.
- **Correctness** — DAG-accurate dependency resolution with no spurious rebuilds.
  Timestamp comparison is monotonic and race-condition safe.
- **Performance** — compiled D binary with parallel scheduling, lazy evaluation,
  and microsecond startup times.
- **Two modes, cleanly separated** — native mode is explicit by design; GNU
  compatibility is activated via a single `-gnu` flag.

## Quick Start

### Building

```sh
# Development build (fast compile, slower runtime)
dub build

# Release build (slower compile, fast runtime)
dub build --compiler=ldc2

# Run tests
dub test

# Run with full GNU Make compatibility
dub run -- -gnu

# Run a specific Makefile
dub run -- -gnu -f MyMakefile target1 target2
```

### CLI Usage

```
antelope <subcommand> <options> --[flags]
```

| Command | Description |
|---------|-------------|
| `antelope` | Run the build (default subcommand) |
| `antelope build` | Explicit build invocation |
| `antelope hunt` | Intelligent Makefile → Antefile converter (late-stage) |
| `antelope configure` | Autotools configure.ac replacement (future) |

| Flag | Description |
|------|-------------|
| `-gnu` | Enable full GNU Make compatibility mode |
| `-f <path>` | Specify a build file |
| `-j <N>` | Run N jobs in parallel |
| `-n` | Dry run (print commands without executing) |
| `-C <dir>` | Change to directory before reading build files |
| `-d` | Debug output |
| `-P` | POSIX conformance mode |

## Two Modes

### Native Mode (default)

Antelope's native mode is explicit by design — no implicit rules, no automatic
variables, no magic. The build file is an `antefile` or `antelope` file.

```make
# antefile — explicit, predictable, debuggable
hello: hello.o
    gcc -o hello hello.o

hello.o: hello.c
    gcc -c hello.c
```

### GNU Mode (`-gnu`)

Pass `-gnu` and Antelope becomes GNU Make — `Makefile` / `makefile` reading,
implicit rules, automatic variables (`$@`, `$<`, `$^`), VPATH, pattern rules,
conditionals, and the entire GNU Make compatibility surface.

```sh
antelope -gnu -j8   # Run Makefile with 8 parallel jobs
```

## Architecture

Antelope is organized into clean layers:

| Layer | Purpose |
|-------|---------|
| **CLI** | Subcommand dispatch, argument parsing, help output |
| **Parser** | Lexer → recursive-descent parser → AST |
| **Evaluator** | AST walking, variable expansion, conditionals, built-in functions |
| **Build** | Dependency graph, topological scheduling, recipe execution |
| **Shell** | Command parsing, environment management, subprocess execution |
| **Filesystem** | Globbing, timestamp comparison, path resolution |
| **Compatibility** | GNU Make feature emulation (13 modules) |
| **Diagnostics** | Structured errors, warnings, log-level output |

See [docs/architecture.md](docs/architecture.md) for the full design.

## GNU Make Compatibility

Antelope targets GNU Make versions 3.81 through 4.4 with feature-complete
emulation of:

- Automatic variables (`$@`, `$<`, `$^`, `$*`, `$?`, `$%`, `$+`, `$|`)
- ~30 built-in implicit rules (C, C++, Fortran, lex, yacc, archive management)
- Pattern rules (`%.o: %.c`) and suffix rules (`.c.o:`)
- VPATH / vpath directory search
- Target-specific and pattern-specific variable assignments
- Order-only prerequisites (`|` separator)
- Secondary expansion (`.SECONDEXPANSION`)
- Include directives with makefile remaking and restart
- Recursive `$(MAKE)` with MAKEFLAGS propagation and jobserver protocol
- Parallel execution (`-jN`, `.NOTPARALLEL`, `.WAIT`, `.JOBS`)
- Conditionals (`ifeq`/`ifneq`/`ifdef`/`ifndef`)
- Functions (`$(shell ...)`, `$(wildcard ...)`, `$(patsubst ...)`, etc.)
- All documented behavioral quirks and edge cases

See [docs/compatibility.md](docs/compatibility.md) for the full compatibility matrix.

## Project Status

**Phase:** Early scaffolding. Stub modules with type definitions and structural
skeleton. Core implementation (lexer, parser, evaluator, build engine) is the
active development focus.

## Documentation

- [Architecture](docs/architecture.md) — system design and key decisions
- [Compatibility](docs/compatibility.md) — GNU Make feature coverage
- [Manual](docs/manual.md) — user guide and reference
- [Contributing](CONTRIBUTING.md) — how to contribute

## License

BSD 3-Clause. See [LICENSE](LICENSE) for the full text.
