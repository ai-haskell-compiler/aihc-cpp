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

GHC does not preprocess Haskell itself: it invokes an external C preprocessor
with a fixed set of flags, both baked into `$(ghc --print-libdir)/settings` when
GHC was built and reported by `ghc --info`. That command is what "against GHC"
means here.

It is not always `gcc`, which is why the harness reads it from `ghc --info`
rather than hardcoding it. The two GHC 9.12.4 installs on the machine this was
developed on disagree: a ghcup build says `gcc`, while a Nix build names an
absolute path to a `clang` wrapper — and on macOS `/usr/bin/gcc` is itself
Apple clang. Users can also override it per-invocation with `-pgmP`.

There are two layers, because they answer different questions.

```bash
just bench
```

In-process, aihc-cpp against [cpphs], the other pure-Haskell C preprocessor.
Both are called as libraries on the same preloaded bytes with results forced to
normal form, so nothing but preprocessing is timed. This is the layer to watch
for regressions.

```bash
just bench-ghc
```

Process against process, aihc-cpp against GHC's C preprocessor. Requires
`hyperfine`, which the dev shell provides.

### What makes the comparison fair

A one-shot process spends most of its wall clock not preprocessing, and the two
sides do not pay the same fixed cost — an RTS is not a compiler driver. Timing
`aihc-cpp file.hs` against `cpp file.hs` on a 100KB input measures startup, and
gets the answer backwards: by raw wall clock aihc-cpp looks 1.6x *faster*, while
the preprocessing itself is several times slower. The harness therefore:

- **Gates on output parity.** Each side's output is normalised — line markers
  resolved to explicit positions, blank lines and interior whitespace dropped —
  and diffed before anything is timed. Inputs the two disagree on are reported
  and excluded, because tools producing different output are not doing the same
  work. Note this gate is deliberately looser than the correctness oracle in
  `test/`, which compares exactly; parity here only decides what is comparable.
- **Excludes known-divergent inputs by design.** aihc-cpp is Haskell-aware and
  will not expand macros inside Haskell block comments or string literals, which
  GHC's C preprocessor happily does. That case is benchmarked in-process only,
  and reported rather than hidden.
- **Runs both sides the same way.** A fresh process reading a file and writing
  to stdout. Neither side gets credit for being a library.
- **Subtracts each side's own startup.** Measured by copying a file through
  untouched (aihc-cpp) and preprocessing an empty file (GHC's preprocessor).
- **Scales the corpus up** (`AIHC_CPP_BENCH_SCALE`, default 10x) so the work
  being measured survives that subtraction, and flags rows where it did not.

The corpus is generated, deterministic, and weighted towards the case that
dominates real modules: thousands of lines the preprocessor merely copies, with
a few directives at the top. It is written under `dist-newstyle/`, away from the
directories the formatter and linter walk — it is megabytes of generated Haskell,
and hlint follows `#include` directives, so linting it costs orders of magnitude
more memory than running the benchmarks does. Set `AIHC_CPP_BENCH_CORPUS` to
point either layer at a directory of real-world modules instead.

Both benchmark binaries are built with an RTS heap cap (`-M512m`), so an
oversized corpus fails with a heap-overflow message rather than exhausting the
machine.

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
