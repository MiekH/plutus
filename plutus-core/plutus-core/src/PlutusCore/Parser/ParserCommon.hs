{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -Wno-deferred-out-of-scope-variables #-}

-- | Common functions for parsers of UPLC, PLC, and PIR.

module PlutusCore.Parser.ParserCommon where

import Data.Char (isAlphaNum)
import Data.Map qualified as M
import Data.Text qualified as T
import PlutusCore qualified as PLC
import PlutusPrelude
import Text.Megaparsec hiding (ParseError, State, parse)
import Text.Megaparsec.Char (char, letterChar, space1, string)
import Text.Megaparsec.Char.Lexer qualified as Lex

import Control.Monad.State (MonadState (get, put), StateT, evalStateT)

import Universe.Core (someValue)

newtype ParserState = ParserState { identifiers :: M.Map T.Text PLC.Unique }
    deriving (Show)

type Parser =
    ParsecT PLC.ParseError T.Text (StateT ParserState PLC.Quote)

instance (Stream s, PLC.MonadQuote m) => PLC.MonadQuote (ParsecT e s m)
instance (Ord ann, Pretty ann) => ShowErrorComponent (PLC.ParseError ann) where
    showErrorComponent err = show $ pretty err

initial :: ParserState
initial = ParserState M.empty

-- | Return the unique identifier of a name.
-- If it's not in the current parser state, map the name to a fresh id
-- and add it to the state. Used in the Name parser.
intern :: (MonadState ParserState m, PLC.MonadQuote m)
    => T.Text -> m PLC.Unique
intern n = do
    st <- get
    case M.lookup n (identifiers st) of
        Just u -> return u
        Nothing -> do
            fresh <- PLC.freshUnique
            let identifiers' = M.insert n fresh $ identifiers st
            put $ ParserState identifiers'
            return fresh

parse :: Parser a -> String -> T.Text -> Either (ParseErrorBundle T.Text PLC.ParseError) a
parse p file str = PLC.runQuote $ parseQuoted p file str

parseQuoted :: Parser a -> String -> T.Text -> PLC.Quote
                   (Either (ParseErrorBundle T.Text PLC.ParseError) a)
parseQuoted p file str = flip evalStateT initial $ runParserT p file str

-- | Space consumer.
whitespace :: Parser ()
whitespace = Lex.space space1 (Lex.skipLineComment "--") (Lex.skipBlockCommentNested "{-" "-}")

lexeme :: Parser a -> Parser a
lexeme = Lex.lexeme whitespace

symbol :: T.Text -> Parser T.Text
symbol = Lex.symbol whitespace

lparen :: Parser T.Text
lparen = symbol "("
rparen :: Parser T.Text
rparen = symbol ")"

lbracket :: Parser T.Text
lbracket = symbol "["
rbracket :: Parser T.Text
rbracket = symbol "]"

lbrace :: Parser T.Text
lbrace = symbol "{"
rbrace :: Parser T.Text
rbrace = symbol "}"

inParens :: Parser a -> Parser a
inParens = between lparen rparen

inBrackets :: Parser a -> Parser a
inBrackets = between lbracket rbracket

inBraces :: Parser a-> Parser a
inBraces = between lbrace rbrace

isIdentifierChar :: Char -> Bool
isIdentifierChar c = isAlphaNum c || c == '_' || c == '\''

-- | Create a parser that matches the input word and returns its source position.
-- This is for attaching source positions to parsed terms/programs.
-- getSourcePos is not cheap, don't call it on matching of every token.
wordPos ::
    -- | The word to match
    T.Text -> Parser SourcePos
wordPos w = lexeme $ try $ getSourcePos <* symbol w

builtinFunction :: Parser PLC.DefaultFun
builtinFunction = lexeme $ choice $ map parseBuiltin [minBound .. maxBound]
    where parseBuiltin builtin = try $ string (display builtin) >> pure builtin

version :: Parser (PLC.Version SourcePos)
version = lexeme $ do
    p <- getSourcePos
    x <- Lex.decimal
    void $ char '.'
    y <- Lex.decimal
    void $ char '.'
    PLC.Version p x y <$> Lex.decimal

name :: Parser PLC.Name
name = lexeme $ try $ do
    void $ lookAhead letterChar
    str <- takeWhileP (Just "identifier") isIdentifierChar
    PLC.Name str <$> intern str

tyName :: Parser PLC.TyName
tyName = PLC.TyName <$> name

-- | Turn a parser that can succeed without consuming any input into one that fails in this case.
enforce :: Parser a -> Parser a
enforce p = do
    (input, x) <- match p
    guard . not $ T.null input
    pure x

-- | Parser for integer constants.
conInt :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
conInt = lexeme Lex.decimal

-- | Parser for single quoted char.
conChar :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
conChar = do
    con <- between (char '\'') (char '\'') Lex.charLiteral
    pure $ someValue con

-- | Parser for double quoted string.
conText :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
conText = do
    con <- char '\"' *> manyTill Lex.charLiteral (char '\"')
    pure $ someValue $ pack con

-- | Parser for unit.
conUnit :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
conUnit = someValue () <$ symbol "unit"

-- | Parser for bool.
conBool :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
conBool = choose
    [ someValue True <$ symbol "True"
    , someValue False <$ symbol "False"
    ]

--TODO
-- conPair :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
-- conPair = someValue (,) <$ symbol "pair"

-- conList :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
-- conList = someValue [] <$ symbol "list"

constant :: Parser (PLC.Some (PLC.ValueOf PLC.DefaultUni))
constant = choose
    [ inParens constant
    , conInt
    , conChar
    , conText
    , conUnit
    , conBool]

constantTerm :: Parser (PLC.Term PLC.TyName PLC.Name PLC.DefaultUni PLC.DefaultFun SourcePos)
constantTerm = do
    p <- getSourcePos
    con <- constant
    pure $ Constant p con
