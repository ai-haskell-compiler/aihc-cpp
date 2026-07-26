# Test runner for aihc-cpp

test:
  cabal test -v0 all --test-options='--hide-successes --quickcheck-tests 1000'

progress:
  cabal exec -- runghc -package=aihc-cpp -itest app/cpp-progress/Main.hs

progress-strict:
  cabal exec -- runghc -package=aihc-cpp -itest app/cpp-progress/Main.hs --strict

fmt:
  nix develop --quiet --command bash -c 'cabal-gild --mode format --io aihc-cpp.cabal; ormolu --mode inplace $(find src test app -name "*.hs" -not -path "*/Test/Fixtures/*")'

check:
  nix develop --quiet --command cabal-gild --mode check --input aihc-cpp.cabal
  nix develop --quiet --command bash -c 'ormolu --mode check $(find src test app -name "*.hs" -not -path "*/Test/Fixtures/*")'
  nix develop --quiet --command bash -c 'hlint -j $(find src test app -name "*.hs" -not -path "*/Test/Fixtures/*")'
  cabal test -v0 all --ghc-options=-Werror --test-options='--hide-successes --quickcheck-tests 1000'
  just progress-strict
