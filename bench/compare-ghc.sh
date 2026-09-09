#!/usr/bin/env bash
#
# Compare aihc-cpp against the C preprocessor GHC actually uses.
#
# GHC does not preprocess Haskell itself: it shells out to a C preprocessor with
# a fixed set of flags, both of which it reports through `ghc --info`. This
# script reads that configuration rather than hardcoding it, so what gets timed
# is whatever *this* GHC would really run.
#
# Three things make the comparison fair:
#
#   1. Parity gate. Before anything is timed, each candidate's output is
#      normalised (line markers resolved, blank lines and interior whitespace
#      dropped) and diffed. An input the two tools disagree on is not an input
#      they can be compared on; it is reported and excluded rather than being
#      silently benchmarked.
#   2. Like for like. Both sides run as a fresh process reading a file and
#      writing to stdout, so neither side gets credit for being a library.
#   3. Startup subtracted. Spawning a process costs more than preprocessing
#      100KB, and the two binaries do not cost the same to spawn: an RTS is not
#      a compiler driver. `driver baseline` copies a file through untouched, and
#      GHC's preprocessor is run on an empty file, giving each side's fixed
#      cost. The summary reports time with that cost removed, which is the only
#      number that describes preprocessing rather than the operating system.
#
# The corpus is also scaled up here (AIHC_CPP_BENCH_SCALE), so that the work
# being measured is large enough to survive the subtraction. It is written under
# dist-newstyle rather than into the source tree: it is megabytes of generated
# Haskell, and a linter walking it costs far more memory than anything the
# benchmark itself does.
#
set -euo pipefail

corpus="${AIHC_CPP_BENCH_CORPUS:-dist-newstyle/bench-corpus-process}"
runs="${AIHC_CPP_BENCH_RUNS:-20}"
scale="${AIHC_CPP_BENCH_SCALE:-10}"

for tool in hyperfine python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is not installed (nix develop provides it)" >&2
    exit 1
  fi
done

driver="$(cabal list-bin bench:driver | tail -1)"
"$driver" gen "$corpus" "$scale"

# Ask GHC how it preprocesses Haskell, instead of assuming.
ghc_info() {
  ghc --info | tr -d '\n' | sed -n "s/.*(\"$1\",\"\([^\"]*\)\").*/\1/p"
}
cpp_command="$(ghc_info 'Haskell CPP command')"
cpp_flags="$(ghc_info 'Haskell CPP flags')"

if [ -z "$cpp_command" ]; then
  echo "error: could not read 'Haskell CPP command' from ghc --info" >&2
  exit 1
fi

echo "GHC:             $(ghc --numeric-version)"
echo "GHC Haskell CPP: $cpp_command $cpp_flags"
echo "corpus:          $corpus (scale ${scale}x)"
echo

# -x c is needed because the inputs are .hs files; GHC passes the same hint.
ghc_cpp() {
  # shellcheck disable=SC2086 # cpp_flags is a flag list and must word-split.
  "$cpp_command" $cpp_flags -I "$corpus" -x c "$1"
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
empty="$workdir/empty.hs"
: >"$empty"

status=0
comparable=()

echo "== parity =="
while IFS=$'\t' read -r name entry ghc_ok note; do
  [ -n "$name" ] || continue
  if [ "$ghc_ok" != "yes" ]; then
    echo "SKIP  $name — differs from GHC's preprocessor by design ($note)"
    continue
  fi
  "$driver" preprocess "$corpus/$entry" | "$driver" normalise >"$workdir/ours"
  ghc_cpp "$corpus/$entry" 2>/dev/null | "$driver" normalise >"$workdir/theirs"
  if diff -q "$workdir/ours" "$workdir/theirs" >/dev/null; then
    echo "OK    $name"
    comparable+=("$name:$entry")
  else
    echo "FAIL  $name — output differs from GHC's preprocessor; not timed"
    diff "$workdir/ours" "$workdir/theirs" | head -10
    status=1
  fi
done < <("$driver" cases)

echo
echo "== timing =="

time_pair() {
  # $1 label, $2 json path, $3 our command, $4 their command
  hyperfine --warmup 3 --runs "$runs" --style none --export-json "$2" \
    --command-name 'aihc-cpp' "$3" \
    --command-name 'ghc-cpp' "$4" >/dev/null
}

time_pair startup "$workdir/startup.json" \
  "$driver baseline $empty" \
  "$cpp_command $cpp_flags -x c $empty"

json_files=("$workdir/startup.json")
labels=("startup")
sizes=("0")

for pair in ${comparable[@]+"${comparable[@]}"}; do
  name="${pair%%:*}"
  entry="${pair#*:}"
  time_pair "$name" "$workdir/$name.json" \
    "$driver preprocess $corpus/$entry" \
    "$cpp_command $cpp_flags -I $corpus -x c $corpus/$entry"
  json_files+=("$workdir/$name.json")
  labels+=("$name")
  sizes+=("$("$driver" bytes "$corpus/$entry")")
  echo "  timed $name"
done

echo
python3 bench/report.py "${labels[@]}" -- "${sizes[@]}" -- "${json_files[@]}"

exit "$status"
