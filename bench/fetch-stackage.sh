#!/usr/bin/env bash
#
# Fetch Haskell source from a Stackage snapshot, for use as a benchmark corpus.
#
#   ./bench/fetch-stackage.sh
#   AIHC_CPP_BENCH_CORPUS=dist-newstyle/stackage/lts-24.58/src just bench
#
# The snapshot is pinned below rather than tracking "latest", so that a number
# measured today can be compared against one measured in six months. Bump it
# deliberately, and say so when reporting a change in the results.
#
# Downloads are cached and skipped if already present, so re-running is cheap
# and an interrupted fetch can simply be repeated.
#
set -euo pipefail

snapshot="${AIHC_CPP_STACKAGE_SNAPSHOT:-lts-24.58}"
cache="${AIHC_CPP_STACKAGE_CACHE:-dist-newstyle/stackage/$snapshot}"
# 0 means the whole snapshot (3441 packages for lts-24.58, several GB). The
# default is a stride through the package list, which spans the snapshot
# alphabetically while keeping the download to a few hundred megabytes.
limit="${AIHC_CPP_STACKAGE_PACKAGES:-400}"
jobs="${AIHC_CPP_STACKAGE_JOBS:-8}"

tarballs="$cache/tarballs"
src="$cache/src"
mkdir -p "$tarballs" "$src"

manifest="$cache/packages.txt"
if [ ! -s "$manifest" ]; then
  echo "fetching package list for $snapshot"
  curl -sSf --max-time 120 "https://www.stackage.org/$snapshot/cabal.config" |
    sed -n 's/^[[:space:]]*\([A-Za-z0-9][A-Za-z0-9-]*\)[[:space:]]*==[[:space:]]*\([0-9][0-9.]*\).*/\1-\2/p' |
    sort -u >"$manifest.all"
  total="$(wc -l <"$manifest.all" | tr -d ' ')"
  if [ "$limit" -gt 0 ] && [ "$total" -gt "$limit" ]; then
    # Take every Nth package so the sample spans the whole list rather than
    # stopping in the a's.
    stride=$((total / limit))
    awk -v n="$stride" 'NR % n == 1' "$manifest.all" >"$manifest"
  else
    cp "$manifest.all" "$manifest"
  fi
  echo "selected $(wc -l <"$manifest" | tr -d ' ') of $total packages"
fi

fetch_one() {
  pkg="$1"
  out="$2/$pkg.tar.gz"
  [ -s "$out" ] && return 0
  url="https://hackage.haskell.org/package/$pkg/$pkg.tar.gz"
  # A package present in the snapshot can still be absent from Hackage (it may
  # have been revised or deprecated). Missing ones are skipped, not fatal.
  if curl -sSf --max-time 120 -o "$out.part" "$url" 2>/dev/null; then
    mv "$out.part" "$out"
  else
    rm -f "$out.part"
  fi
}
export -f fetch_one

echo "downloading into $tarballs (jobs: $jobs)"
xargs -P "$jobs" -I{} bash -c 'fetch_one "$@"' _ {} "$tarballs" <"$manifest"

echo "extracting into $src"
extracted=0
for archive in "$tarballs"/*.tar.gz; do
  [ -e "$archive" ] || continue
  name="$(basename "$archive" .tar.gz)"
  [ -d "$src/$name" ] && continue
  tar xzf "$archive" -C "$src" 2>/dev/null || true
  extracted=$((extracted + 1))
done

modules="$(find "$src" -name '*.hs' | wc -l | tr -d ' ')"
cat <<EOF

snapshot:  $snapshot
packages:  $(find "$src" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') extracted ($extracted new)
modules:   $modules .hs files
size:      $(du -sh "$src" | cut -f1)

Run the benchmark against it with:

  AIHC_CPP_BENCH_CORPUS=$src just bench
EOF
