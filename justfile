# Test runner for aihc-cpp

test:
  cabal test -v0 all --test-options='--hide-successes --quickcheck-tests 1000'

progress:
  cabal exec -- runghc -package=aihc-cpp -itest app/cpp-progress/Main.hs

progress-strict:
  cabal exec -- runghc -package=aihc-cpp -itest app/cpp-progress/Main.hs --strict

# In-process benchmark: aihc-cpp vs cpphs, no process overhead in the numbers.
bench:
  cabal bench micro

# Process-level benchmark against the C preprocessor this GHC actually invokes.
bench-ghc:
  ./bench/compare-ghc.sh

fmt:
  nix develop --quiet --command bash -c 'cabal-gild --mode format --io aihc-cpp.cabal; ormolu --mode inplace $(find src test app bench -name "*.hs" -not -path "*/Test/Fixtures/*" -not -path "*/.*")'

check:
  nix develop --quiet --command cabal-gild --mode check --input aihc-cpp.cabal
  nix develop --quiet --command bash -c 'ormolu --mode check $(find src test app bench -name "*.hs" -not -path "*/Test/Fixtures/*" -not -path "*/.*")'
  nix develop --quiet --command bash -c 'hlint -j4 $(find src test app bench -name "*.hs" -not -path "*/Test/Fixtures/*" -not -path "*/.*")'
  cabal test -v0 all --ghc-options=-Werror --test-options='--hide-successes --quickcheck-tests 1000'
  nix develop --quiet --command bash -c 'shellcheck bench/*.sh'
  nix develop --quiet --command bash -c 'shfmt --diff --indent 2 --case-indent bench/*.sh'
  just progress-strict
