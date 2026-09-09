{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Aihc.Cpp (Config (..), Diagnostic (..), Result (..), Severity (..), Step (..), defaultConfig, preprocess)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C
import qualified Data.Map.Strict as M
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import Test.Progress (CaseMeta (..), Outcome (..), evaluateCase, loadManifest)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)
import qualified Test.Tasty.QuickCheck as QC

main :: IO ()
main = do
  cases <- loadManifest
  checks <- mapM mkCase cases
  defaultMain
    ( testGroup
        "cpp-oracle"
        ( checks
            <> [linePragmaTest, dateTimeTest, functionMacroArgumentTest, functionMacroUnclosedCallTest, definedConditionSpacingTest, stringContinuationTests, tokenPastingTests, ccallLineCommentTest]
            <> [pragmaOnceTest, pragmaInsideBlockCommentTests, encodingTests]
            <> [QC.testProperty "dummy quickcheck property" prop_dummy]
        )
    )

-- | The preprocessor must be agnostic to the source encoding: bytes it
-- did not generate itself are copied through verbatim, whatever they
-- encode. GHC itself accepts an undecodable byte inside a comment (it
-- only rejects one where a token must be lexed), so rejecting such a
-- file outright would fail modules that really do compile.
encodingTests :: TestTree
encodingTests =
  testGroup
    "source encoding"
    [ testCase "latin-1 byte in a comment survives byte-for-byte" $ do
        -- The Stackage module that first exposed this: Ebnf2ps's
        -- Defaults.hs is ISO-8859-1 and has 0xA9 ((c)) in a comment.
        let input = "{-# LANGUAGE CPP #-}\n-- " <> byte 0xA9 <> " 2026\n#define X 1\nx = X\n"
            cfg = defaultConfig {configInputFile = "Defaults.hs"}
        preprocessTo cfg input
          @?= ("#line 1 \"Defaults.hs\"\n{-# LANGUAGE CPP #-}\n-- " <> byte 0xA9 <> " 2026\n\nx = 1\n"),
      testCase "no diagnostics for undecodable bytes" $ do
        let input = "-- " <> byte 0xA9 <> "\nx = 1\n"
        diagnosticsOf defaultConfig input @?= [],
      testCase "latin-1 bytes survive in a string literal and in code" $ do
        let input = "#define X 1\ns = \"" <> byte 0xE9 <> "\"\nc = X -- " <> byte 0xFF <> "\n"
        preprocessTo defaultConfig input
          @?= ("#line 1 \"<input>\"\n\ns = \"" <> byte 0xE9 <> "\"\nc = 1 -- " <> byte 0xFF <> "\n"),
      testCase "a lone continuation byte is not treated as whitespace" $ do
        -- 0xA0 is Latin-1 NBSP and 'Data.Char.isSpace'; treating it as
        -- whitespace would split a UTF-8 character in half.
        let input = "#define A" <> byte 0xA0 <> "B 1\nA" <> byte 0xA0 <> "B\n"
        preprocessTo defaultConfig input
          @?= "#line 1 \"<input>\"\n\n1\n",
      testCase "utf-8 identifiers still expand" $ do
        let input = TE.encodeUtf8 "#define caf\xe9 42\ncaf\xe9\n"
        preprocessTo defaultConfig input
          @?= TE.encodeUtf8 "#line 1 \"<input>\"\n\n42\n",
      testCase "arbitrary non-text bytes round-trip unchanged" $ do
        let payload = BS.pack [0x00, 0x80, 0xFE, 0xFF, 0xC0, 0x80, 0xED, 0xA0, 0x80]
            input = "-- " <> payload <> "\nx = 1\n"
        preprocessTo defaultConfig input
          @?= ("#line 1 \"<input>\"\n-- " <> payload <> "\nx = 1\n"),
      testCase "an undecodable include is preprocessed like any other" $ do
        let includeBytes = "-- " <> byte 0xA9 <> "\n"
        case preprocess defaultConfig {configInputFile = "root.hs"} "#include \"bad.h\"\nx = 1\n" of
          NeedInclude _ k ->
            case k (Just includeBytes) of
              Done result -> do
                [d | d <- resultDiagnostics result, diagSeverity d == Error] @?= []
                (byte 0xA9 `BS.isInfixOf` resultOutput result) @?= True
              _ -> assertFailure "expected Done"
          _ -> assertFailure "expected NeedInclude"
    ]

