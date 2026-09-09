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

## Benchmarking

```bash
just bench
```

Measures raw throughput against the other two pure-Haskell C preprocessors on
Hackage, [hpp] and [cpphs]. All three run in-process as libraries, on the same
preloaded bytes, with output forced to normal form, so the only thing timed is
preprocessing — no process startup, no reading the entry file, no lazy IO left
unevaluated.

Indicative figures on an M-series Mac, GHC 9.12.4:

| case | aihc-cpp | hpp | cpphs |
| --- | --- | --- | --- |
| passthrough | 2.45 ms | 57.7 ms | 3.03 ms |
| conditionals | 2.87 ms | 46.0 ms | 6.55 ms |
| macros | 9.39 ms | 142 ms | 10.9 ms |
| literals | 6.26 ms | 69.4 ms | 4.19 ms |
| includes | 14.2 ms | 164 ms | 13.3 ms |

The corpus is generated, deterministic, and weighted towards the case that
dominates real modules: thousands of lines the preprocessor merely copies, with
a few directives at the top. Set `AIHC_CPP_BENCH_CORPUS` to point it at a
directory of real-world modules instead.

The benchmark does not check that the three agree, and is not meant to.
Preprocessing Haskell is under-specified — the implementations differ on comment
handling, on rescanning, on what survives inside a literal — so demanding
equivalence would mean either dropping the interesting inputs or holding
aihc-cpp to another implementation's accidents. Behaviour is pinned down by the
test suite, which compares against cpphs as an oracle; this measures speed. The
output sizes printed before the timings are a sanity check that the three are
doing comparable amounts of work, not a contract.

There is deliberately no comparison against the C preprocessor GHC invokes.
Running it means forking a process, and that dominates: on a 100KB input the
fork and startup cost several times more than the preprocessing, so the
measurement mostly reports how expensive it is to start a compiler driver.

The corpus is written under `dist-newstyle/`, away from the directories the
formatter and linter walk — it is megabytes of generated Haskell, and hlint
follows `#include` directives, so linting it costs orders of magnitude more
memory than running the benchmarks does. The benchmark binary carries an RTS
heap cap (`-M512m`) so a corpus pointed somewhere unexpected fails with a
heap-overflow message rather than exhausting the machine.

[hpp]: https://hackage.haskell.org/package/hpp
[cpphs]: https://hackage.haskell.org/package/cpphs

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
