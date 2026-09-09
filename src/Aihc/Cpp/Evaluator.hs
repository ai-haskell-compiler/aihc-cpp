{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Aihc.Cpp.Evaluator
  ( expandMacros,
    expandMacrosMultiline,
    substituteParams,
    evalCondition,
    evalNumeric,
    Token (..),
    tokenize,
    parseExpr,
    parseOr,
    parseAnd,
    parseEq,
    parseRel,
    parseAdd,
    parseMul,
    parseUnary,
    parseAtom,
    replaceDefined,
    replaceRemainingWithZero,
  )
where

import Aihc.Cpp.Parser (isIdentChar, isIdentStart, isOpChar, isSpaceChar)
import Aihc.Cpp.Types (EngineState (..), MacroDef (..))
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BSB
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S

-- | Expand macros in a single piece of text using the blue-paint algorithm.
-- A single pass with a suppression set replaces the previous iterate-up-to-32
-- fixpoint approach.
expandMacros :: EngineState -> ByteString -> ByteString
expandMacros st txt =
  builderToBytes (expandBlue st S.empty False False False (BSB.byteString txt))

-- | Expand macros with multi-line support. When a function-like macro call
-- spans multiple lines, continuation lines are consumed from @moreLines@.
-- Returns the expanded text and the number of extra lines consumed.
expandMacrosMultiline :: EngineState -> ByteString -> [ByteString] -> (ByteString, Int)
expandMacrosMultiline st txt moreLines =
  let extraNeeded = countExtraLinesConsumed st txt moreLines
   in if extraNeeded == 0
        then (expandMacros st txt, 0)
        else
          let combinedLines = txt : take extraNeeded moreLines
              combined = C.intercalate "\n" combinedLines
              expanded = expandMacros st combined
           in (expanded, extraNeeded)

-- | Count how many extra lines a function macro call consumes.
-- Scans the first line for an identifier that matches a function macro,
-- then checks if parseCallArgs needs to span into continuation lines.
countExtraLinesConsumed :: EngineState -> ByteString -> [ByteString] -> Int
countExtraLinesConsumed st txt moreLines = scanForFunctionMacro False False False txt
  where
    macros = stMacros st

    scanForFunctionMacro :: Bool -> Bool -> Bool -> ByteString -> Int
    scanForFunctionMacro _ _ _ t | C.null t = 0
    scanForFunctionMacro inString inChar escaped t =
      case C.uncons t of
        Nothing -> 0
        Just (c, rest)
          | inString ->
              let escaped' = c == '\\' && not escaped
                  inString' = not (c == '"' && not escaped)
               in scanForFunctionMacro inString' False escaped' rest
          | inChar ->
              let escaped' = c == '\\' && not escaped
                  inChar' = not (c == '\'' && not escaped)
               in scanForFunctionMacro False inChar' escaped' rest
          | startsHsBlockComment t ->
              let (_, remaining) = consumeHsBlockComment t
               in scanForFunctionMacro False False False remaining
          | c == '"' -> scanForFunctionMacro True False False rest
          | c == '\'' -> scanForFunctionMacro False True False rest
          | isIdentStart c ->
              let (ident, rest') = C.span isIdentChar t
               in case M.lookup ident macros of
                    Just (FunctionMacro _ _) ->
                      case tryMultilineCallArgs rest' of
                        Just n -> n
                        Nothing -> scanForFunctionMacro False False False rest'
                    _ -> scanForFunctionMacro False False False rest'
          | otherwise -> scanForFunctionMacro False False False rest

    -- Try to parse function call args, potentially spanning multiple lines.
    -- Returns Just n if the call spans n extra lines, Nothing if no call.
    tryMultilineCallArgs :: ByteString -> Maybe Int
    tryMultilineCallArgs rest = seekOpenParen (C.dropWhile isSpaceChar rest) 0

    seekOpenParen :: ByteString -> Int -> Maybe Int
    seekOpenParen remaining extraLines =
      case C.uncons remaining of
        Just ('(', afterOpen) ->
          findClosingParen 0 afterOpen extraLines
        Just _ ->
          Nothing
        Nothing ->
          case drop extraLines moreLines of
            [] -> Nothing
            (nextLine : _) ->
              seekOpenParen (C.dropWhile isSpaceChar nextLine) (extraLines + 1)

    findClosingParen :: Int -> ByteString -> Int -> Maybe Int
    findClosingParen = goClosing False False False
      where
        goClosing :: Bool -> Bool -> Bool -> Int -> ByteString -> Int -> Maybe Int
        goClosing inString inChar escaped depth remaining extraLines =
          case C.uncons remaining of
            Nothing ->
              -- Need more lines
              case drop extraLines moreLines of
                [] -> Nothing -- No more lines, unclosed call
                (nextLine : _) ->
                  goClosing inString inChar escaped depth (C.cons '\n' nextLine) (extraLines + 1)
            Just (ch, rest)
              | inString ->
                  let escaped' = ch == '\\' && not escaped
                      inString' = not (ch == '"' && not escaped)
                   in goClosing inString' False escaped' depth rest extraLines
              | inChar ->
                  let escaped' = ch == '\\' && not escaped
                      inChar' = not (ch == '\'' && not escaped)
                   in goClosing False inChar' escaped' depth rest extraLines
              | startsHsBlockComment remaining ->
                  let (_, afterComment) = consumeHsBlockComment remaining
                   in goClosing False False False depth afterComment extraLines
              | ch == '"' -> goClosing True False False depth rest extraLines
              | ch == '\'' -> goClosing False True False depth rest extraLines
              | ch == '(' -> goClosing False False False (depth + 1) rest extraLines
              | ch == ')' && depth > 0 -> goClosing False False False (depth - 1) rest extraLines
              | ch == ')' -> Just extraLines
              | otherwise -> goClosing False False False depth rest extraLines