-- | Number of non-overlapping occurrences of a substring.
countSubstring :: BS.ByteString -> BS.ByteString -> Int
countSubstring needle = go 0
  where
    go n hay =
      case BS.breakSubstring needle hay of
        (_, rest)
          | BS.null rest -> n
          | otherwise -> go (n + 1) (BS.drop (BS.length needle) rest)

-- | A single raw byte, with no encoding applied.
byte :: Word8 -> BS.ByteString
byte b = BS.pack [b]

-- | Run 'preprocess' to completion and return the raw output bytes.
preprocessTo :: Config -> BS.ByteString -> BS.ByteString
preprocessTo cfg input =
  case preprocess cfg input of
    Done result -> resultOutput result
    _ -> error "expected Done"

diagnosticsOf :: Config -> BS.ByteString -> [Diagnostic]
diagnosticsOf cfg input =
  case preprocess cfg input of
    Done result -> resultDiagnostics result
    _ -> error "expected Done"

-- | Dummy QuickCheck property that always passes.
-- Added so that --quickcheck-tests flag is accepted by the test suite.
prop_dummy :: Bool
prop_dummy = True

dateTimeTest :: TestTree
dateTimeTest =
  testGroup
    "__DATE__ and __TIME__"
    [ testCase "expands to provided values" $ do
        let cfg =
              defaultConfig
                { configMacros =
                    M.fromList
                      [ ("__DATE__", "\"Mar 15 2026\""),
                        ("__TIME__", "\"12:00:00\"")
                      ]
                }
            input = TE.encodeUtf8 "__DATE__ __TIME__"
        case preprocess cfg input of
          Done result ->
            resultOutput result @?= "#line 1 \"<input>\"\n\"Mar 15 2026\" \"12:00:00\"\n"
          _ -> assertFailure "expected Done",
      testCase "defaults to unix epoch" $ do
        let cfg = defaultConfig
            input = TE.encodeUtf8 "__DATE__ __TIME__"
        case preprocess cfg input of
          Done result ->
            resultOutput result @?= "#line 1 \"<input>\"\n\"Jan  1 1970\" \"00:00:00\"\n"
          _ -> assertFailure "expected Done"
    ]

(@?=) :: (Eq a, Show a) => a -> a -> Assertion
actual @?= expected =
  if actual == expected
    then pure ()
    else assertFailure ("expected: " <> show expected <> "\n but got: " <> show actual)

mkCase :: CaseMeta -> IO TestTree
mkCase meta =
  pure $ testCase (caseId meta) (assertCase meta)

assertCase :: CaseMeta -> Assertion
assertCase meta = do
  (_, outcome, details) <- evaluateCase meta
  case outcome of
    OutcomeFail ->
      assertFailure
        ( "cpp regression in "
            <> caseId meta
            <> " ["
            <> caseCategory meta
            <> "]: "
            <> details
        )
    _ -> pure ()

linePragmaTest :: TestTree
linePragmaTest =
  testCase "include emits line pragmas" $
    case preprocess defaultConfig {configInputFile = "root.hs"} "before\n#include \"nested.inc\"\nafter" of
      NeedInclude _ k ->
        case k (Just "inside") of
          Done result -> do
            let out = C.lines (resultOutput result)
                hasIncludePragma = any (C.isSuffixOf "nested.inc\"") out
            if hasIncludePragma && "#line 3 \"root.hs\"" `elem` out
              then pure ()
              else assertFailure "expected include line pragmas in output"
          NeedInclude {} -> assertFailure "unexpected nested include in line pragma test"
      Done _ -> assertFailure "expected include continuation step"

