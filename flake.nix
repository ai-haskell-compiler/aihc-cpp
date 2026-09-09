{
  description = "aihc-cpp development flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {nixpkgs, ...}: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    packages = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      package = pkgs.haskell.packages.ghc9124.callCabal2nix "aihc-cpp" ./. {};
    in {
      default = package;
      aihc-cpp = package;
    });

    checks = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      hsPkgs = pkgs.haskell.packages.ghc9124;
      src = pkgs.lib.cleanSource ./.;
      package = hsPkgs.callCabal2nix "aihc-cpp" src {};
      checked = pkgs.haskell.lib.overrideCabal package (old: {
        doCheck = true;
        configureFlags = (old.configureFlags or []) ++ ["--ghc-options=-Werror"];
        testFlags = ["--hide-successes" "--quickcheck-tests" "1000"];
      });
      ghcEnv = hsPkgs.ghcWithPackages (p: [package p.cpphs]);
      sourceCheck = name: inputs: command:
        pkgs.runCommand name {
          nativeBuildInputs = inputs;
          inherit src;
        } ''
          cp -r "$src" source
          chmod -R u+w source
          cd source
          ${command}
          touch "$out"
        '';
    in {
      package-tests = checked;
      doctest = sourceCheck "aihc-cpp-doctest" [hsPkgs.doctest hsPkgs.ghc] ''
        doctest -XGHC2021 -isrc src/Aihc/Cpp.hs
      '';
      progress-strict = sourceCheck "aihc-cpp-progress-strict" [ghcEnv] ''
        runghc -package-env - -package=aihc-cpp -itest app/cpp-progress/Main.hs --strict
      '';
      haskell-format = sourceCheck "aihc-cpp-haskell-format" [pkgs.ormolu pkgs.findutils] ''
        find src test app bench -name '*.hs' -not -path '*/Test/Fixtures/*' -not -path '*/.*' -print0 | xargs -0 -r ormolu --mode check
      '';
      haskell-lint = sourceCheck "aihc-cpp-haskell-lint" [pkgs.hlint pkgs.findutils] ''
        find src test app bench -name '*.hs' -not -path '*/Test/Fixtures/*' -not -path '*/.*' -print0 | xargs -0 -r hlint -j4
      '';
      cabal-format = sourceCheck "aihc-cpp-cabal-format" [pkgs.haskellPackages.cabal-gild] ''
        cabal-gild --mode check --input aihc-cpp.cabal
      '';
    });

    devShells = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      hsPkgs = pkgs.haskell.packages.ghc9124;
    in {
      default = pkgs.mkShell {
        packages = [
          hsPkgs.ghc
          pkgs.cabal-install
          pkgs.just
          pkgs.ormolu
          pkgs.hlint
          pkgs.haskellPackages.cabal-gild
        ];
      };
    });

    formatter = forAllSystems (system: (import nixpkgs {inherit system;}).alejandra);
  };
}
