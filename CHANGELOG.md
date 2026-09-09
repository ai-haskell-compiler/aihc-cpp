# Changelog

All notable changes to `aihc-cpp` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- Macro arguments are now expanded before substitution, so a function-like
  macro invocation produced by an expansion is rescanned and expanded, matching
  GHC's C preprocessor and `cpphs`. The C standard's non-recursive-expansion
  rule is honoured, so a macro is never expanded inside its own expansion.

## [1.0.0.3] - 2026-07-26

### Changed

- Moved development to the standalone
  [`ai-haskell-compiler/aihc-cpp`](https://github.com/ai-haskell-compiler/aihc-cpp)
  repository, including the full test and compatibility CI configuration.

## [1.0.0.2] - 2026-05-27

### Fixed

- Removed the internal `cpp-progress` executable from the published Cabal
  package so Hackage lists `aihc-cpp` as library-only.
- Included the CPP progress fixtures in the source distribution so Hackage can
  run the package test suite and report coverage.

## [1.0.0.1] - 2026-05-27

### Fixed

- Marked the internal `cpp-progress` executable as private so Hackage lists
  `aihc-cpp` as a library-only package.

## [1.0.0.0] - 2026-05-27

### Added

- Initial stable release of the pure Haskell CPP package.
- Public preprocessing API with deterministic configuration, diagnostics,
  include continuations, and preprocessing results.
- Support for object-like and function-like macros, includes, conditionals,
  diagnostics, line directives, token pasting, stringification, predefined
  macro handling, and comment-aware scanning.
- Oracle-backed progress suite against cpphs with the current `46/46`
  implemented baseline.
