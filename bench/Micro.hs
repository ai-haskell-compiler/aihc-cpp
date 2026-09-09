{-# LANGUAGE OverloadedStrings #-}

-- | Raw throughput of aihc-cpp against the other two pure-Haskell C
-- preprocessors on Hackage, hpp and cpphs.
--
-- All three run in-process as libraries, on the same preloaded bytes, with
-- their output forced to normal form. Nothing but preprocessing is timed: no
-- process startup, no reading the entry file, no lazy IO left unevaluated.
--
-- This deliberately does not check that the three agree. Preprocessing Haskell
-- is under-specified — the tools differ on comment handling, on rescanning, on
-- what survives inside a literal — and demanding equivalence would mean either
-- excluding the interesting inputs or holding aihc-cpp to another
-- implementation's accidents. The test suite is where behaviour is pinned down;
-- this is where speed is. The output sizes printed at startup are a sanity
-- check that the three are doing comparable amounts of work, not a contract.
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
import Control.Exception (evaluate)
import Control.Monad.Trans.Except (runExceptT)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
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
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty.Bench (bench, bgroup, defaultMain, nfIO)

-- | Where the generated corpus lives. Overridable so a developer can point the
-- benchmark at a directory of real-world modules instead.
corpusRoot :: IO FilePath
corpusRoot = fromMaybe defaultCorpusRoot <$> lookupEnv "AIHC_CPP_BENCH_CORPUS"

-- | A case with its entry file preloaded in each preprocessor's input type.
--
-- The conversions happen here, outside the timed region, so that no tool is
-- charged for the shape of its own API.
data Prepared = Prepared
  { prepCase :: !CorpusCase,
    prepPath :: !FilePath,
    prepBytes :: !BS.ByteString,
    prepString :: !String,
    prepLines :: ![BS.ByteString]
  }

main :: IO ()
main = do
  root <- corpusRoot
  generateCorpus root
  prepared <- mapM (prepare root) corpusCases
  mapM_ (reportSizes root) prepared
  defaultMain
    [ bgroup
        (caseName (prepCase p))
        [ bench "aihc-cpp" (nfIO (resultOutput <$> runAihc (prepPath p) (prepBytes p))),
          bench "hpp" (nfIO (hpp root p)),
          bench "cpphs" (nfIO (runCpphs (cpphsOptions root) (prepPath p) (prepString p)))
        ]
    | p <- prepared
    ]

prepare :: FilePath -> CorpusCase -> IO Prepared
prepare root c = do
  let path = root </> caseEntry c
  bytes <- BS.readFile path
  Prepared c path bytes
    <$> evaluate (force (BS8.unpack bytes))
    <*> evaluate (force (BS8.lines bytes))

-- | Print how much output each tool produces, once, before timing.
--
-- Not a correctness check. It is here so that a wildly faster result is not
-- mistaken for a win when it is really a tool that gave up early or emitted far
-- less; a reader can see at a glance whether the three are in the same range.
reportSizes :: FilePath -> Prepared -> IO ()
reportSizes root p = do
  ours <- T.length . resultOutput <$> runAihc (prepPath p) (prepBytes p)
  theirHpp <- sum . map BS.length <$> hpp root p
  theirCpphs <- length <$> runCpphs (cpphsOptions root) (prepPath p) (prepString p)
  putStrLn
    ( caseName (prepCase p)
        <> ": in "
        <> show (BS.length (prepBytes p))
        <> "B, out aihc-cpp "
        <> show ours
        <> " hpp "
        <> show theirHpp
        <> " cpphs "
        <> show theirCpphs
    )

-- | Run hpp over the preloaded lines, returning its output chunks.
hpp :: FilePath -> Prepared -> IO [BS.ByteString]
hpp root p = do
  result <-
    runExceptT
      ( Hpp.runHpp
          (Hpp.initHppState (hppConfig root (prepPath p)) mempty)
          (Hpp.preprocess (prepLines p))
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
            HppConfig.includePathsF = Just [root]
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
