{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic corpus generation for the aihc-cpp benchmarks.
--
-- The corpus is generated rather than committed so that it can be resized
-- without churning the repository, and it is fully deterministic so that two
-- runs on two machines benchmark byte-identical inputs.
--
-- The cases are chosen to isolate the different costs a preprocessor pays, so
-- that a regression can be attributed to one of them rather than showing up as
-- a single number that moved.
--
-- This corpus is artificial, and it is worth being explicit about where it
-- departs from reality. Measured over 1,631 CPP-using modules from 211 Hackage
-- packages: the median module is 6.2KB with 3.5% directive lines; conditionals
-- dominate the directive mix (@#if@ and @#endif@ together outnumber @#define@
-- by more than ten to one); @__GLASGOW_HASKELL__@, @MIN_VERSION_base@ and
-- @mingw32_HOST_OS@ account for most macro references, nearly all of them
-- inside @#if@ conditions rather than expanded into the output; and a module
-- that includes anything usually includes one or two headers.
--
-- So 'passthroughCase' and 'conditionalsCase' are close to real code, while
-- 'macrosCase' (a function-like macro expanded on every line) and
-- 'includesCase' (24 included files) are far heavier than anything real.
-- They are useful for isolating a cost, and misleading if read as a workload.
-- Point the benchmark at real source instead — see the AIHC_CPP_BENCH_CORPUS
-- setting in @bench\/Micro.hs@ — before drawing conclusions about throughput.
module Bench.Corpus
  ( CorpusCase (..),
    corpusCases,
    generateCorpus,
    defaultCorpusRoot,
  )
where

import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

-- | Where the generated corpus goes by default.
--
-- Deliberately outside @src@, @test@, @app@ and @bench@, the directories the
-- formatter and linter walk. A generated corpus is megabytes of machine-written
-- Haskell full of redundant brackets, and hlint follows @#include@ directives,
-- so letting a linter reach it produces six-figure hint counts and exhausts
-- memory. Putting it under @dist-newstyle@ makes that structurally impossible
-- rather than depending on an exclusion pattern staying correct, and means
-- @cabal clean@ disposes of it.
defaultCorpusRoot :: FilePath
defaultCorpusRoot = "dist-newstyle" </> "bench-corpus"

-- | One benchmark input: a top-level file plus any files it includes.
data CorpusCase = CorpusCase
  { -- | Short identifier, also the basename of the generated file.
    caseName :: !String,
    -- | Human-readable note about what this case stresses.
    caseDescription :: !String,
    -- | Path of the entry file, relative to the corpus root.
    caseEntry :: !FilePath,
    -- | All files to write, relative to the corpus root.
    caseFiles :: [(FilePath, String)]
  }

-- | Rough target size, in lines, for each generated case.
--
-- Large enough that a single run takes milliseconds rather than microseconds,
-- so the measurement is not dominated by timer resolution, and small enough
-- that a full sweep of three preprocessors stays interactive.
caseLines :: Int
caseLines = 4000

-- | The benchmark corpus.
--
-- The mix is deliberately weighted towards 'passthrough', because that is what
-- real CPP-using Haskell looks like: a few directives at the top and thousands
-- of lines the preprocessor merely has to copy. The remaining cases isolate
-- individual costs so a regression can be attributed.
corpusCases :: [CorpusCase]
corpusCases =
  [ passthroughCase,
    conditionalsCase,
    macrosCase,
    literalsCase,
    includesCase
  ]

-- | Write the corpus under the given root directory.
generateCorpus :: FilePath -> IO ()
generateCorpus root = do
  createDirectoryIfMissing True root
  createDirectoryIfMissing True (root </> "includes")
  mapM_ writeCase corpusCases
  where
    writeCase c = mapM_ writeOne (caseFiles c)
    writeOne (path, contents) = writeFile (root </> path) contents

-- ---------------------------------------------------------------------------
-- Deterministic pseudo-randomness
-- ---------------------------------------------------------------------------

-- | A tiny linear congruential generator (the Numerical Recipes constants).
--
-- Avoids a dependency on @random@ and, more importantly, pins the corpus to an
-- exact byte sequence that does not drift between library versions.
lcg :: Int -> Int
lcg s = (s * 1664525 + 1013904223) `mod` 2147483648

-- | An infinite deterministic stream of values drawn from a list.
pick :: Int -> [a] -> [a]
pick seed xs = go seed
  where
    n = length xs
    go s = let s' = lcg s in (xs !! (s' `mod` n)) : go s'

