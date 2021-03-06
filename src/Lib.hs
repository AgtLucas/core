module Lib
  ( printWasm
  , printExpression
  , printModule
  , parseExpressionFromString
  , Expression(..)
  , OperatorExpr(..)
  ) where

import Data.Char
import Data.Functor.Identity
import Data.List (intercalate)
import Data.Text (Text)
import Debug.Trace

import Text.Megaparsec
import Text.Megaparsec.Expr

type Parser = Parsec Dec String
type ParseError' = ParseError Char Dec

data OperatorExpr
  = Add
  | Subtract
  | Divide
  | Multiply
  deriving (Show, Eq)

type Ident = String

ident :: String -> Ident
ident s = s

data Expression
  = Identifier Ident
  | Number Int
  | Assignment Ident
               [Ident]
               Expression
  | Infix OperatorExpr
          Expression
          Expression
  | Call Ident
         [Expression]
  | Case Expression
         [(Expression, Expression)]
  | BetweenParens Expression
  deriving (Show, Eq)

parseDigit   :: Parser Expression
parseDigit = do
  value <- some digitChar
  return $ Number (read value)

parseOperator  :: Parser OperatorExpr
parseOperator = do
  char <- oneOf "+-*/"
  return $
    case char of
      '+' -> Add
      '-' -> Subtract
      '*' -> Multiply
      '/' -> Divide

parseInfix :: Parser Expression
parseInfix = do
  a <- parseDigit <|> parseIdentifier
  space
  operator <- parseOperator
  space
  b <- parseExpression
  return $ Infix operator a b

parseDeclaration :: Parser Expression
parseDeclaration = do
  name <- many letterChar
  space
  arguments <- many parseArgument
  char '='
  space
  value <- parseExpression
  return $ Assignment (ident name) arguments value
  where
    parseArgument = do
      name <- some letterChar
      space
      return (ident name)


parseCall  :: Parser Expression
parseCall = do
  name <- parseIdent
  space
  arguments <- some parseArgument
  return $ Call name arguments
  where
    parseArgument = do
      argument <- parseExpression
      space
      return argument

parseBetweenParens :: Parser Expression
parseBetweenParens = do
  char '('
  expr <- parseExpression
  char ')'
  return $ BetweenParens expr

parseExpression  :: Parser Expression
parseExpression =
  parseBetweenParens <|> try parseCase <|> try parseInfix <|> parseDigit <|>
  try parseDeclaration <|>
  try parseCall <|>
  parseIdentifier

parseCase :: Parser Expression
parseCase = do
  space
  string "case"
  space
  expr <- parseIdentifier
  space
  string "of"
  space
  patterns <- some parsePattern
  return $ Case expr patterns
  where
    parsePattern = do
      pattern' <- parseDigit <|> parseIdentifier
      space
      string "->"
      space
      expr <- parseExpression
      space
      return (pattern', expr)

parseIdentifier :: Parser Expression
parseIdentifier = do
  name <- parseIdent
  return $ Identifier name

parseIdent  :: Parser Ident
parseIdent = do
  name <- some letterChar
  return (ident name)

parseString :: Parser [Expression]
parseString = do
  expr <- some parseExpression
  space
  eof
  return expr

parseExpressionFromString = parse parseString ""

operatorToString :: OperatorExpr -> String
operatorToString op =
  case op of
    Add -> "+"
    Subtract -> "-"
    Multiply -> "*"
    Divide -> "/"

printModule :: [Expression] -> String
printModule expressions = intercalate "\n\n" $ map printExpression expressions

printExpression :: Expression -> String
printExpression expr =
  case expr of
    Number n -> show n
    Infix op expr expr2 ->
      unwords [printExpression expr, operatorToString op, printExpression expr2]
    Assignment name args expr ->
      name ++ " " ++ unwords args ++ " = \n" ++ indent (printExpression expr) 2
    Identifier name -> name
    Call name args -> name ++ " " ++ unwords (printExpression <$> args)
    Case caseExpr patterns ->
      "case " ++
      printExpression caseExpr ++ " of\n" ++ indent (printPatterns patterns) 2
    BetweenParens expr -> "(" ++ printExpression expr ++ ")"
  where
    printPatterns patterns = unlines $ map printPattern patterns
    printPattern (patternExpr, resultExpr) =
      printExpression patternExpr ++ " -> " ++ printExpression resultExpr

indent :: String -> Int -> String
indent str level =
  intercalate "\n" $ map (\line -> replicate level ' ' ++ line) (lines str)

printWasm :: [Expression] -> String
printWasm expr =
  "(module\n" ++ indent (intercalate "\n" $ map printWasmExpr expr) 2 ++ "\n)"
  where
    printWasmExpr expr =
      case expr of
        Number n -> "(i32.const " ++ show n ++ ")"
        Assignment name args expr ->
          "(export \"" ++
          name ++
          "\" (func $" ++
          name ++
          "))\n(func $" ++
          name ++
          " " ++
          paramsString args ++
          " " ++
          "(result i32)\n" ++
          indent ("(return \n" ++ indent (printWasmExpr expr) 2 ++ "\n)") 2 ++
          "\n)"
        Infix op expr expr2 ->
          "(" ++
          opString op ++
          "\n" ++
          indent (printWasmExpr expr ++ "\n" ++ printWasmExpr expr2) 2 ++ "\n)"
        Identifier name -> "(get_local $" ++ name ++ ")"
        Call name args ->
          "(call $" ++
          name ++ "\n" ++ indent (unlines (printWasmExpr <$> args)) 2 ++ "\n)"
        Case caseExpr patterns -> printCase caseExpr patterns
        BetweenParens expr -> printWasmExpr expr
      where
        printCase caseExpr patterns =
          "(if (result i32)\n" ++
          indent (printPatterns caseExpr patterns) 2 ++ "\n)"
        combinePatterns acc val = acc ++ "\n" ++ printPattern val
        printPattern (patternExpr, branchExpr) = printWasmExpr branchExpr
        firstCase patterns = fst (head patterns)
        printPatterns caseExpr patterns =
          intercalate "\n" $
          case length patterns of
            1 ->
              [ printComparator caseExpr (fst $ head patterns)
              , "(then \n" ++ indent (printPattern (head patterns)) 2 ++ "\n)"
              ]
            n ->
              [ printComparator caseExpr (fst $ head patterns)
              , "(then \n" ++ indent (printPattern (head patterns)) 2 ++ "\n)"
              , "(else \n" ++
                indent (printCase caseExpr (tail patterns)) 2 ++ "\n)"
              ]
        printComparator a b =
          intercalate
            "\n"
            [ "(i32.eq"
            , indent (printWasmExpr a) 2
            , indent (printWasmExpr b) 2
            , ")"
            ]
    paramsString args = unwords (paramString <$> args)
    paramString arg = "(param $" ++ arg ++ " i32)"
    opString op =
      case op of
        Add -> "i32.add"
        Subtract -> "i32.sub"
        Multiply -> "i32.mul"
        Divide -> "i32.div_s"
