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
preloaded bytes, with output forced, so the only thing timed is preprocessing —
no process startup, no reading the entry file, no lazy IO left unevaluated.

### Real-world corpus

Point the benchmark at a directory of Haskell source and it will sample the
CPP-using modules under it:

```bash
AIHC_CPP_BENCH_CORPUS=/path/to/checkout just bench
```

Over 178 modules (2.2 MB) sampled from 211 Hackage packages, on an M-series Mac
with GHC 9.12.4:

| | time | modules preprocessed | output |
| --- | --- | --- | --- |
| aihc-cpp | 87.8 ms | 178 / 178 | 2104 KiB |
| cpphs | 136 ms | 175 / 178 | 2107 KiB |
| hpp | 664 ms | 151 / 178 | 1149 KiB |

Read the failure column alongside the times: real modules reference headers that
are absent and macros that are never defined, the three tools disagree about
which of those is fatal, and a tool that gives up early does less work. hpp is
slowest despite producing a little over half the output.

The sample is bounded by `AIHC_CPP_BENCH_MAX_BYTES` (2 MB by default), because
the corpus is held in memory three times over and a Haskell `String` costs
upwards of sixteen bytes per character. Modules are taken at an even stride
through the sorted file list, so the sample spans the tree rather than stopping
inside whichever package sorts first, and the same modules are chosen every run.

### Generated corpus

With no `AIHC_CPP_BENCH_CORPUS` set, the benchmark generates a deterministic
corpus of its own under `dist-newstyle/`. It is cheap and stable, which makes it
useful for spotting regressions, but it is artificial:

| case | aihc-cpp | hpp | cpphs |
| --- | --- | --- | --- |
| passthrough | 2.45 ms | 57.7 ms | 3.03 ms |
| conditionals | 2.87 ms | 46.0 ms | 6.55 ms |
| macros | 9.39 ms | 142 ms | 10.9 ms |
| literals | 6.26 ms | 69.4 ms | 4.19 ms |
| includes | 14.2 ms | 164 ms | 13.3 ms |

Measured over 1,631 CPP-using modules from 211 Hackage packages, real code has a
median size of 6.2 KB with 3.5% directive lines; conditionals dominate the
directive mix (`#if` and `#endif` together outnumber `#define` more than ten to
one); `__GLASGOW_HASKELL__`, `MIN_VERSION_base` and `mingw32_HOST_OS` account
for most macro references, nearly all inside `#if` conditions rather than
expanded into the output; and a module that includes anything usually includes
one or two headers.

So `passthrough` and `conditionals` resemble real code, while `macros` (a
function-like macro expanded on every line) and `includes` (24 included files)
are far heavier than anything real. They isolate a cost usefully and mislead if
read as a workload. Use the real-world corpus for throughput claims.

### What is not measured

The benchmark does not check that the three tools agree, and is not meant to.
Preprocessing Haskell is under-specified — the implementations differ on comment
handling, on rescanning, on what survives inside a literal — so demanding
equivalence would mean either dropping the interesting inputs or holding
aihc-cpp to another implementation's accidents. Behaviour is pinned down by the
test suite, which compares against cpphs as an oracle; this measures speed. The
output sizes reported before the timings are a sanity check that the tools are
doing comparable amounts of work, not a contract.

There is also no comparison against the C preprocessor GHC invokes. Running it
means forking a process, and on inputs this size the fork and startup cost
several times more than the preprocessing, so the measurement would mostly
report how expensive it is to start a compiler driver.

The generated corpus is written under `dist-newstyle/`, away from the
directories the formatter and linter walk — it is megabytes of generated
Haskell, and hlint follows `#include` directives, so linting it costs orders of
magnitude more memory than running the benchmarks does. The binary carries an
RTS heap cap (`-M512m`) so an oversized corpus fails with a heap-overflow
message rather than exhausting the machine.

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