-- ---------------------------------------------------------------------------
-- Cases
-- ---------------------------------------------------------------------------

-- | Ordinary Haskell with a realistic sprinkling of directives.
--
-- Roughly 5% directive lines, with the rest simply copied through. This is the
-- case that best predicts the cost a preprocessor adds to a real compile, and
-- the one to weight most heavily when reading the results.
passthroughCase :: CorpusCase
passthroughCase =
  CorpusCase
    { caseName = "passthrough",
      caseDescription = "realistic module: ~5% directives, the rest copied through",
      caseEntry = "passthrough.hs",
      caseFiles = [("passthrough.hs", body)]
    }
  where
    body = unlines (header <> concat (take (caseLines `div` 20) chunks))
    header =
      [ "{-# LANGUAGE CPP #-}",
        "module Passthrough where",
        "#define VERSION_base 1",
        "#define HAS_FEATURE(x) (x)"
      ]
    chunks = zipWith chunk [0 :: Int ..] (pick 1 [0 .. 9 :: Int])
    chunk i r =
      [ "",
        "-- | Documentation for value " <> show i <> ".",
        "value" <> show i <> " :: Int -> Int",
        "value" <> show i <> " x = x + " <> show (r * i `mod` 97),
        "",
        "helper" <> show i <> " :: [Int] -> Int",
        "helper" <> show i <> " xs = sum (map value" <> show i <> " xs)",
        ""
      ]
        <> ( if i `mod` 5 == 0
               then
                 [ "#ifdef VERSION_base",
                   "guarded" <> show i <> " :: Int",
                   "guarded" <> show i <> " = " <> show i,
                   "#else",
                   "guarded" <> show i <> " :: Int",
                   "guarded" <> show i <> " = 0",
                   "#endif"
                 ]
               else
                 [ "plain" <> show i <> " :: Int",
                   "plain" <> show i <> " = " <> show i
                 ]
           )
        <> replicate 8 ("-- filler comment line for value " <> show i)

-- | Dense, deeply nested conditionals with arithmetic and @defined@.
conditionalsCase :: CorpusCase
conditionalsCase =
  CorpusCase
    { caseName = "conditionals",
      caseDescription = "nested #if/#elif/#else with arithmetic and defined()",
      caseEntry = "conditionals.hs",
      caseFiles = [("conditionals.hs", body)]
    }
  where
    body = unlines (header <> concatMap block [0 .. caseLines `div` 16])
    header =
      [ "{-# LANGUAGE CPP #-}",
        "module Conditionals where",
        "#define MAJOR 9",
        "#define MINOR 12",
        "#define GLASGOW_HASKELL 912",
        "#define WORD_SIZE_IN_BITS 64"
      ]
    block i =
      [ "#if MAJOR > 8 && MINOR >= 4",
        "#  if defined(GLASGOW_HASKELL) && GLASGOW_HASKELL >= 900",
        "#    if WORD_SIZE_IN_BITS == 64",
        "cond" <> show i <> " :: Int",
        "cond" <> show i <> " = " <> show i,
        "#    else",
        "cond" <> show i <> " :: Int",
        "cond" <> show i <> " = 0",
        "#    endif",
        "#  elif defined(MISSING)",
        "cond" <> show i <> " = -1",
        "#  else",
        "cond" <> show i <> " = -2",
        "#  endif",
        "#else",
        "cond" <> show i <> " = -3",
        "#endif"
      ]

