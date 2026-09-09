{-# LANGUAGE OverloadedStrings #-}

-- | Shared plumbing for the aihc-cpp benchmarks: driving the include
-- continuation, and normalising preprocessor output so that aihc-cpp, cpphs and
-- GHC's C preprocessor can be checked for agreement before they are timed.
module Bench.Run
  ( -- * Running aihc-cpp
    LoadedCase (..),
    loadCase,
    runAihc,
    runAihcPure,

    -- * Output normalisation
    LocatedLine (..),
    normalise,
    renderNormalised,
  )
where

import Aihc.Cpp
  ( Config (..),
    IncludeRequest (..),
    Result (..),
    Step (..),
    defaultConfig,
    preprocess,
  )
import qualified Data.ByteString as BS
import Data.Char (isDigit, isSpace)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

-- | A benchmark input with every file it needs already read into memory.
--
-- Reading up front matters for fairness: the in-process benchmark must not
-- time the file system, and an include-heavy case would otherwise spend most of
-- its time in @readFile@ rather than in the preprocessor.
data LoadedCase = LoadedCase
  { loadedPath :: !FilePath,
    loadedSource :: !BS.ByteString,
    -- | Every file reachable by @#include@, keyed by resolved path.
    loadedIncludes :: !(Map FilePath BS.ByteString)
  }

-- | Read an entry file and, transitively, everything it includes.
loadCase :: FilePath -> IO LoadedCase
loadCase path = do
  source <- BS.readFile path
  includes <- go (preprocess (config path) source) M.empty
  pure (LoadedCase path source includes)
  where
    go (Done _) acc = pure acc
    go (NeedInclude req k) acc = do
      let target = resolveInclude path req
      exists <- doesFileExist target
      if exists
        then do
          contents <- BS.readFile target
          go (k (Just contents)) (M.insert target contents acc)
        else go (k Nothing) acc

config :: FilePath -> Config
config path = defaultConfig {configInputFile = path}

-- | Preprocess a preloaded case. Pure, so the benchmark times the preprocessor
-- and nothing else.
runAihcPure :: LoadedCase -> Result
runAihcPure lc = go (preprocess (config (loadedPath lc)) (loadedSource lc))
  where
    go (Done r) = r
    go (NeedInclude req k) =
      go (k (M.lookup (resolveInclude (loadedPath lc) req) (loadedIncludes lc)))

-- | Preprocess a file, resolving includes from disk as they are requested.
runAihc :: FilePath -> BS.ByteString -> IO Result
runAihc path source = go (preprocess (config path) source)
  where
    go (Done r) = pure r
    go (NeedInclude req k) = do
      let target = resolveInclude path req
      exists <- doesFileExist target
      contents <- if exists then Just <$> BS.readFile target else pure Nothing
      go (k contents)

-- | Resolve an include relative to the file that requested it, falling back to
-- the directory of the entry file.
resolveInclude :: FilePath -> IncludeRequest -> FilePath
resolveInclude rootPath req = baseDir </> includePath req
  where
    fromDir = takeDirectory (includeFrom req)
    baseDir = if null fromDir then takeDirectory rootPath else fromDir

-- ---------------------------------------------------------------------------
-- Normalisation
-- ---------------------------------------------------------------------------

-- | A single output line, tagged with the source position the preprocessor
-- claims it came from.
data LocatedLine = LocatedLine
  { locatedFile :: !FilePath,
    locatedLineNo :: !Int,
    locatedText :: !Text
  }
  deriving (Eq, Show)

-- | Reduce preprocessor output to a comparable form.
--
-- Three implementations of the same job disagree on presentation without
-- disagreeing on meaning: aihc-cpp emits @#line 5 \"F\"@, GHC's C preprocessor
-- emits @# 5 \"F\"@ plus flag digits, both use blank lines to keep line numbers
-- aligned, and they differ on whether the space after a comma survives into a
-- macro expansion. Normalising resolves every line marker into an explicit
-- (file, line) tag, drops blank lines, keeps leading indentation (Haskell\'s
-- layout rule makes it meaningful) and drops interior whitespace.
--
-- This is the parity gate for benchmarking, and it answers a narrower question
-- than the test suite does: are two tools doing the same work on this input, so
-- that timing them against each other means anything? It deliberately tolerates
-- presentation differences that the correctness oracle in @test/@ does not —
-- that comparison is exact, and it, not this, is the authority on whether the
-- output is right.
normalise :: Text -> [LocatedLine]
normalise = go 1 "<unknown>" . T.lines
  where
    go _ _ [] = []
    go lineNo filePath (line : rest) =
      case parseLineMarker line of
        Just (nextLineNo, mFile) ->
          go nextLineNo (fromMaybe filePath mFile) rest
        Nothing
          | T.null (T.strip line) -> go (lineNo + 1) filePath rest
          | otherwise ->
              LocatedLine filePath lineNo (collapseSpaces line)
                : go (lineNo + 1) filePath rest

-- | Drop interior whitespace, preserving leading indentation.
--
-- Indentation is kept because Haskell\'s layout rule makes it meaningful, and a
-- preprocessor that changed it would be changing the program. Whitespace within
-- the line is dropped because that is exactly where the tools differ without
-- disagreeing: @gcc -traditional@ keeps the space after a comma when it
-- substitutes a macro argument and aihc-cpp does not.
--
-- The cost of this is that the gate would not notice two tokens being glued
-- together where one tool emits @foo bar@ and another @foobar@. That is a real
-- correctness question, and it is the exact-comparison oracle in @test/@ that
-- answers it; the gate here only decides whether timing the two is meaningful.
collapseSpaces :: Text -> Text
collapseSpaces line = indent <> T.filter (not . isSpace) body
  where
    (indent, body) = T.span isSpace line

-- | Parse either @#line N \"file\"@ (aihc-cpp, cpphs) or @# N \"file\" flags@
-- (GHC's C preprocessor).
parseLineMarker :: Text -> Maybe (Int, Maybe FilePath)
parseLineMarker raw =
  case T.stripPrefix "#" (T.strip raw) of
    Nothing -> Nothing
    Just afterHash -> do
      let body = T.stripStart (fromMaybe afterHash (T.stripPrefix "line" (T.stripStart afterHash)))
          (digits, rest) = T.span isDigit body
      if T.null digits
        then Nothing
        else do
          lineNo <- readInt digits
          let rest' = T.stripStart rest
          case T.uncons rest' of
            Just ('"', quoted) ->
              let (filePath, suffix) = T.breakOn "\"" quoted
               in if T.null suffix then Nothing else Just (lineNo, Just (T.unpack filePath))
            _ -> Just (lineNo, Nothing)

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack t) of
  [(n, "")] -> Just n
  _ -> Nothing

-- | Render normalised output as one record per line, for @diff@.
renderNormalised :: [LocatedLine] -> Text
renderNormalised = T.unlines . map render
  where
    render (LocatedLine f n t) = T.pack (f <> ":" <> show n <> ": ") <> t