functionMacroArgumentTest :: TestTree
functionMacroArgumentTest =
  testCase "function-like macro keeps nested argument text" $
    case preprocess defaultConfig "#define PAIR(x,y) x + y\nPAIR((1 + 2), 3)" of
      Done result ->
        resultOutput result @?= "#line 1 \"<input>\"\n\n(1 + 2) + 3\n"
      _ -> assertFailure "expected Done"

functionMacroUnclosedCallTest :: TestTree
functionMacroUnclosedCallTest =
  testCase "unterminated function-like call does not expand macro" $
    case preprocess defaultConfig "#define ID() replaced\nID(" of
      Done result ->
        resultOutput result @?= "#line 1 \"<input>\"\n\nID(\n"
      _ -> assertFailure "expected Done"

definedConditionSpacingTest :: TestTree
definedConditionSpacingTest =
  testCase "defined handles whitespace around parenthesized name" $
    case preprocess defaultConfig "#define FLAG 1\n#if defined   ( FLAG )\nok\n#else\nbad\n#endif" of
      Done result ->
        if "ok\n" `C.isInfixOf` resultOutput result && not ("bad\n" `C.isInfixOf` resultOutput result)
          then pure ()
          else assertFailure ("expected ok branch to be active, output was: " <> show (resultOutput result))
      _ -> assertFailure "expected Done"

stringContinuationTests :: TestTree
stringContinuationTests =
  testGroup
    "Haskell string continuations"
    [ testCase "ordinary string accepts GCC double-backslash continuation" $
        assertPreprocessOutput
          gccStringContinuationInput
          (C.unlines ["#line 1 \"<input>\"", "x = \"a\\       \\b\""]),
      testCase "ordinary string preserves GHC single-backslash gap" $
        assertPreprocessOutput
          ghcStringGapInput
          (C.unlines ["#line 1 \"<input>\"", "x = \"a\\", "       \\b\""]),
      testCase "function macro argument accepts GCC double-backslash continuation" $
        assertPreprocessOutput
          gccStringContinuationMacroInput
          (C.unlines ["#line 1 \"<input>\"", "", "x = \"a\\       \\b\""]),
      testCase "function macro argument preserves GHC single-backslash gap" $
        assertPreprocessOutput
          ghcStringGapMacroInput
          (C.unlines ["#line 1 \"<input>\"", "", "x = \"a\\", "       \\b\""]),
      testCase "GCC continuation tracks string gaps across concatenation" $
        assertPreprocessOutput
          gccStringContinuationConcatInput
          (C.unlines ["#line 1 \"<input>\"", "x = \"a\\       \\\" <> y <> \"\\n\\       \\b\""]),
      testCase "double backslash outside strings is not line-spliced" $
        assertPreprocessOutput
          nonStringDoubleBackslashInput
          (C.unlines ["#line 1 \"<input>\"", "", "x = foo \\\\", "       bar"])
    ]

assertPreprocessOutput :: BS.ByteString -> BS.ByteString -> Assertion
assertPreprocessOutput input expected =
  case preprocess defaultConfig input of
    Done result -> resultOutput result @?= expected
    _ -> assertFailure "expected Done"

