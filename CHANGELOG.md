# Changelog

All notable changes to Antelope are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Project scaffolding: full module layout with type definitions and structural
  skeleton across all layers (CLI, parser, evaluator, build, shell, filesystem,
  compatibility, diagnostics).
- CLI argument parsing with subcommand dispatch (`build`, `hunt`, `configure`).
- `-gnu` flag for GNU Make compatibility mode (Makefile reading, full GNU Make
  semantics, implicit rules, automatic variables, VPATH).
- AST node, token, and error type definitions.
- Lexer, parser, and evaluator stub modules with correct signatures.
- Build engine skeleton: dependency graph, target metadata, scheduler, executor.
- Shell interface stubs: command parsing, environment management, subprocess
  execution.
- Filesystem stubs: globbing, timestamp comparison, path resolution.
- Compatibility layer: 13 modules covering the full GNU Make feature surface
  (automatic variables, implicit rules, pattern rules, VPATH, target-specific
  variables, order-only prerequisites, secondary expansion, include handling,
  submake protocol, parallel execution, quirks, POSIX conformance).
- Diagnostics framework: structured errors, warnings, and log-level output.
- Documentation: architecture overview, GNU Make compatibility reference.
- Test fixtures for integration testing (simple builds, variables, conditionals,
  include directives).
- Integration test verifying CLI argument parsing.
