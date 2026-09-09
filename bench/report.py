#!/usr/bin/env python3
"""Turn hyperfine JSON into a startup-adjusted comparison table.

Wall-clock time for a one-shot process is mostly not preprocessing. Spawning
the aihc-cpp binary starts a Haskell RTS; spawning GHC's preprocessor starts a
compiler driver. Neither cost belongs in a preprocessing measurement, and they
are not equal, so reporting raw times would compare the two runtimes rather
than the two preprocessors.

This script subtracts each side's own measured startup from its own timings and
reports what is left, as time and as throughput. The raw numbers are printed
too, because they are what a caller shelling out per file would actually pay.

Usage: report.py LABEL... -- SIZE... -- JSON...
The first triple must be the startup baseline, with size 0.
"""

import json
import sys


def split_args(argv):
    first = argv.index("--")
    second = argv.index("--", first + 1)
    return argv[:first], argv[first + 1 : second], argv[second + 1 :]


def load(path):
    """Return {name: (mean_seconds, stddev_seconds)} for one hyperfine run."""
    with open(path) as handle:
        data = json.load(handle)
    return {
        result["command"]: (result["mean"], result.get("stddev") or 0.0)
        for result in data["results"]
    }


def fmt_ms(seconds):
    return f"{seconds * 1000:7.2f}"


def main():
    labels, sizes, paths = split_args(sys.argv[1:])
    if not (len(labels) == len(sizes) == len(paths)) or not labels:
        print(__doc__, file=sys.stderr)
        return 2

    startup = load(paths[0])
    base_ours = startup["aihc-cpp"][0]
    base_theirs = startup["ghc-cpp"][0]

    print("Fixed per-process cost (measured, subtracted below)")
    print(f"  aihc-cpp {fmt_ms(base_ours)} ms   ghc-cpp {fmt_ms(base_theirs)} ms")
    print()
    header = (
        f"{'case':<14}{'size':>9}"
        f"{'aihc raw':>11}{'ghc raw':>10}"
        f"{'aihc net':>11}{'ghc net':>10}"
        f"{'net MB/s':>10}{'ghc MB/s':>10}{'ratio':>8}"
    )
    print(header)
    print("-" * len(header))

    for label, size, path in list(zip(labels, sizes, paths))[1:]:
        size = int(size)
        run = load(path)
        raw_ours, sd_ours = run["aihc-cpp"]
        raw_theirs, sd_theirs = run["ghc-cpp"]
        net_ours = raw_ours - base_ours
        net_theirs = raw_theirs - base_theirs

        # A net time smaller than the noise in the baseline is not a
        # measurement; say so rather than printing a ratio built on it.
        noisy = net_ours <= 2 * sd_ours or net_theirs <= 2 * sd_theirs

        mb = size / 1e6
        mbps_ours = mb / net_ours if net_ours > 0 else float("nan")
        mbps_theirs = mb / net_theirs if net_theirs > 0 else float("nan")
        ratio = net_theirs / net_ours if net_ours > 0 else float("nan")

        print(
            f"{label:<14}{size:>9}"
            f"{fmt_ms(raw_ours):>11}{fmt_ms(raw_theirs):>10}"
            f"{fmt_ms(net_ours):>11}{fmt_ms(net_theirs):>10}"
            f"{mbps_ours:>10.1f}{mbps_theirs:>10.1f}"
            f"{ratio:>7.2f}x" + ("  (noisy)" if noisy else "")
        )

    print()
    print("raw = wall clock, including process startup on both sides.")
    print("net = raw minus that side's own measured startup: the preprocessing.")
    print("ratio > 1 means aihc-cpp is faster than the preprocessor GHC invokes.")
    print("Rows marked (noisy) have a net time comparable to run-to-run variance;")
    print("raise AIHC_CPP_BENCH_SCALE or use `cabal bench micro` for those.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