-- | Blue-paint macro expansion engine. Uses a suppression set (@painted@)
-- to prevent infinite recursion instead of iterating to a fixpoint.
-- Output is accumulated via a lazy 'BSB.Builder' for amortized O(n).
expandBlue :: EngineState -> Set ByteString -> Bool -> Bool -> Bool -> BSB.Builder -> BSB.Builder
expandBlue st painted inString inChar escaped input =
  let txt = builderToBytes input
   in goText st painted inString inChar escaped txt mempty

-- | Walk the input text, expanding macros with blue-paint suppression.
goText :: EngineState -> Set ByteString -> Bool -> Bool -> Bool -> ByteString -> BSB.Builder -> BSB.Builder
goText _ _ _ _ _ txt acc | C.null txt = acc
goText st painted inString inChar escaped txt acc =
  case C.uncons txt of
    Nothing -> acc
    Just (c, rest)
      | inString ->
          let escaped' = c == '\\' && not escaped
              inString' = not (c == '"' && not escaped)
           in goText st painted inString' False escaped' rest (acc <> BSB.char8 c)
      | inChar ->
          let escaped' = c == '\\' && not escaped
              inChar' = not (c == '\'' && not escaped)
           in goText st painted False inChar' escaped' rest (acc <> BSB.char8 c)
      | startsHsBlockComment txt ->
          let (commentText, remaining) = consumeHsBlockComment txt
           in goText st painted False False False remaining (acc <> BSB.byteString commentText)
      | c == '"' ->
          goText st painted True False False rest (acc <> BSB.char8 c)
      | c == '\'' ->
          goText st painted False True False rest (acc <> BSB.char8 c)
      | isIdentStart c ->
          expandIdentBlue st painted txt acc
      | c == '-',
        Just ('-', _) <- C.uncons rest ->
          -- Haskell line comment: copy remainder verbatim without macro expansion
          acc <> BSB.byteString txt
      | otherwise ->
          goText st painted False False False rest (acc <> BSB.char8 c)