tokenPastingTests :: TestTree
tokenPastingTests =
  testGroup
    "token pasting"
    [ testCase "CCALL macro expands stringizing and token pasting" $
        case preprocess defaultConfig ccallMacroInput of
          Done result ->
            if "foreign import ccall unsafe \"foo\"" `C.isInfixOf` resultOutput result
              && "c_foo :: Int -> IO Int" `C.isInfixOf` resultOutput result
              then pure ()
              else assertFailure ("expected CCALL expansion in output, got: " <> show (resultOutput result))
          _ -> assertFailure "expected Done",
      testCase "token pasting joins both sides without expanding arguments first" $
        case preprocess defaultConfig tokenPasteRawArgInput of
          Done result ->
            resultOutput result @?= "#line 1 \"<input>\"\n\n\nXY\n"
          _ -> assertFailure "expected Done",
      testCase "token pasting result is rescanned for further macro expansion" $
        case preprocess defaultConfig tokenPasteRescanInput of
          Done result ->
            resultOutput result @?= "#line 1 \"<input>\"\n\n\n42\n"
          _ -> assertFailure "expected Done",
      testCase "token pasting supports prefix and suffix forms" $
        case preprocess defaultConfig tokenPasteAffixInput of
          Done result ->
            resultOutput result @?= "#line 1 \"<input>\"\n\n\nleft right\n"
          _ -> assertFailure "expected Done",
      testCase "token pasting supports chained concatenation" $
        case preprocess defaultConfig tokenPasteChainedInput of
          Done result ->
            resultOutput result @?= "#line 1 \"<input>\"\n\nfoobar\n"
          _ -> assertFailure "expected Done",
      testCase "token pasting survives Haskell block comments in arguments" $
        case preprocess defaultConfig tokenPasteHsCommentInput of
          Done result ->
            resultOutput result
              @?= "#line 1 \"<input>\"\n\n{-# INLINE _bar #-}; _bar :: LensP Foo Baz{-comment-}; _bar = lens bar $ \\ Foo {..} bar_ -> Foo {bar = bar_, ..}\n"
          _ -> assertFailure "expected Done"
    ]

ccallLineCommentTest :: TestTree
ccallLineCommentTest =
  testCase "CCALL macro with -- comment in argument list" $
    case preprocess defaultConfig ccallLineCommentInput of
      Done result ->
        if "foreign import ccall unsafe \"xls_wb_sheetcount\"" `C.isInfixOf` resultOutput result
          && "c_xls_wb_sheetcount :: XLSWorkbook -> IO CInt" `C.isInfixOf` resultOutput result
          && " -- Int32" `C.isInfixOf` resultOutput result
          then pure ()
          else assertFailure ("expected CCALL expansion with line comment, got: " <> show (resultOutput result))
      _ -> assertFailure "expected Done"

pragmaOnceTest :: TestTree
pragmaOnceTest =
  testCase "#pragma once skips repeated includes" $
    case preprocess defaultConfig {configInputFile = "root.hs"} "#include \"guarded.inc\"\n#include \"guarded.inc\"\nafter" of
      NeedInclude _ k1 ->
        case k1 (Just "#pragma once\ninside") of
          NeedInclude {} -> assertFailure "second include should be skipped"
          Done result -> do
            let output = resultOutput result
            if countSubstring "inside" output == 1 && "after\n" `C.isSuffixOf` output
              then pure ()
              else assertFailure ("expected guarded include once, got: " <> show output)
      Done _ -> assertFailure "expected include continuation step"

pragmaInsideBlockCommentTests :: TestTree
pragmaInsideBlockCommentTests =
  testGroup
    "pragma inside a Haskell block comment"
    [ testCase "#-} does not close the enclosing comment" $
        case preprocess defaultConfig pragmaInBlockCommentInput of
          Done result -> do
            resultDiagnostics result @?= []
            resultOutput result
              @?= "#line 1 \"<input>\"\n{-\n#if 0\n{-# INLINABLE foo #-}\n#endif\n-}\nlive\n"
          _ -> assertFailure "expected Done",
      testCase "commented-out #if 0 does not delete live code" $
        case preprocess defaultConfig pragmaInBlockCommentElseInput of
          Done result -> do
            resultDiagnostics result @?= []
            if "kept" `C.isInfixOf` resultOutput result
              then pure ()
              else assertFailure ("expected commented-out branch to stay intact, got: " <> show (resultOutput result))
          _ -> assertFailure "expected Done"
    ]