-- | Heavy object- and function-like macro expansion.
macrosCase :: CorpusCase
macrosCase =
  CorpusCase
    { caseName = "macros",
      caseDescription = "object- and function-like macro expansion on every line",
      caseEntry = "macros.hs",
      caseFiles = [("macros.hs", body)]
    }
  where
    body = unlines (header <> concatMap block [0 .. caseLines `div` 6])
    header =
      [ "{-# LANGUAGE CPP #-}",
        "module Macros where",
        "#define MIN_VERSION_base(a,b,c) 1",
        "#define WRAP(x) (fromIntegral (x))",
        "#define PAIR(a,b) ((a), (b))",
        "#define NAME base",
        "#define WIDE(a,b,c,d) ((a) + (b) + (c) + (d))"
      ]
    block i =
      [ "macro" <> show i <> " :: Int",
        "macro" <> show i <> " = WRAP(" <> show i <> ")",
        "pair" <> show i <> " = PAIR(" <> show i <> ", " <> show (i + 1) <> ")",
        "wide" <> show i <> " = WIDE(" <> show i <> ", 2, 3, 4)",
        "#if MIN_VERSION_base(4,16,0)",
        "gated" <> show i <> " = WRAP(" <> show i <> ")",
        "#endif"
      ]

-- | String, character and comment heavy input.
--
-- Haskell-aware preprocessors track Haskell block comments and string literals
-- so they can avoid expanding macros inside them. That scanning is real work,
-- and the three implementations do differing amounts of it, so it gets its own
-- case rather than quietly taxing the average of the others.
literalsCase :: CorpusCase
literalsCase =
  CorpusCase
    { caseName = "literals",
      caseDescription = "string/char literals and Haskell comments (macro-suppression scanning)",
      caseEntry = "literals.hs",
      caseFiles = [("literals.hs", body)]
    }
  where
    body = unlines (header <> concatMap block [0 .. caseLines `div` 8])
    header =
      [ "{-# LANGUAGE CPP #-}",
        "module Literals where",
        "#define NAME notExpandedInStrings"
      ]
    block i =
      [ "text" <> show i <> " :: String",
        "text" <> show i <> " = \"NAME must not be expanded here \" ++ show " <> show i,
        "chars" <> show i <> " = ['N', 'A', 'M', 'E']",
        "{- NAME inside a Haskell block comment",
        "   spanning several lines, still NAME -}",
        "prime" <> show i <> "' = " <> show i <> " -- NAME in a line comment",
        "escaped" <> show i <> " = \"a \\\"NAME\\\" quoted\"",
        ""
      ]

-- | An include chain, exercising the continuation-based include protocol.
includesCase :: CorpusCase
includesCase =
  CorpusCase
    { caseName = "includes",
      caseDescription = "chain of #include files resolved through the continuation API",
      caseEntry = "includes.hs",
      caseFiles = ("includes.hs", entry) : map leaf [0 .. leafCount - 1]
    }
  where
    leafCount = 24 :: Int
    entry =
      unlines
        ( [ "{-# LANGUAGE CPP #-}",
            "module Includes where"
          ]
            <> ["#include \"includes/part" <> show n <> ".inc\"" | n <- [0 .. leafCount - 1]]
        )
    leaf n =
      ( "includes" </> ("part" <> show n <> ".inc"),
        unlines
          ( [ "#ifndef PART" <> show n,
              "#define PART" <> show n <> " 1",
              "#define PART" <> show n <> "_VALUE(x) ((x) + " <> show n <> ")"
            ]
              <> concat
                [ [ "part" <> show n <> "_" <> show k <> " :: Int",
                    "part" <> show n <> "_" <> show k <> " = PART" <> show n <> "_VALUE(" <> show k <> ")"
                  ]
                | k <- [0 .. (caseLines `div` leafCount) - 1 :: Int]
                ]
              <> ["#endif"]
          )
      )
