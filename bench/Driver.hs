{-# LANGUAGE OverloadedStrings #-}

-- | Command-line driver used by @bench/compare-ghc.sh@.
--
-- GHC's C preprocessor is a separate binary, so the only way to time aihc-cpp
-- against it is process against process. That comparison is only honest if the
-- two processes are doing the same job and if fixed per-process overhead is
-- accounted for, which is what the subcommands here are for.
module Main (main) where

import Aihc.Cpp (Diagnostic (..), Result (..), Severity (..))
import Bench.Corpus (CorpusCase (..), corpusCases, generateCorpus, maxScale)
import Bench.Run (LoadedCase (..), loadCase, normalise, renderNormalised, runAihc)
import qualified Data.ByteString as BS
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["gen", root] -> generateCorpus 1 root
    ["gen", root, scale] -> case readMaybe scale of
      Just n | n >= 1 && n <= maxScale -> generateCorpus n root
      _ -> do
        hPutStrLn stderr ("error: SCALE must be between 1 and " <> show maxScale)
        usage
    -- Emits the corpus manifest as TSV so the shell harness does not have to
    -- keep its own copy of the case list, including which cases it is fair to
    -- compare against GHC's preprocessor.
    ["cases"] -> mapM_ (putStrLn . describeCase) (corpusCases 1)
    ["preprocess", path] -> preprocessFile path
    -- Reads the input and writes it back out untouched. Running this on the
    -- same file measures everything that is not preprocessing: process spawn,
    -- RTS startup, reading the input, writing the output. Subtracting it from
    -- the 'preprocess' time is what makes the process-level comparison against
    -- GHC's preprocessor meaningful.
    ["baseline", path] -> BS.readFile path >>= BS.putStr
    -- Reads preprocessor output on stdin and prints it in normalised form, so
    -- aihc-cpp and GHC's preprocessor can be diffed for agreement despite
    -- emitting different line-marker syntax.
    -- Total input size, counting included files. The entry file of an
    -- include-heavy case is a few hundred bytes while the work is megabytes,
    -- so using the entry file's size would report nonsense throughput.
    ["bytes", path] -> loadCase path >>= print . totalBytes
    ["normalise"] -> TIO.getContents >>= TIO.putStr . renderNormalised . normalise
    _ -> usage

usage :: IO ()
usage = do
  self <- getProgName
  mapM_
    (hPutStrLn stderr)
    [ "usage: " <> self <> " <command>",
      "",
      "  gen DIR [SCALE]    write the benchmark corpus under DIR, SCALE times larger",
      "  cases              list corpus cases as TSV: name, entry, ghc-comparable, note",
      "  preprocess FILE    preprocess FILE with aihc-cpp, output on stdout",
      "  baseline FILE      copy FILE to stdout (process-overhead baseline)",
      "  bytes FILE         total input size of FILE and everything it includes",
      "  normalise          normalise preprocessor output read from stdin"
    ]
  exitFailure

totalBytes :: LoadedCase -> Int
totalBytes lc = BS.length (loadedSource lc) + sum (map BS.length (M.elems (loadedIncludes lc)))

describeCase :: CorpusCase -> String
describeCase c =
  intercalate
    "\t"
    [ caseName c,
      caseEntry c,
      if caseComparableWithGhc c then "yes" else "no",
      caseDescription c
    ]

preprocessFile :: FilePath -> IO ()
preprocessFile path = do
  source <- BS.readFile path
  result <- runAihc path source
  mapM_ report (resultDiagnostics result)
  TIO.putStr (resultOutput result)
  case [d | d <- resultDiagnostics result, diagSeverity d == Error] of
    [] -> pure ()
    _ -> exitFailure
  where
    report d =
      hPutStrLn
        stderr
        ( diagFile d
            <> ":"
            <> show (diagLine d)
            <> ": "
            <> show (diagSeverity d)
            <> ": "
            <> T.unpack (diagMessage d)
        )