pragmaInBlockCommentInput :: BS.ByteString
pragmaInBlockCommentInput =
  C.unlines
    [ "{-",
      "#if 0",
      "{-# INLINABLE foo #-}",
      "#endif",
      "-}",
      "live"
    ]

pragmaInBlockCommentElseInput :: BS.ByteString
pragmaInBlockCommentElseInput =
  C.unlines
    [ "{-",
      "{-# INLINABLE foo #-}",
      "#if 0",
      "kept",
      "#else",
      "also kept",
      "#endif",
      "-}",
      "live"
    ]

ccallLineCommentInput :: BS.ByteString
ccallLineCommentInput =
  C.unlines
    [ "#define CCALL(name,signature) \\",
      "foreign import ccall unsafe #name \\",
      "    c_##name :: signature",
      "",
      "CCALL(xls_wb_sheetcount, XLSWorkbook -> IO CInt -- Int32)"
    ]

ccallMacroInput :: BS.ByteString
ccallMacroInput =
  C.unlines
    [ "#define CCALL(name,signature) \\",
      "foreign import ccall unsafe #name \\",
      "    c_##name :: signature",
      "",
      "CCALL(foo, Int -> IO Int)"
    ]

tokenPasteRawArgInput :: BS.ByteString
tokenPasteRawArgInput =
  C.unlines
    [ "#define X Y",
      "#define JOIN(a,b) a##b",
      "JOIN(X,Y)"
    ]

tokenPasteRescanInput :: BS.ByteString
tokenPasteRescanInput =
  C.unlines
    [ "#define VALUE 42",
      "#define JOIN(a,b) a##b",
      "JOIN(VAL,UE)"
    ]

tokenPasteAffixInput :: BS.ByteString
tokenPasteAffixInput =
  C.unlines
    [ "#define PREFIX(name) left##name",
      "#define SUFFIX(name) name##right",
      "PREFIX() SUFFIX()"
    ]

tokenPasteChainedInput :: BS.ByteString
tokenPasteChainedInput =
  C.unlines
    [ "#define CHAIN(a,b,c) a##b##c",
      "CHAIN(foo,bar,)"
    ]

tokenPasteHsCommentInput :: BS.ByteString
tokenPasteHsCommentInput =
  C.unlines
    [ "#define LENS(S,F,A) {-# INLINE _/**/F #-}; _/**/F :: LensP S A; _/**/F = lens F $ \\ S {..} F/**/_ -> S {F = F/**/_, ..}",
      "LENS(Foo,bar,Baz{-comment-})"
    ]

gccStringContinuationInput :: BS.ByteString
gccStringContinuationInput =
  C.unlines
    [ "x = \"a\\\\",
      "       \\b\""
    ]

ghcStringGapInput :: BS.ByteString
ghcStringGapInput =
  C.unlines
    [ "x = \"a\\",
      "       \\b\""
    ]

gccStringContinuationMacroInput :: BS.ByteString
gccStringContinuationMacroInput =
  C.unlines
    [ "#define ID(x) x",
      "x = ID(\"a\\\\",
      "       \\b\")"
    ]

ghcStringGapMacroInput :: BS.ByteString
ghcStringGapMacroInput =
  C.unlines
    [ "#define ID(x) x",
      "x = ID(\"a\\",
      "       \\b\")"
    ]

gccStringContinuationConcatInput :: BS.ByteString
gccStringContinuationConcatInput =
  C.unlines
    [ "x = \"a\\\\",
      "       \\\" <> y <> \"\\n\\\\",
      "       \\b\""
    ]

nonStringDoubleBackslashInput :: BS.ByteString
nonStringDoubleBackslashInput =
  C.unlines
    [ "#define ID(x) x",
      "x = ID(foo \\\\",
      "       bar)"
    ]
