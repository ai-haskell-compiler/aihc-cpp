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
- `49/49` implemented (`100.00%` complete)
<!-- AUTO-GENERATED: END cpp-progress -->

## Benchmarking

```bash
just bench
```

Measures raw throughput against the other two pure-Haskell C preprocessors on
Hackage, [hpp] and [cpphs]. All three run in-process as libraries, on the same
preloaded bytes, with output forced, so the only thing timed is preprocessing —
no process startup, no reading the entry file, no lazy IO left unevaluated.

### Stackage corpus

The meaningful numbers come from real code. `bench/fetch-stackage.sh` fetches
package sources from a pinned Stackage snapshot (`lts-24.58`, GHC 9.10.3) into
`dist-newstyle/`; downloads are cached and resumable.

#### Full snapshot sweep

```bash
just bench-stackage-sweep
```

One pass over every CPP-using module in the snapshot — all 3,441 packages, 5,802
modules, 71 MiB of source. On an M-series Mac with GHC 9.12.4:

| tool | ok | errored | crashed | seconds | MiB out | MiB/s |
| --- | --- | --- | --- | --- | --- | --- |
| aihc-cpp | 5359 | 443 | **0** | 3.10 | 69.5 | 23.2 |
| cpphs | 5767 | 0 | 35 | 4.46 | 69.1 | 16.1 |
| hpp | 5233 | 0 | 569 | 32.47 | 57.8 | 2.2 |
| *(read only)* | 5802 | — | — | *0.14* | — | — |
| *(read + String)* | 5802 | — | — | *0.73* | — | — |

Subtract each tool's input baseline for a like-for-like figure: aihc-cpp 2.96 s
against cpphs 3.73 s, so **aihc-cpp is about 1.26x faster**, and hpp is an order
of magnitude behind both. aihc-cpp is the only one that gets through all 5,802
modules without crashing.

The three columns are not interchangeable:

- **errored** — the tool produced output but reported a problem in the source.
  Only aihc-cpp distinguishes this; the other two throw. Nearly all 443 are
  `missing include: MachDeps.h` or similar: headers a real build generates and
  a bare source tree does not have. cpphs ignores an unresolvable include
  silently, so this is a difference of policy, not of capability.
- **crashed** — the tool produced nothing. cpphs's 35 are almost all genuine
  `#error` directives it is right to stop on. hpp's 569 are mostly missing
  includes, which it treats as fatal, and that is also why it emits the least
  output.

#### Sampled benchmark

```bash
just bench-stackage
```

For regression work, `tasty-bench` statistics over a sampled subset rather than
a single pass. It fetches a stride of 400 packages by default; raise
`AIHC_CPP_STACKAGE_PACKAGES` for more (a larger count is a superset, so only
missing packages are fetched) or set it to `0` for the whole snapshot. The
sample is bounded by `AIHC_CPP_BENCH_MAX_BYTES` (8 MB by default).

Any directory of Haskell source works, not just the Stackage cache:

```bash
AIHC_CPP_BENCH_CORPUS=/path/to/checkout just bench
```

Nothing is preloaded — each tool reads each module inside the timed region — so
there is no ceiling on corpus size, and the read cost is charged to every tool
equally and quantified by the `(read only)` row. cpphs additionally needs a
`String`, which `(read + String)` measures.

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
read as a workload. Use the Stackage corpus for throughput claims.

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
