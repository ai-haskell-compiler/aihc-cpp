# Stackage sweep results

Every CPP-using module in a pinned Stackage snapshot, preprocessed once by each
tool. Regenerated weekly by `.github/workflows/benchmark.yml`, which opens a
pull request with the new table.

The workflow skips the sweep entirely when nothing has landed on the default
branch since this file was last written — the results cannot have changed, and
the corpus is a gigabyte of downloads. A manual run from the Actions tab goes
ahead regardless.

**Read the counts, not the clock.** `ok`, `errored`, `crashed` and `MiB out` are
deterministic: a change in them means a change in behaviour, and is worth
looking into. The timings come from a single pass on a shared CI runner and
move by 10% or more between runs for reasons that have nothing to do with the
code. For timings worth quoting, run `just bench-stackage-sweep` locally a few
times and take medians.

- Snapshot: `lts-24.58` (GHC 9.10.3)
- Predefined macros: `__GLASGOW_HASKELL__=910`, `x86_64_HOST_ARCH`, `linux_HOST_OS`
- Corpus: 5802 CPP-using modules, 71 MiB, from 3404 packages

<!-- AUTO-GENERATED: START stackage-sweep -->
```
tool              ok       errored  crashed  seconds    MiB out    MiB/s
--------------------------------------------------------------------------
aihc-cpp          5734     68       0        3.30       71.4       21.8
hpp               5575     0        227      35.51      64.6       2.0
cpphs             5773     0        29       4.33       71.0       16.6
(read only)       5802     0        0        0.13       71.8       552.3
(read + String)   5802     0        0        0.68       71.8       105.6
```
<!-- AUTO-GENERATED: END stackage-sweep -->

Baseline recorded locally on an M-series Mac with GHC 9.12.4, medians of three
passes. The first CI run will replace it with numbers from an `ubuntu-24.04`
runner, which will be slower in absolute terms.

## Reading the columns

- **ok** — preprocessed with nothing to report.
- **errored** — produced output but reported a problem in the source. Only
  aihc-cpp distinguishes this; the other two throw instead.
- **crashed** — produced nothing.

The three do not agree on what is fatal. An unresolvable `#include` stops hpp
and cpphs but not aihc-cpp, so a difference in these columns is often a
difference of policy rather than of capability. What matters is a column
*moving* between runs of the same tool.

`(read only)` and `(read + String)` are not competitors: they measure reading
the corpus, and reading it plus the `String` conversion cpphs's API needs.
Subtract the matching one from a tool for a like-for-like figure.
