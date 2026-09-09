{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
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
    Diagnostic (..),
    IncludeRequest (..),
    Result (..),
    Severity (..),
    Step (..),
    defaultConfig,
    preprocess,
  )
import Bench.Corpus (CorpusCase (..), corpusCases, defaultCorpusRoot, generateCorpus)
import Control.DeepSeq (NFData, force)
import Control.Exception (AsyncException, SomeException, evaluate, fromException, throwIO, try)
import Control.Monad (foldM)
import Control.Monad.Trans.Except (runExceptT)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Either (fromRight, rights)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import GHC.Clock (getMonotonicTime)
import GHC.Generics (Generic)
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
import System.FilePath (splitDirectories, takeDirectory, (</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.IO.Unsafe (unsafePerformIO)
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

-- | Every @.hs@ file under a directory, as packed paths.
--
-- Iterative rather than recursive, with the accumulator forced as it goes, and
-- paths held as 'BS.ByteString' rather than 'FilePath'. Both matter at snapshot
-- scale: a full Stackage checkout is fifty thousand modules under a tree of
-- several hundred thousand entries, and a Haskell 'String' path costs around
-- two kilobytes, so keeping them unpacked exhausted the heap before the walk
-- finished.
listHsFiles :: FilePath -> IO [BS.ByteString]
listHsFiles root = sort <$> go [BS8.pack root] []
  where
    go [] acc = pure acc
    go (dir : queue) acc = do
      let dirPath = BS8.unpack dir
      entries <- fromRight [] <$> tryIO (listDirectory dirPath)
      (dirs, files) <- foldM (classify dirPath) ([], []) entries
      go (dirs <> queue) $! foldl (flip (:)) acc files
    classify dirPath (dirs, files) entry
      | "." `isPrefixOf` entry = pure (dirs, files)
      | otherwise = do
          let path = dirPath </> entry
          isDir <- doesDirectoryExist path
          pure $
            if isDir
              then (BS8.pack path : dirs, files)
              else (dirs, if ".hs" `isSuffixOf` entry then BS8.pack path : files else files)
    tryIO :: IO a -> IO (Either SomeException a)
    tryIO = try

-- | Choose the modules to benchmark: CPP-using, within the byte budget.
--
-- Candidates are examined at an even stride through the sorted file list rather
-- than from the front, so the sample spans the whole tree instead of stopping
-- inside whichever package sorts first, and only the candidates are read.
-- Deterministic, so two runs measure the same modules.
selectModules :: Int -> [BS.ByteString] -> IO [FilePath]
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
    take' remaining (packed : rest)
      | remaining <= 0 = pure []
      | otherwise = do
          let path = BS8.unpack packed
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

-- | An input, identified by path.
--
-- Nothing is preloaded. Each tool reads the file inside the timed region and
-- discards it, so peak memory is one module rather than the whole corpus and
-- there is no ceiling on how much of a snapshot can be measured. The read is
-- charged to every tool equally and quantified by the @(read only)@ row.
newtype Prepared = Prepared {prepPath :: FilePath}

-- | What one tool did with one module.
data Outcome = Outcome
  { -- | Bytes of output produced.
    outBytes :: !Int,
    -- | The tool produced output but reported an error in the source.
    outErrored :: !Bool
  }
  deriving (Generic, NFData)

-- | The three preprocessors behind one interface, plus the cost of feeding one.
--
-- The two parenthesised entries are not competitors. @(read only)@ is the file
-- read every tool pays for; @(read + String)@ adds the 'String' conversion that
-- cpphs's API demands. Subtract the matching baseline from a tool to compare
-- preprocessing rather than plumbing.
--
-- Each forces its output completely and returns the length, so that no tool
-- benefits from leaving a lazy structure unevaluated and all three are charged
-- for producing the whole result, and each converts the input into the shape
-- its own API demands inside the timed region.
tools :: [(String, FilePath -> Prepared -> IO Outcome)]
tools =
  [ ( "aihc-cpp",
      \root p -> do
        source <- BS.readFile (prepPath p)
        result <- runAihc (searchPath root p) (prepPath p) source
        -- aihc-cpp reports a bad directive or an unresolvable include as a
        -- diagnostic and still returns output; hpp and cpphs throw. Reporting
        -- these separately from crashes keeps that difference visible instead
        -- of turning it into a robustness claim in either direction.
        let errored = any ((== Error) . diagSeverity) (resultDiagnostics result)
        flip Outcome errored . BS.length <$> evaluate (force (resultOutput result))
    ),
    ( "hpp",
      \root p -> do
        source <- BS.readFile (prepPath p)
        out <- hpp (searchPath root p) p (BS8.lines source)
        flip Outcome False . sum . map BS.length <$> evaluate (force out)
    ),
    ( "cpphs",
      \root p -> do
        source <- BS.readFile (prepPath p)
        out <- runCpphs (cpphsOptions (searchPath root p)) (prepPath p) (BS8.unpack source)
        flip Outcome False . length <$> evaluate (force out)
    ),
    ( "(read only)",
      \_ p -> flip Outcome False . BS.length <$> BS.readFile (prepPath p)
    ),
    ( "(read + String)",
      \_ p -> do
        source <- BS.readFile (prepPath p)
        flip Outcome False . length <$> evaluate (force (BS8.unpack source))
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
      warnMissingStubs
      found <- listHsFiles root
      full <- lookupEnv "AIHC_CPP_BENCH_SWEEP"
      selected <- lookupEnv "AIHC_CPP_BENCH_TOOLS"
      let chosen = case selected of
            Nothing -> tools
            Just names -> [t | t@(name, _) <- tools, name `elem` splitOn ',' names]
      case full of
        Just _ -> fullSweep root chosen =<< mapM prepare =<< allCppModules found
        Nothing -> do
          budget <- byteBudget
          prepared <- mapM prepare =<< selectModules budget found
          reportCorpus root (length found) prepared
          defaultMain [bgroup "real-world" (map (sweep root prepared) chosen)]

splitOn :: Char -> String -> [String]
splitOn sep str = case break (== sep) str of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn sep rest

-- | Preprocess every CPP-using module in the corpus, once, per tool.
--
-- The sampled benchmark above exists to catch regressions and needs repeated
-- runs for its statistics, which puts a practical ceiling on corpus size. This
-- answers a different question — how does each tool fare across a whole
-- snapshot — and so takes one pass over everything and reports wall clock and
-- throughput rather than a distribution.
fullSweep :: FilePath -> [(String, FilePath -> Prepared -> IO Outcome)] -> [Prepared] -> IO ()
fullSweep root chosen prepared = do
  corpusBytes <- sum <$> mapM (fmap BS.length . BS.readFile . prepPath) prepared
  putStrLn
    ( "full sweep: "
        <> show (length prepared)
        <> " CPP-using modules, "
        <> show (corpusBytes `div` (1024 * 1024))
        <> " MiB"
    )
  putStrLn ""
  putStrLn
    ( pad 18 "tool"
        <> pad 9 "ok"
        <> pad 9 "errored"
        <> pad 9 "crashed"
        <> pad 11 "seconds"
        <> pad 11 "MiB out"
        <> "MiB/s"
    )
  putStrLn (replicate 74 '-')
  mapM_ (one corpusBytes) chosen
  where
    one corpusBytes (name, run) = do
      start <- getMonotonicTime
      -- Folded strictly, keeping only counters and the first few failures.
      -- Retaining every outcome kept each failure's exception alive, and with
      -- it whatever the exception's message had captured.
      tally <- foldM (step run) (Tally 0 0 0 0 []) prepared
      elapsed <- subtract start <$> getMonotonicTime
      let mib = fromIntegral corpusBytes / 1048576 :: Double
      putStrLn
        ( pad 18 name
            <> pad 9 (show (tallyOk tally))
            <> pad 9 (show (tallyErrored tally))
            <> pad 9 (show (tallyCrashed tally))
            <> pad 11 (showFixed 2 elapsed)
            <> pad 11 (showFixed 1 (fromIntegral (tallyBytes tally) / 1048576 :: Double))
            <> showFixed 1 (mib / elapsed)
        )
      mapM_ (\msg -> putStrLn ("    " <> msg)) (reverse (tallyFailures tally))
    step run tally p = do
      outcome <- tryTool (run root p)
      pure $! case outcome of
        Right o
          | outErrored o -> tally {tallyErrored = tallyErrored tally + 1, tallyBytes = tallyBytes tally + outBytes o}
          | otherwise -> tally {tallyOk = tallyOk tally + 1, tallyBytes = tallyBytes tally + outBytes o}
        Left err ->
          tally
            { tallyCrashed = tallyCrashed tally + 1,
              tallyFailures = keepFew (prepPath p <> ": " <> show err) (tallyFailures tally)
            }
    keepFew msg msgs
      | length msgs >= 3 = msgs
      | otherwise = length msg `seq` (msg : msgs)
    pad n str = str <> replicate (max 1 (n - length str)) ' '
    showFixed places x =
      let scaled = round (x * 10 ^ places) :: Integer
          (whole, frac) = scaled `divMod` (10 ^ places)
       in show whole <> "." <> pad0 places (show frac)
    pad0 n str = replicate (n - length str) '0' <> str

-- | Running counts for one tool's pass over the corpus.
data Tally = Tally
  { tallyOk :: !Int,
    tallyErrored :: !Int,
    tallyCrashed :: !Int,
    tallyBytes :: !Int,
    tallyFailures :: [String]
  }

-- | Every CPP-using module, with no sampling and no budget.
allCppModules :: [BS.ByteString] -> IO [FilePath]
allCppModules = fmap reverse . foldM check []
  where
    check acc packed = do
      let path = BS8.unpack packed
      bytes <- fromRight BS.empty <$> (try (BS.readFile path) :: IO (Either SomeException BS.ByteString))
      pure $! if usesCpp bytes then path : acc else acc

-- | Preprocess every module in the corpus, as one benchmark.
--
-- Real modules have a median size of a few kilobytes: too small to time
-- individually, and there are far too many to list separately. Timing the whole
-- set at once is also the workload that matters — what a build pays across a
-- project, not what one module costs.
sweep :: FilePath -> [Prepared] -> (String, FilePath -> Prepared -> IO Outcome) -> Benchmark
sweep root prepared (name, run) =
  bench name (nfIO (foldM step 0 prepared))
  where
    step !acc p = (acc +) <$> safely (run root p)

-- | Run a preprocessor, treating a failure of its own as zero output.
--
-- Real modules routinely reference headers that are not present and macros that
-- are never defined, and the three tools disagree about which of those is
-- fatal. A crash must not abort the sweep, but it does mean less work was done,
-- which is why the failure counts are reported alongside the timings.
safely :: IO Outcome -> IO Int
safely act = either (const 0) outBytes <$> tryTool act

-- | Catch what a preprocessor does wrong, not what the runtime does.
--
-- A plain @try \@SomeException@ also catches heap and stack overflow, which
-- turned a benchmark run that was simply given too little memory into a report
-- of hundreds of \"tool failures\" — and the tool that tripped the limit looked
-- slow rather than starved. Runtime exhaustion is a problem with how the
-- benchmark was run, so it is re-thrown and aborts the run loudly.
tryTool :: IO a -> IO (Either SomeException a)
tryTool act = do
  outcome <- try act
  case outcome of
    Left err | Just async <- fromException err -> throwIO (async :: AsyncException)
    _ -> pure outcome

prepare :: FilePath -> IO Prepared
prepare = pure . Prepared

-- | Describe the discovered corpus, and how much of it each tool can handle.
reportCorpus :: FilePath -> Int -> [Prepared] -> IO ()
reportCorpus root found prepared = do
  corpusBytes <- sum <$> mapM (fmap BS.length . BS.readFile . prepPath) prepared
  putStrLn
    ( "real-world corpus: "
        <> show (length prepared)
        <> " of "
        <> show found
        <> " sampled CPP-using modules from "
        <> root
        <> ", "
        <> show (corpusBytes `div` 1024)
        <> " KiB (raise AIHC_CPP_BENCH_MAX_BYTES to widen)"
    )
  mapM_ report tools
  where
    report (name, run) = do
      outcomes <- mapM (\p -> (,) (prepPath p) <$> tryTool (run root p)) prepared
      let failed = [(path, show err) | (path, Left err) <- outcomes]
          produced = sum (map outBytes (rights (map snd outcomes)))
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
  inBytes <- BS.length <$> BS.readFile (prepPath p)
  sizes <- mapM (\(name, run) -> (,) name <$> safely (run root p)) tools
  putStrLn
    ( caseName c
        <> ": in "
        <> show inBytes
        <> "B, out"
        <> concat [" " <> name <> " " <> show n | (name, n) <- sizes]
    )

-- | Run hpp over the preloaded lines, returning its output chunks.
hpp :: [FilePath] -> Prepared -> [BS.ByteString] -> IO [BS.ByteString]
hpp dirs p inputLines = do
  result <-
    runExceptT
      ( Hpp.runHpp
          (Hpp.initHppState (hppConfig dirs (prepPath p)) mempty)
          (Hpp.preprocess inputLines)
      )
  case result of
    Left err -> error ("hpp failed on " <> prepPath p <> ": " <> show err)
    Right (out, _) -> pure (Hpp.hppOutput out)

hppConfig :: [FilePath] -> FilePath -> HppConfig.Config
hppConfig dirs path =
  fromMaybe
    (error "hpp configuration incomplete")
    ( HppConfig.realizeConfig
        HppConfig.defaultConfigF
          { HppConfig.curFileNameF = Just path,
            HppConfig.includePathsF = Just (takeDirectory path : dirs)
          }
    )

-- | The same cpphs configuration the correctness oracle in @test/@ uses, so the
-- implementation being timed is the one already being compared against.
cpphsOptions :: [FilePath] -> CpphsOptions
cpphsOptions dirs =
  defaultCpphsOptions
    { boolopts = (boolopts defaultCpphsOptions) {stripC89 = True, warnings = False},
      includes = dirs
    }

-- | Where to look for an @#include@ target, beyond the including file's own
-- directory.
--
-- A real build passes include directories that a bare source tree does not
-- have: the RTS headers GHC ships (stubbed under @bench\/include@) and the
-- package's own @include@ directory, which Cabal adds from @include-dirs@.
-- Without them around a hundred modules per snapshot fail to resolve
-- @MachDeps.h@ alone, and since the three tools disagree about whether an
-- unresolvable include is fatal, the failure counts end up describing include
-- resolution rather than the preprocessors.
searchPath :: FilePath -> Prepared -> [FilePath]
searchPath root p = [stubIncludes, packageDir </> "include", packageDir, root]
  where
    -- Corpus layout is <root>/<package-version>/..., so the package directory
    -- is the first component below the root.
    packageDir = case stripPrefixDir root (prepPath p) of
      Just (component : _) -> root </> component
      _ -> takeDirectory (prepPath p)

-- | Directory holding stand-ins for headers a real build would supply.
--
-- Relative to the package root, which is where @cabal bench@ runs. Overridable
-- so the binary can be run from elsewhere; 'warnMissingStubs' says so if it is
-- not found, because the symptom otherwise is a quietly worse failure count
-- rather than an error.
stubIncludes :: FilePath
stubIncludes = unsafeStubIncludes

{-# NOINLINE unsafeStubIncludes #-}
unsafeStubIncludes :: FilePath
unsafeStubIncludes =
  unsafePerformIO (fromMaybe ("bench" </> "include") <$> lookupEnv "AIHC_CPP_BENCH_INCLUDE")

-- | Say so if the stub headers are not where they are expected.
warnMissingStubs :: IO ()
warnMissingStubs = do
  present <- doesDirectoryExist stubIncludes
  if present
    then putStrLn ("stub headers: " <> stubIncludes)
    else
      putStrLn
        ( "warning: no stub headers at "
            <> stubIncludes
            <> " (set AIHC_CPP_BENCH_INCLUDE); modules including MachDeps.h will not resolve"
        )

stripPrefixDir :: FilePath -> FilePath -> Maybe [FilePath]
stripPrefixDir root path = go (splitDirectories root) (splitDirectories path)
  where
    go [] rest = Just rest
    go (r : rs) (p : ps) | r == p = go rs ps
    go _ _ = Nothing

-- | Preprocess a file whose contents are already in memory, searching the given
-- directories for @#include@ targets as they are requested.
--
-- Includes are read from disk rather than preloaded because that is what cpphs
-- and hpp do: they take the entry file's contents and go to the file system for
-- the rest. Preloading them for aihc-cpp alone would hand it an advantage the
-- other two cannot have.
runAihc :: [FilePath] -> FilePath -> BS.ByteString -> IO Result
runAihc dirs path source =
  go (preprocess (defaultConfig {configInputFile = path}) source)
  where
    go (Done r) = pure r
    go (NeedInclude req k) = do
      contents <- firstExisting (candidates req)
      go (k contents)
    candidates req = [dir </> includePath req | dir <- includeDirs req]
    includeDirs req =
      let fromDir = takeDirectory (includeFrom req)
       in (if null fromDir then takeDirectory path else fromDir) : dirs
    firstExisting [] = pure Nothing
    firstExisting (candidate : rest) = do
      exists <- doesFileExist candidate
      if exists then Just <$> BS.readFile candidate else firstExisting rest
