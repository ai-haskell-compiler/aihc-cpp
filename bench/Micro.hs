{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Raw throughput of aihc-cpp against the other two pure-Haskell C
-- preprocessors on Hackage, hpp and cpphs.
--
-- All three run in-process as libraries, on the same preloaded bytes, with
-- their output forced. Nothing but preprocessing is timed: no process startup,
-- no reading the entry file, no lazy IO left unevaluated.
--
-- This deliberately does not check that the three agree. Preprocessing Haskell
-- is under-specified — the tools differ on comment handling, on rescanning, on
-- what survives inside a literal — and demanding equivalence would mean either
-- excluding the interesting inputs or holding aihc-cpp to another
-- implementation's accidents. The test suite is where behaviour is pinned down;
-- this is where speed is.
--
-- Two corpora are available:
--
-- * The default is generated (see "Bench.Corpus"): deterministic and cheap,
--   good for spotting regressions, but artificial. Its shape is a guess at what
--   real code looks like, and a guess written by the same people who wrote the
--   preprocessor being measured.
-- * Setting @AIHC_CPP_BENCH_CORPUS@ to a directory of Haskell source
--   benchmarks every CPP-using module found under it. That is the number to
--   trust when the question is throughput on real work.
module Main (main) where

import Aihc.Cpp
  ( Config (..),
    IncludeRequest (..),
    Result (..),
    Step (..),
    defaultConfig,
    preprocess,
  )
import Bench.Corpus (CorpusCase (..), corpusCases, defaultCorpusRoot, generateCorpus)
import Control.DeepSeq (force)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (foldM)
import Control.Monad.Trans.Except (runExceptT)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Either (fromRight, rights)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Hpp
import qualified Hpp.Config as HppConfig
import Language.Preprocessor.Cpphs
  ( BoolOptions (..),
    CpphsOptions (..),
    defaultCpphsOptions,
    runCpphs,
  )
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import Test.Tasty.Bench (Benchmark, bench, bgroup, defaultMain, nfIO)

-- | Which corpus to benchmark.
data Corpus
  = -- | The generated corpus, in a directory this program owns.
    Generated FilePath
  | -- | Real modules discovered under a directory the user supplied.
    RealWorld FilePath

-- | Read the corpus choice from the environment.
--
-- A user-supplied directory is only ever read from. An earlier version called
-- 'generateCorpus' on whatever path this variable named, which overwrote files
-- in that directory and then benchmarked the generated corpus while appearing
-- to honour the setting.
selectCorpus :: IO Corpus
selectCorpus = maybe (Generated defaultCorpusRoot) RealWorld <$> lookupEnv "AIHC_CPP_BENCH_CORPUS"

-- | How many bytes of source to preload, in total.
--
-- The corpus is held in memory three times over, once in each preprocessor's
-- input type, and a Haskell 'String' costs upwards of sixteen bytes per
-- character — so a few megabytes of source becomes a few hundred megabytes of
-- residency. Only the bytes are held now (see 'tools'), so the budget buys
-- much more coverage than it used to, but outputs and collector headroom still
-- scale with it: 8MB samples several hundred modules, 16MB samples about
-- eleven hundred and peaks near 590MB against the 512MB heap cap this binary
-- carries. Raise it for wider coverage and lower it if the cap is ever hit.
byteBudget :: IO Int
byteBudget = maybe defaultBudget read <$> lookupEnv "AIHC_CPP_BENCH_MAX_BYTES"
  where
    defaultBudget = 8 * 1024 * 1024

-- | Every @.hs@ file under a directory.
--
-- Iterative rather than recursive, with the accumulator forced as it goes: a
-- monorepo can hold hundreds of thousands of entries, and building that tree
-- with @mapM@ and @concat@ retains every intermediate listing at once.
listHsFiles :: FilePath -> IO [FilePath]
listHsFiles root = sort <$> go [root] []
  where
    go [] acc = pure acc
    go (dir : queue) acc = do
      entries <- fromRight [] <$> tryIO (listDirectory dir)
      (dirs, files) <- foldM (classify dir) ([], []) entries
      go (dirs <> queue) $! foldl' (flip (:)) acc files
    classify dir (dirs, files) entry
      | "." `isPrefixOf` entry = pure (dirs, files)
      | otherwise = do
          let path = dir </> entry
          isDir <- doesDirectoryExist path
          pure $
            if isDir
              then (path : dirs, files)
              else (dirs, if ".hs" `isSuffixOf` entry then path : files else files)
    tryIO :: IO a -> IO (Either SomeException a)
    tryIO = try

-- | Choose the modules to benchmark: CPP-using, within the byte budget.
--
-- Candidates are examined at an even stride through the sorted file list rather
-- than from the front, so the sample spans the whole tree instead of stopping
-- inside whichever package sorts first, and only the candidates are read.
-- Deterministic, so two runs measure the same modules.
selectModules :: Int -> [FilePath] -> IO [FilePath]
selectModules budget paths = take' budget (every stride paths)
  where
    -- Bound how many files are opened just to find out whether they use CPP,
    -- while still examining enough of them to fill the budget: roughly one
    -- module in ten uses CPP, and the median one is a few kilobytes.
    candidates = max 4000 (budget `div` 256)
    stride = max 1 (length paths `div` candidates)
    every n xs = case xs of
      [] -> []
      (x : rest) -> x : every n (drop (n - 1) rest)
    take' _ [] = pure []
    take' remaining (path : rest)
      | remaining <= 0 = pure []
      | otherwise = do
          bytes <- fromRight BS.empty <$> (try (BS.readFile path) :: IO (Either SomeException BS.ByteString))
          if usesCpp bytes
            then (path :) <$> take' (remaining - BS.length bytes) rest
            else take' remaining rest

-- | Does this source actually contain preprocessor directives?
--
-- Modules without them would measure nothing but the cost of copying bytes,
-- which all three tools do at much the same speed and which no one is trying to
-- optimise.
usesCpp :: BS.ByteString -> Bool
usesCpp = any isDirective . BS8.lines
  where
    isDirective line = case BS8.uncons (dropBlanks line) of
      Just ('#', rest) -> any (`BS.isPrefixOf` dropBlanks rest) directives
      _ -> False
    dropBlanks = BS8.dropWhile (`elem` (" \t" :: String))
    directives =
      ["if", "ifdef", "ifndef", "elif", "else", "endif", "define", "undef", "include"]

-- | An input, read from disk once.
--
-- Only the bytes are held. The two other input shapes the tools want are built
-- inside the timed region, per iteration, and discarded — see 'tools'.
data Prepared = Prepared
  { prepPath :: !FilePath,
    prepBytes :: !BS.ByteString
  }

-- | The three preprocessors behind one interface, plus the cost of feeding one.
--
-- Each forces its output completely and returns the length, so that no tool
-- benefits from leaving a lazy structure unevaluated and all three are charged
-- for producing the whole result.
--
-- Each also converts the input into the shape its own API demands, inside the
-- timed region. cpphs takes a 'String', and holding the whole corpus as one
-- costs about seventy bytes per source character once the collector\'s copying
-- space is counted — on a 4MB corpus that was 290MB of the 417MB peak, and it
-- was the reason the corpus had to stay small. Doing it per iteration instead
-- keeps one module\'s worth live rather than the whole corpus.
--
-- That does charge cpphs for marshalling that is not preprocessing, so the cost
-- is measured too: the @(input marshalling)@ entry does the 'String' conversion
-- and nothing else. Subtract it from cpphs to recover a like-for-like number.
tools :: [(String, FilePath -> Prepared -> IO Int)]
tools =
  [ ( "aihc-cpp",
      \_ p -> do
        out <- resultOutput <$> runAihc (prepPath p) (prepBytes p)
        T.length <$> evaluate (force out)
    ),
    ( "hpp",
      \root p -> do
        out <- hpp root p (BS8.lines (prepBytes p))
        sum . map BS.length <$> evaluate (force out)
    ),
    ( "cpphs",
      \root p -> do
        out <- runCpphs (cpphsOptions root) (prepPath p) (BS8.unpack (prepBytes p))
        length <$> evaluate (force out)
    ),
    ( "(input marshalling)",
      \_ p -> length <$> evaluate (force (BS8.unpack (prepBytes p)))
    )
  ]

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  corpus <- selectCorpus
  case corpus of
    Generated root -> do
      generateCorpus root
      prepared <- mapM (prepare . (root </>) . caseEntry) corpusCases
      mapM_ (reportOne root) (zip corpusCases prepared)
      defaultMain
        [ bgroup (caseName c) [bench name (nfIO (run root p)) | (name, run) <- tools]
        | (c, p) <- zip corpusCases prepared
        ]
    RealWorld root -> do
      found <- listHsFiles root
      budget <- byteBudget
      prepared <- mapM prepare =<< selectModules budget found
      reportCorpus root (length found) prepared
      defaultMain [bgroup "real-world" (map (sweep root prepared) tools)]

-- | Preprocess every module in the corpus, as one benchmark.
--
-- Real modules have a median size of a few kilobytes: too small to time
-- individually, and there are far too many to list separately. Timing the whole
-- set at once is also the workload that matters — what a build pays across a
-- project, not what one module costs.
sweep :: FilePath -> [Prepared] -> (String, FilePath -> Prepared -> IO Int) -> Benchmark
sweep root prepared (name, run) =
  bench name (nfIO (foldM step 0 prepared))
  where
    step !acc p = (acc +) <$> safely (run root p)

-- | Run a preprocessor, treating failure as zero output.
--
-- Real modules routinely reference headers that are not present and macros that
-- are never defined, and the three tools disagree about which of those is
-- fatal. A crash must not abort the sweep, but it does mean less work was done,
-- which is why 'reportCorpus' prints the failure counts alongside the timings.
safely :: IO Int -> IO Int
safely act = fromRight 0 <$> (try act :: IO (Either SomeException Int))

prepare :: FilePath -> IO Prepared
prepare path = Prepared path <$> BS.readFile path

-- | Describe the discovered corpus, and how much of it each tool can handle.
reportCorpus :: FilePath -> Int -> [Prepared] -> IO ()
reportCorpus root found prepared = do
  putStrLn
    ( "real-world corpus: "
        <> show (length prepared)
        <> " of "
        <> show found
        <> " sampled CPP-using modules from "
        <> root
        <> ", "
        <> show (sum (map (BS.length . prepBytes) prepared) `div` 1024)
        <> " KiB (raise AIHC_CPP_BENCH_MAX_BYTES to widen)"
    )
  mapM_ report tools
  where
    report (name, run) = do
      outcomes <- mapM (\p -> (,) (prepPath p) <$> (try (run root p) :: IO (Either SomeException Int))) prepared
      let failed = [(path, show err) | (path, Left err) <- outcomes]
          produced = sum (rights (map snd outcomes))
      putStrLn
        ( "  "
            <> name
            <> ": "
            <> show (length prepared - length failed)
            <> " ok, "
            <> show (length failed)
            <> " failed, "
            <> show (produced `div` 1024)
            <> " KiB out"
        )
      -- Name the first few failures. A tool that crashes on real input is
      -- doing less work than the others, and if it is aihc-cpp it is a bug
      -- report rather than a benchmark result.
      mapM_ (\(path, err) -> putStrLn ("      failed: " <> path <> ": " <> err)) (take 3 failed)

-- | Print how much output each tool produces on a generated case.
--
-- Not a correctness check. It is here so a wildly faster result is not mistaken
-- for a win when it is really a tool that gave up early or emitted far less.
reportOne :: FilePath -> (CorpusCase, Prepared) -> IO ()
reportOne root (c, p) = do
  sizes <- mapM (\(name, run) -> (,) name <$> safely (run root p)) tools
  putStrLn
    ( caseName c
        <> ": in "
        <> show (BS.length (prepBytes p))
        <> "B, out"
        <> concat [" " <> name <> " " <> show n | (name, n) <- sizes]
    )

-- | Run hpp over the preloaded lines, returning its output chunks.
hpp :: FilePath -> Prepared -> [BS.ByteString] -> IO [BS.ByteString]
hpp root p inputLines = do
  result <-
    runExceptT
      ( Hpp.runHpp
          (Hpp.initHppState (hppConfig root (prepPath p)) mempty)
          (Hpp.preprocess inputLines)
      )
  case result of
    Left err -> error ("hpp failed on " <> prepPath p <> ": " <> show err)
    Right (out, _) -> pure (Hpp.hppOutput out)

hppConfig :: FilePath -> FilePath -> HppConfig.Config
hppConfig root path =
  fromMaybe
    (error "hpp configuration incomplete")
    ( HppConfig.realizeConfig
        HppConfig.defaultConfigF
          { HppConfig.curFileNameF = Just path,
            HppConfig.includePathsF = Just [root, takeDirectory path]
          }
    )

-- | The same cpphs configuration the correctness oracle in @test/@ uses, so the
-- implementation being timed is the one already being compared against.
cpphsOptions :: FilePath -> CpphsOptions
cpphsOptions root =
  defaultCpphsOptions
    { boolopts = (boolopts defaultCpphsOptions) {stripC89 = True, warnings = False},
      includes = [root]
    }

-- | Preprocess a file whose contents are already in memory, resolving
-- @#include@ directives from disk as they are requested.
--
-- Includes are read from disk rather than preloaded because that is what cpphs
-- and hpp do: they take the entry file's contents and go to the file system for
-- the rest. Preloading them for aihc-cpp alone would hand it an advantage the
-- other two cannot have.
runAihc :: FilePath -> BS.ByteString -> IO Result
runAihc path source = go (preprocess (defaultConfig {configInputFile = path}) source)
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
