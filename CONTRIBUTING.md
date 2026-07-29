# Contributing to Antelope

## Getting Started

### Prerequisites

- A D compiler: [DMD](https://dlang.org/download.html) (fast compile, for
  development) or [LDC](https://github.com/ldc-developers/ldc) (fast runtime,
  for release builds).
- [Dub](https://code.dlang.org/getting_started) — the D package manager
  (bundled with DMD).

### Setup

```sh
git clone https://git.spectoria.dev/specter/antelope.git
cd antelope
dub build                # Verify the project builds
dub test                 # Run the test suite
```

### Build Commands

| Command | Purpose |
|---------|---------|
| `dub build` | Build with DMD (fast compile, development) |
| `dub build --compiler=ldc2` | Build with LDC (optimized, release) |
| `dub run` | Build and run |
| `dub test` | Run all unit tests |
| `dub test --compiler=ldc2` | Run tests with LDC |

## Project Structure

```
antelope/
├── dub.json                  Package descriptor
├── source/antelope/          Source code
│   ├── app.d                 Entry point
│   ├── cli/                  Command-line interface
│   ├── parser/               Lexer, parser, AST
│   ├── evaluator/            AST evaluation, expansion
│   ├── build/                Dependency graph, scheduling, execution
│   ├── shell/                Command parsing, environment, subprocess
│   ├── filesystem/           File I/O, glob, timestamps, paths
│   ├── compatibility/        GNU Make emulation (13 modules)
│   └── diagnostics/          Errors, warnings, structured output
├── tests/                    Test suites (mirrors source layout)
├── examples/                 Example build files
└── docs/                     Design documentation
```

Before diving in, read:
- [docs/architecture.md](docs/architecture.md) — system design and key decisions
- [docs/compatibility.md](docs/compatibility.md) — GNU Make feature coverage

## Coding Conventions

### D Language Style

**Naming:**
- Types (structs, enums, classes): `PascalCase` (`AstNode`, `TargetKind`)
- Functions: `camelCase` (`parseCommand`, `resolveDependencies`)
- Variables: `camelCase` (`lexerState`, `targetName`)
- Enum members: `snake_case` (`notparallel`, `fileNotFound`)
- Constants: `camelCase` with `static immutable` or `enum`
- Modules: `snake_case` matching directory structure (`antelope.parser.ast`)

**Documentation:**
- All public declarations get `///` doc comments (ddoc format)
- Module-level doc comment at the top of each file
- Struct fields get per-field `///` comments
- Complex algorithms get an explanation or example

**Imports:**
- Explicit selective imports preferred over wildcard imports
- Group: standard library imports first, then project imports
- Within project: order by module depth (shallowest first)

**Error handling:**
- Return error structs over throwing exceptions for expected failures
- Use `ErrorKind` enum for categorized errors
- Exceptions only for truly exceptional conditions (OOM, unexpected state)
- No `assert(false)` — use structured error reporting

**Memory:**
- Use D's GC freely (not a systems-level binary)
- Avoid manual memory management unless in hot paths
- Prefer slices (`[]`) over dynamic arrays for function parameters

### Code Organization

- One logical concept per module
- Maximum ~300 lines per module (split if longer)
- Module name matches file name exactly
- Public API at the top of the file, implementation details below

### Compat-Reader Pattern

Modules that have both "clean" and "compat" behavior gate the compat path
behind the `-gnu` flag:

```d
/// Pure implementation (Antelope-native behavior)
string expand(string input) { ... }

/// Compat path (call for GNU Make emulation, enabled via -gnu)
string expandCompat(string input, GnuMakeCompat compat)
{
    if (compat.enableGnuBuiltins)
        return expandGnuStyle(input);
    return expand(input);
}
```

This keeps the clean implementation readable while providing compatibility
as a layer on top.

### Module Template

```d
/// One-line summary of what this module does.
///
/// Extended description with details, edge cases, and
/// references to related modules or GNU Make behavior.
module antelope.layer.module;  // Path from source/

import std.algorithm;
import antelope.diagnostics.errors;

// --- Types ---

/// Brief doc for the primary type.
struct MyType
{
    string name;
    size_t count;
}

// --- Public API ---

/// Calculate something from input.
/// Returns: description of return value.
ReturnType doThing(InputType input)
{
    return ReturnType();
}

// --- Implementation ---

private void helperFunction()
{
}
```

## Testing

### Test Layout

```
tests/
├── parser/         Lexer and parser unit tests
├── evaluator/      Expansion and conditional tests
├── build/          Graph, scheduling, and execution tests
├── compatibility/  GNU Make behavior conformance tests
└── integration/    End-to-end Makefile execution tests
```

### Testing Philosophy

- **Unit tests** for each module in isolation (mock dependencies where needed)
- **Snapshot tests** for parser output (parse Makefile → compare AST)
- **Compat tests** — run real GNU Make on a test Makefile, then run Antelope,
  and compare outputs (stdout, exit code, files produced)
- **Regression tests** for every quirk and bug fix

### Running Tests

```sh
dub test                          # All tests
dub test --compiler=ldc2          # All tests with LDC
```

Tests are `unittest` blocks within modules or in separate test files.
`dub test` discovers and runs all `unittest` blocks.

### Test Structure Pattern

```d
// tests/parser/lexer_test.d
unittest
{
    auto lexer = Lexer("target: prereq\n\trecipe line");
    assert(lexer.nextToken().type == TokenType.identifier);
    assert(lexer.nextToken().type == TokenType.colon);
    // ...
}
```

## Design Principles

### Compatibility Always Comes First

This is the #1 design constraint. Everything yields to compatibility.
Antelope must flawlessly run real-world Makefiles, especially those
generated by GNU Autotools. If a Makefile works with GNU Make, it must
work with Antelope.

### Explicitness over Implicit

Antelope's native mode is explicit by design. Implicit behaviors (pattern
rules, automatic variables, derived prerequisites) are only enabled when
explicitly requested — either via `-gnu` for full GNU compat, or via
per-feature opt-ins. This keeps builds predictable and debuggable.

### Correctness First

Dependency resolution must be DAG-accurate with no spurious rebuilds.
Timestamp comparison must be monotonic and race-condition safe.

### Structs over Classes

Prefer D structs over classes for data types — value semantics, stack
allocation, better cache locality. Exceptions: subsystems that genuinely
need polymorphism or reference semantics (e.g., jobserver coordination).

### The `-gnu` Flag as Mode Switch

The `-gnu` flag is the architectural cornerstone. It is NOT just a feature
flag — it changes behavior at every layer of the system, from which build
file is read to which parser rules, implicit rules, and variables are
active. The flag is checked at the top level and threaded through as
configuration, not as a global variable.

## Commit Guidelines

- Write commits in imperative mood: "Add lexer tokenization for recipe lines"
- Keep commits atomic — one logical change per commit
- Reference relevant issues or design docs where applicable
- No AI-generated commit messages — write meaningful, human-authored messages

## Questions?

Open an issue or start a discussion on the project repository.
