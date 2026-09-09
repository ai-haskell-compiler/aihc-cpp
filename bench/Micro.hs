{-# LANGUAGE OverloadedStrings #-}

-- | In-process benchmark: aihc-cpp against cpphs, the other pure-Haskell C
-- preprocessor, on identical preloaded inputs.
--
-- This is the layer to watch for regressions. Both implementations are
-- libraries called in the same process, on the same bytes, with results forced
-- to normal form, so the only thing measured is preprocessing: no process
-- startup, no file system, no lazy IO left unevaluated.
--
-- GHC's preprocessor cannot take part here — it is a separate binary — so the
-- comparison against GHC lives in @bench/compare-ghc.sh@ instead.
module Main (main) where

import Bench.Corpus (CorpusCase (..), corpusCases, defaultCorpusRoot, generateCorpus)
import Bench.Run (LoadedCase (..), loadCase, runAihcPure)
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import qualified Data.ByteString.Char8 as BS8
import Data.Maybe (fromMaybe)
import Language.Preprocessor.Cpphs
  ( BoolOptions (..),
    CpphsOptions (..),
    defaultCpphsOptions,
    runCpphs,
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Test.Tasty.Bench (bench, bgroup, defaultMain, nf, nfIO)

-- | Where the generated corpus lives. Overridable so CI can point it at a
-- scratch directory, or a developer at a directory of real-world modules.
corpusRoot :: IO FilePath
corpusRoot = fromMaybe defaultCorpusRoot <$> lookupEnv "AIHC_CPP_BENCH_CORPUS"

main :: IO ()
main = do
  root <- corpusRoot
  generateCorpus 1 root
  prepared <- mapM (prepare root) (corpusCases 1)
  defaultMain
    [ bgroup
        (caseName c)
        [ bench "aihc-cpp" (nf runAihcPure lc),
          bench "cpphs" (nfIO (runCpphs (cpphsOptions root) (loadedPath lc) srcString))
        ]
    | (c, lc, srcString) <- prepared
    ]

-- | Load a case and pre-convert its source to the 'String' cpphs wants.
--
-- The conversion is forced here, outside the timed region: cpphs is being
-- measured on preprocessing, not on the cost of Haskell's @String@.
prepare :: FilePath -> CorpusCase -> IO (CorpusCase, LoadedCase, String)
prepare root c = do
  lc <- loadCase (root </> caseEntry c)
  srcString <- evaluate (force (BS8.unpack (loadedSource lc)))
  pure (c, lc, srcString)

-- | The same cpphs configuration the correctness oracle in @test/@ uses, so the
-- implementation being timed is the one being checked for agreement.
cpphsOptions :: FilePath -> CpphsOptions
cpphsOptions root =
  defaultCpphsOptions
    { boolopts = (boolopts defaultCpphsOptions) {stripC89 = True, warnings = False},
      includes = [root]
    }
