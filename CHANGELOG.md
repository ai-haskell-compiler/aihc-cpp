# Changelog

All notable changes to `aihc-cpp` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Breaking:** the preprocessor is now agnostic to the source encoding.
  `resultOutput` is a `ByteString` rather than `Text`, and `configMacros`
  is keyed by `ByteString`. Bytes the preprocessor did not generate itself
  are copied from input to output verbatim, so a module in any encoding —
  or in no consistent encoding — passes through unchanged. Nothing but
  `Diagnostic` message text is ever decoded.

  To migrate, decode at the boundary if you want `Text`:
  `Data.Text.Encoding.decodeUtf8With Data.Text.Encoding.Error.lenientDecode (resultOutput r)`.

### Fixed

- `preprocess` no longer throws an impure exception on source that is not
  valid UTF-8 (for example a Latin-1 encoded module containing byte `0xa9`,
  as shipped in Ebnf2ps). Previously `Data.Text.Encoding.decodeUtf8` raised
  from inside a pure function, escaping the `Diagnostic` mechanism the API
  otherwise uses; such bytes now simply pass through. GHC accepts an
  undecodable byte in a comment and rejects one where a token must be
  lexed, so this leaves the encoding decision to the compiler front-end
  instead of failing modules that genuinely compile.
- Whitespace and identifier classification is now ASCII-only. Using
  `Data.Char.isSpace` on a byte treated `0xA0` — an ordinary UTF-8
  continuation byte — as whitespace, which could split a multi-byte
  character in half.

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
