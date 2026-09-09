# Changelog

All notable changes to `aihc-cpp` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- A pragma nested inside a Haskell block comment no longer terminates that
  comment. `{-#` is treated as a pragma delimiter only outside a comment;
  inside one it counts as an ordinary nested `{-`, balancing the `-}` of the
  closing `#-}`. Previously each such pragma decremented the comment depth,
  making CPP directives in the rest of the commented-out region live —
  producing spurious `unmatched #endif` warnings and, with a commented-out
  `#if 0`, silently dropping the comment's contents
  ([#1](https://github.com/ai-haskell-compiler/aihc-cpp/issues/1)).

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