-- | Handle an identifier during blue-paint expansion.
expandIdentBlue :: EngineState -> Set ByteString -> ByteString -> BSB.Builder -> BSB.Builder
expandIdentBlue st painted txt acc =
  let (ident, rest) = C.span isIdentChar txt
   in if S.member ident painted
        then -- Blue-painted: copy verbatim, don't expand
          goText st painted False False False rest (acc <> BSB.byteString ident)
        else case ident of
          "__LINE__" ->
            goText st painted False False False rest (acc <> BSB.string8 (show (stCurrentLine st)))
          "__FILE__" ->
            goText st painted False False False rest (acc <> BSB.string8 (show (stCurrentFile st)))
          _ ->
            case M.lookup ident (stMacros st) of
              Just (ObjectMacro replacement) ->
                let painted' = S.insert ident painted
                    replacement' = normalizeObjectReplacement replacement
                    expanded = builderToBytes (goText st painted' False False False replacement' mempty)
                 in goText st painted False False False rest (acc <> BSB.byteString expanded)
              Just (FunctionMacro params body) ->
                case parseCallArgs rest of
                  Nothing ->
                    goText st painted False False False rest (acc <> BSB.byteString ident)
                  Just (args, restAfter)
                    | length args == length params ->
                        let body' = substituteParamsBuilder (M.fromList (zip params args)) body
                            painted' = S.insert ident painted
                            expanded = builderToBytes (goText st painted' False False False body' mempty)
                         in goText st painted False False False restAfter (acc <> BSB.byteString expanded)
                    | otherwise ->
                        goText st painted False False False rest (acc <> BSB.byteString ident)
              Nothing ->
                goText st painted False False False rest (acc <> BSB.byteString ident)

-- | Normalize comments inside object-like macro replacement text while
-- preserving string and char literals. cpphs replaces @/* ... */@ with spaces
-- matching the width of the comment body, but treats empty @/**/@ as a token
-- pasting hack with zero width.
normalizeObjectReplacement :: ByteString -> ByteString
normalizeObjectReplacement = C.dropWhileEnd isSpaceChar . go False False False mempty
  where
    go :: Bool -> Bool -> Bool -> BSB.Builder -> ByteString -> ByteString
    go _ _ _ acc txt | C.null txt = builderToBytes acc
    go inString inChar escaped acc txt =
      case C.uncons txt of
        Nothing -> builderToBytes acc
        Just (c, rest)
          | inString ->
              let escaped' = c == '\\' && not escaped
                  inString' = not (c == '"' && not escaped)
               in go inString' False escaped' (acc <> BSB.char8 c) rest
          | inChar ->
              let escaped' = c == '\\' && not escaped
                  inChar' = not (c == '\'' && not escaped)
               in go False inChar' escaped' (acc <> BSB.char8 c) rest
          | c == '"' -> go True False False (acc <> BSB.char8 c) rest
          | c == '\'' -> go False True False (acc <> BSB.char8 c) rest
          | "/*" `C.isPrefixOf` txt ->
              let (commentText, remaining) = consumeCBlockComment txt
                  replacement = commentReplacement commentText
               in go False False False (acc <> BSB.byteString replacement) remaining
          | otherwise ->
              go False False False (acc <> BSB.char8 c) rest

consumeCBlockComment :: ByteString -> (ByteString, ByteString)
consumeCBlockComment txt =
  let afterOpen = C.drop 2 txt
      (inside, suffix) = BS.breakSubstring "*/" afterOpen
   in if C.null suffix
        then (txt, "")
        else ("/*" <> inside <> "*/", C.drop 2 suffix)

commentReplacement :: ByteString -> ByteString
commentReplacement commentText
  | commentText == "/**/" = ""
  | otherwise = C.replicate (charWidth (commentBody commentText)) ' '

-- | Number of characters in a UTF-8 buffer, for column alignment: count
-- every byte that is not a UTF-8 continuation byte. On valid UTF-8 this
-- is the character count; on anything else it degrades gracefully instead
-- of failing, and on ASCII it is just the length.
charWidth :: ByteString -> Int
charWidth = BS.foldl' step 0
  where
    step !n b = if b .&. 0xC0 == 0x80 then n else n + 1

