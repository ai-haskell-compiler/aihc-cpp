# Haskell CPP

[![CI](https://github.com/ai-haskell-compiler/aihc-cpp/actions/workflows/nix-flake-check.yml/badge.svg)](https://github.com/ai-haskell-compiler/aihc-cpp/actions/workflows/nix-flake-check.yml)
[![GHC compatibility](https://github.com/ai-haskell-compiler/aihc-cpp/actions/workflows/minimum-ghc.yml/badge.svg)](https://github.com/ai-haskell-compiler/aihc-cpp/actions/workflows/minimum-ghc.yml)
[![Hackage](https://img.shields.io/hackage/v/aihc-cpp.svg)](https://hackage.haskell.org/package/aihc-cpp)

This component implements a pure Haskell C preprocessor used by the parser pipeline.

## Why not use an off-the-shelf CPP?

- `cpp` doesn't work with WASM, so we can't use it.
- `cpphs` is ruled out because: Nondeterministic `__DATE__` and `__TIME__` handling, can't be used without IO, LGPL license.

## Progress Tracking

Coverage is tracked with a manifest-driven corpus under:

- `test/Test/Fixtures/progress/manifest.tsv`

Current baseline:

<!-- AUTO-GENERATED: START cpp-progress -->
- `46/46` implemented (`100.00%` complete)
<!-- AUTO-GENERATED: END cpp-progress -->

## Commands

Run all cpp tests:

```bash
just test
```

Run progress summary:

```bash
just progress
```

Strict mode (non-zero on `FAIL` or `XPASS`):

```bash
just progress-strict
```

Run the complete local CI suite with `just check`, or the hermetic suite with
`nix flake check`.
