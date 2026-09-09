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

The meaningful numbers come from real code. `just bench-stackage` fetches
package sources from a pinned Stackage snapshot (`lts-24.58`, GHC 9.10.3) and
benchmarks the CPP-using modules in them:

```bash
just bench-stackage
```

The first run downloads and extracts into `dist-newstyle/`; later runs reuse it.
By default it takes a stride of 400 packages through the snapshot's 3,441, which
spans the list while keeping the download to a few hundred megabytes. Raise
`AIHC_CPP_STACKAGE_PACKAGES` for more (a larger count is a superset, so only the
missing packages are fetched) or set it to `0` for the whole snapshot.

Over 570 CPP-using modules (8.0 MB) sampled from 1,702 Stackage packages, on an
M-series Mac with GHC 9.12.4:

| | time | modules preprocessed | output |
| --- | --- | --- | --- |
| aihc-cpp | 295 ms | 569 / 570 | 7909 KiB |
| cpphs | 438 ms | 566 / 570 | 7781 KiB |
| hpp | 3.27 s | 523 / 570 | 6766 KiB |
| *(input marshalling)* | *58.9 ms* | — | — |

Two things to read alongside the times.

The failure column: real modules reference headers that are absent and macros
that are never defined, and the three tools disagree about which of those is
fatal — hpp treats a missing `#include` as an error and stops, where the other
two carry on. A tool that gives up early does less work, so hpp is slowest while
producing about six sevenths of the output. (aihc-cpp's one failure is a bug: it
throws rather than reporting a diagnostic on a module that is Latin-1 rather
than UTF-8.)

The marshalling row: cpphs takes a `String`, so its time includes converting the
input from bytes. That conversion is measured on its own and is not
preprocessing — subtract it for a like-for-like comparison, which puts cpphs at
roughly 379 ms against aihc-cpp's 295 ms. It is charged rather than preloaded
because holding the whole corpus as a `String` costs around seventy bytes per
source character once the collector's copying space is counted; preloading it
capped the corpus at a few hundred modules, and the resulting GC pressure made
cpphs look *slower* than it does now.

Any directory of Haskell source works, not just the Stackage cache:

```bash
AIHC_CPP_BENCH_CORPUS=/path/to/checkout just bench
```

The sample is bounded by `AIHC_CPP_BENCH_MAX_BYTES` (8 MB by default); outputs
and collector headroom scale with it, and 16 MB samples about eleven hundred
modules at close to the binary's heap cap. Modules are taken at an even stride
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
