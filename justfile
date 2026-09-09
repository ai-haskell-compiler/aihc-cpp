# Test runner for aihc-cpp

test:
  cabal test -v0 all --test-options='--hide-successes --quickcheck-tests 1000'

progress:
  cabal exec -- runghc -package=aihc-cpp -itest app/cpp-progress/Main.hs

progress-strict:
  cabal exec -- runghc -package=aihc-cpp -itest app/cpp-progress/Main.hs --strict

# Raw throughput against the other pure-Haskell preprocessors, hpp and cpphs,
# on a generated corpus.
bench:
  cabal bench micro

# The same, against real modules from a pinned Stackage snapshot. The first run
# downloads and extracts package sources into dist-newstyle; later runs reuse
# them.
bench-stackage:
  ./bench/fetch-stackage.sh
  AIHC_CPP_BENCH_CORPUS=dist-newstyle/stackage/lts-24.58/src AIHC_CPP_BENCH_INCLUDE=bench/include:dist-newstyle/stackage/lts-24.58/include cabal bench micro

# One pass over every CPP-using module in the whole snapshot, reporting
# throughput and what each tool could not handle. Fetches all 3441 packages.
bench-stackage-sweep:
  AIHC_CPP_STACKAGE_PACKAGES=0 ./bench/fetch-stackage.sh
  AIHC_CPP_BENCH_CORPUS=dist-newstyle/stackage/lts-24.58/src AIHC_CPP_BENCH_INCLUDE=bench/include:dist-newstyle/stackage/lts-24.58/include AIHC_CPP_BENCH_SWEEP=1 cabal bench micro

fmt:
  nix develop --quiet --command bash -c 'cabal-gild --mode format --io aihc-cpp.cabal; ormolu --mode inplace $(find src test app bench -name "*.hs" -not -path "*/Test/Fixtures/*" -not -path "*/.*")'

check:
  nix develop --quiet --command cabal-gild --mode check --input aihc-cpp.cabal
  nix develop --quiet --command bash -c 'ormolu --mode check $(find src test app bench -name "*.hs" -not -path "*/Test/Fixtures/*" -not -path "*/.*")'
  nix develop --quiet --command bash -c 'hlint -j4 $(find src test app bench -name "*.hs" -not -path "*/Test/Fixtures/*" -not -path "*/.*")'
  nix develop --quiet --command bash -c 'shellcheck bench/*.sh'
  nix develop --quiet --command bash -c 'shfmt --diff --indent 2 --case-indent bench/*.sh'
  cabal test -v0 all --ghc-options=-Werror --test-options='--hide-successes --quickcheck-tests 1000'
  just progress-strict