commentBody :: ByteString -> ByteString
commentBody commentText =
  if "/*" `C.isPrefixOf` commentText && "*/" `C.isSuffixOf` commentText
    then C.take (C.length commentText - 4) (C.drop 2 commentText)
    else C.drop 2 commentText

-- | Parse function-like macro call arguments.
parseCallArgs :: ByteString -> Maybe ([ByteString], ByteString)
parseCallArgs input = do
  ('(', rest) <- C.uncons (C.dropWhile isSpaceChar input)
  parseArgs False False False 0 [] mempty rest

parseArgs :: Bool -> Bool -> Bool -> Int -> [ByteString] -> BSB.Builder -> ByteString -> Maybe ([ByteString], ByteString)
parseArgs inString inChar escaped depth argsRev current remaining =
  case C.uncons remaining of
    Nothing -> Nothing
    Just (ch, rest)
      | inString ->
          let escaped' = ch == '\\' && not escaped
              inString' = not (ch == '"' && not escaped)
           in parseArgs inString' False escaped' depth argsRev (current <> BSB.char8 ch) rest
      | inChar ->
          let escaped' = ch == '\\' && not escaped
              inChar' = not (ch == '\'' && not escaped)
           in parseArgs False inChar' escaped' depth argsRev (current <> BSB.char8 ch) rest
      | startsHsBlockComment remaining ->
          let (commentText, afterComment) = consumeHsBlockComment remaining
           in parseArgs False False False depth argsRev (current <> BSB.byteString commentText) afterComment
      | ch == '"' ->
          parseArgs True False False depth argsRev (current <> BSB.char8 ch) rest
      | ch == '\'' ->
          parseArgs False True False depth argsRev (current <> BSB.char8 ch) rest
      | ch == '(' ->
          parseArgs False False False (depth + 1) argsRev (current <> BSB.char8 ch) rest
      | ch == ')' && depth > 0 ->
          parseArgs False False False (depth - 1) argsRev (current <> BSB.char8 ch) rest
      | ch == ')' && depth == 0 ->
          let arg = trimSpacesBytes (builderToBytes current)
              argsRev' =
                if C.null arg && null argsRev
                  then [""]
                  else arg : argsRev
           in Just (reverse argsRev', rest)
      | ch == ',' && depth == 0 ->
          let arg = trimSpacesBytes (builderToBytes current)
           in parseArgs False False False depth (arg : argsRev) mempty rest
      | ch == '-' && depth == 0,
        Just ('-', afterDash) <- C.uncons rest ->
          -- Haskell line comment inside arg list: close the arg, find ')' in comment
          let commentText = "--" <> afterDash
           in case findLastCloseParen commentText of
                Nothing -> Nothing
                Just (commentPrefix, afterClose) ->
                  let currentText = builderToBytes current
                      arg = trimSpacesBytes currentText
                      trailingWS = C.takeWhileEnd isSpaceChar currentText
                      argsRev' = if C.null arg && null argsRev then [""] else arg : argsRev
                   in Just (reverse argsRev', trailingWS <> commentPrefix <> afterClose)
      | otherwise ->
          parseArgs False False False depth argsRev (current <> BSB.char8 ch) rest

-- | Find the last ')' in text and split before it.
findLastCloseParen :: ByteString -> Maybe (ByteString, ByteString)
findLastCloseParen txt =
  case C.elemIndexEnd ')' txt of
    Nothing -> Nothing
    Just idx -> Just (C.take idx txt, C.drop (idx + 1) txt)

startsHsBlockComment :: ByteString -> Bool
startsHsBlockComment txt =
  case C.uncons txt of
    Just ('{', rest) ->
      case C.uncons rest of
        Just ('-', rest') ->
          case C.uncons rest' of
            Just ('#', _) -> False
            _ -> True
        _ -> False
    _ -> False

consumeHsBlockComment :: ByteString -> (ByteString, ByteString)
consumeHsBlockComment = go 0 mempty
  where
    go :: Int -> BSB.Builder -> ByteString -> (ByteString, ByteString)
    go depth acc txt =
      case C.uncons txt of
        Nothing -> (builderToBytes acc, "")
        Just (c, rest) ->
          case C.uncons rest of
            Just ('-', rest')
              | c == '{' ->
                  go (depth + 1) (acc <> BSB.byteString "{-") rest'
            Just ('}', rest')
              | c == '-' && depth <= 1 ->
                  (builderToBytes (acc <> BSB.byteString "-}"), rest')
            Just ('}', rest')
              | c == '-' ->
                  go (depth - 1) (acc <> BSB.byteString "-}") rest'
            _ ->
              go depth (acc <> BSB.char8 c) rest

data Piece
  = PieceWhitespace !ByteString
  | PiecePaste
  | PieceRaw !ByteString
  | PieceParam !ByteString

substituteParams :: Map ByteString ByteString -> ByteString -> ByteString
substituteParams = substituteParamsBuilder

-- | Builder-based parameter substitution. Replaces identifiers found
-- in the substitution map, respecting string and char literals.
substituteParamsBuilder :: Map ByteString ByteString -> ByteString -> ByteString
substituteParamsBuilder subs = renderPieces . collapseTokenPastes . collapseStringizing . tokenizeReplacementList
  where
    tokenizeReplacementList :: ByteString -> [Piece]
    tokenizeReplacementList txt =
      case C.uncons txt of
        Nothing -> []
        Just (c, rest)
          | isSpaceChar c ->
              let (spaces, remaining) = C.span isSpaceChar txt
               in PieceWhitespace spaces : tokenizeReplacementList remaining
          | c == '"' ->
              let (literal, remaining) = scanQuoted '"' txt
               in PieceRaw literal : tokenizeReplacementList remaining
          | c == '\'' ->
              let (literal, remaining) = scanQuoted '\'' txt
               in PieceRaw literal : tokenizeReplacementList remaining
          | "/*" `C.isPrefixOf` txt ->
              let (commentText, remaining) = consumeCBlockComment txt
                  piece = if commentText == "/**/" then PiecePaste else PieceWhitespace (commentReplacement commentText)
               in piece : tokenizeReplacementList remaining
          | "##" `C.isPrefixOf` txt ->
              PiecePaste : tokenizeReplacementList (C.drop 2 txt)
          | isIdentStart c ->
              let (ident, remaining) = C.span isIdentChar txt
                  piece = if M.member ident subs then PieceParam ident else PieceRaw ident
               in piece : tokenizeReplacementList remaining
          | otherwise ->
              PieceRaw (C.singleton c) : tokenizeReplacementList rest

    scanQuoted :: Char -> ByteString -> (ByteString, ByteString)
    scanQuoted quote = go False mempty
      where
        go escaped acc remaining =
          case C.uncons remaining of
            Nothing -> (builderToBytes acc, "")
            Just (c, rest)
              | c == quote && not escaped ->
                  (builderToBytes (acc <> BSB.char8 c), rest)
              | c == '\\' ->
                  go (not escaped) (acc <> BSB.char8 c) rest
              | otherwise ->
                  go False (acc <> BSB.char8 c) rest

    collapseStringizing :: [Piece] -> [Piece]
    collapseStringizing [] = []
    collapseStringizing (PieceRaw "#" : PieceParam name : rest) =
      PieceRaw (stringizeArgument (lookupParam name)) : collapseStringizing rest
    collapseStringizing (PieceRaw "#" : rest) =
      PieceRaw "#" : collapseStringizing rest
    collapseStringizing (piece : rest) = piece : collapseStringizing rest

    collapseTokenPastes :: [Piece] -> [Piece]
    collapseTokenPastes = go []
      where
        go acc [] = acc
        go acc (piece : rest) =
          case piece of
            PiecePaste ->
              let (accNoSpace, _) = trimTrailingWhitespace acc
                  (leadingSpace, restAfterSpace) = span isWhitespacePiece rest
               in case (unsnoc accNoSpace, restAfterSpace) of
                    (Just (accInit, leftPiece), rightPiece : remaining) ->
                      go (accInit <> [PieceRaw (renderPiece leftPiece <> renderPiece rightPiece)]) remaining
                    _ -> go (acc <> [PieceRaw "##"] <> leadingSpace) restAfterSpace
            _ -> go (acc <> [piece]) rest

    trimTrailingWhitespace :: [Piece] -> ([Piece], [Piece])
    trimTrailingWhitespace pieces =
      let (trailingRev, restRev) = span isWhitespacePiece (reverse pieces)
       in (reverse restRev, reverse trailingRev)

    unsnoc :: [a] -> Maybe ([a], a)
    unsnoc [] = Nothing
    unsnoc [x] = Just ([], x)
    unsnoc (x : xs) = do
      (init', last') <- unsnoc xs
      pure (x : init', last')

    isWhitespacePiece :: Piece -> Bool
    isWhitespacePiece (PieceWhitespace _) = True
    isWhitespacePiece _ = False

    lookupParam :: ByteString -> ByteString
    lookupParam name = M.findWithDefault name name subs

    renderPieces :: [Piece] -> ByteString
    renderPieces = C.concat . map renderPiece

    renderPiece :: Piece -> ByteString
    renderPiece piece =
      case piece of
        PieceWhitespace txt -> txt
        PiecePaste -> "##"
        PieceRaw txt -> txt
        PieceParam name -> lookupParam name

    stringizeArgument :: ByteString -> ByteString
    stringizeArgument arg =
      let normalized = normalizeWhitespace arg
          escaped = C.concatMap escapeStringChar normalized
       in C.cons '"' (C.snoc escaped '"')

    -- Not 'C.words'/'C.unwords': those treat byte 0xA0 as whitespace and
    -- would split a multi-byte character down the middle.
    normalizeWhitespace :: ByteString -> ByteString
    normalizeWhitespace =
      C.intercalate " " . filter (not . C.null) . C.splitWith isSpaceChar

    escapeStringChar :: Char -> ByteString
    escapeStringChar '"' = "\\\""
    escapeStringChar '\\' = "\\\\"
    escapeStringChar c = C.singleton c

evalCondition :: EngineState -> ByteString -> Bool
evalCondition st expr = eval expr /= 0
  where
    macros = stMacros st
    eval = evalNumeric . replaceRemainingWithZero . expandMacros st . replaceDefined macros

evalNumeric :: ByteString -> Integer
evalNumeric input =
  let tokens = tokenize input
   in case parseExpr tokens of
        (val, _) -> val

data Token = TOp ByteString | TNum Integer | TIdent ByteString | TOpenParen | TCloseParen deriving (Show)

tokenize :: ByteString -> [Token]
tokenize input =
  case C.uncons input of
    Nothing -> []
    Just (c, rest)
      | isSpaceChar c ->
          tokenize (C.dropWhile isSpaceChar rest)
      | isDigit c ->
          let (num, remaining) = C.span isDigit input
           in case C.readInteger num of
                Just (value, _) -> TNum value : tokenize remaining
                Nothing -> tokenize remaining
      | isIdentStart c ->
          let (ident, remaining) = C.span isIdentChar input
           in TIdent ident : tokenize remaining
      | c == '(' ->
          TOpenParen : tokenize rest
      | c == ')' ->
          TCloseParen : tokenize rest
      | otherwise ->
          let (op, remaining) = C.span isOpChar input
           in if C.null op
                then tokenize rest
                else TOp op : tokenize remaining

parseExpr :: [Token] -> (Integer, [Token])
parseExpr = parseOr

binary :: ([Token] -> (Integer, [Token])) -> [ByteString] -> [Token] -> (Integer, [Token])
binary next ops ts =
  let (v1, ts1) = next ts
   in go v1 ts1
  where
    go v1 (TOp op : ts2)
      | op `elem` ops =
          let (v2, ts3) = next ts2
           in go (apply op v1 v2) ts3
    go v1 ts2 = (v1, ts2)

    apply "||" a b = if a /= 0 || b /= 0 then 1 else 0
    apply "&&" a b = if a /= 0 && b /= 0 then 1 else 0
    apply "==" a b = if a == b then 1 else 0
    apply "!=" a b = if a /= b then 1 else 0
    apply "<" a b = if a < b then 1 else 0
    apply ">" a b = if a > b then 1 else 0
    apply "<=" a b = if a <= b then 1 else 0
    apply ">=" a b = if a >= b then 1 else 0
    apply "+" a b = a + b
    apply "-" a b = a - b
    apply "*" a b = a * b
    apply "/" a b = if b == 0 then 0 else a `div` b
    apply "%" a b = if b == 0 then 0 else a `mod` b
    apply _ a _ = a

parseOr, parseAnd, parseEq, parseRel, parseAdd, parseMul :: [Token] -> (Integer, [Token])
parseOr = binary parseAnd ["||"]
parseAnd = binary parseEq ["&&"]
parseEq = binary parseRel ["==", "!="]
parseRel = binary parseAdd ["<", ">", "<=", ">="]
parseAdd = binary parseMul ["+", "-"]
parseMul = binary parseUnary ["*", "/", "%"]

parseUnary :: [Token] -> (Integer, [Token])
parseUnary (TOp "!" : ts) = let (v, ts') = parseUnary ts in (if v == 0 then 1 else 0, ts')
parseUnary (TOp "-" : ts) = let (v, ts') = parseUnary ts in (-v, ts')
parseUnary ts = parseAtom ts

parseAtom :: [Token] -> (Integer, [Token])
parseAtom (TNum n : ts) = (n, ts)
parseAtom (TIdent _ : ts) = (0, ts)
parseAtom (TOpenParen : ts) =
  let (v, ts1) = parseExpr ts
   in case ts1 of
        TCloseParen : ts2 -> (v, ts2)
        _ -> (v, ts1)
parseAtom ts = (0, ts)

replaceDefined :: Map ByteString MacroDef -> ByteString -> ByteString
replaceDefined macros = go
  where
    go txt =
      case C.uncons txt of
        Nothing -> ""
        Just (c, rest)
          | "defined" `C.isPrefixOf` txt && not (nextCharIsIdent (C.drop 7 txt)) ->
              expandDefined (C.dropWhile isSpaceChar (C.drop 7 txt))
          | otherwise ->
              C.cons c (go rest)

    expandDefined rest =
      case C.uncons rest of
        Just ('(', restAfterOpen) ->
          let rest' = C.dropWhile isSpaceChar restAfterOpen
              (name, restAfterName0) = C.span isIdentChar rest'
              restAfterName = C.dropWhile isSpaceChar restAfterName0
           in case C.uncons restAfterName of
                Just (')', restAfterClose) ->
                  boolLiteral (M.member name macros) <> go restAfterClose
                _ ->
                  boolLiteral False <> go restAfterName
        _ ->
          let (name, restAfterName) = C.span isIdentChar rest
           in if C.null name
                then boolLiteral False <> go rest
                else boolLiteral (M.member name macros) <> go restAfterName

    boolLiteral True = " 1 "
    boolLiteral False = " 0 "

    nextCharIsIdent remaining =
      case C.uncons remaining of
        Just (c, _) -> isIdentChar c
        Nothing -> False

replaceRemainingWithZero :: ByteString -> ByteString
replaceRemainingWithZero = go
  where
    go txt =
      case C.uncons txt of
        Nothing -> ""
        Just (c, rest)
          | isIdentStart c ->
              let (_, remaining) = C.span isIdentChar txt
               in " 0 " <> go remaining
          | otherwise ->
              C.cons c (go rest)

builderToBytes :: BSB.Builder -> ByteString
builderToBytes = BSL.toStrict . BSB.toLazyByteString

trimSpacesBytes :: ByteString -> ByteString
trimSpacesBytes = C.dropWhileEnd isSpaceChar . C.dropWhile isSpaceChar
