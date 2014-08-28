import Prelude hiding (break)

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Cont
import Data.Bits
import Data.Complex
import Data.Fixed
import Data.IORef
import Data.List hiding (break)
import Data.Map (Map)
import qualified Data.Map as Map
import Debug.Trace
import System.Environment
import Text.Printf

import Language
import Parser

type Evaluator = ContT () (ReaderT FlowControl (StateT Environment IO))
type EvaluatorCont = () -> Evaluator ()
type EvaluatorReturnCont = Value -> Evaluator ()
type SymbolTable = Map String Value

data FlowControl = FlowControl {
    loopBreak :: EvaluatorCont,
    loopContinue :: EvaluatorCont
}

data Environment = Environment {
    scopes :: [SymbolTable],
    fnReturn :: EvaluatorReturnCont
}

unimplemented :: Statement -> Evaluator ()
unimplemented s = fail $ printf "Unimplemented: %s" (show s)

defaultEnv :: Environment
defaultEnv = do
    let builtins = []
    let globals = Map.fromList builtins
    Environment {scopes = [globals], fnReturn = error "Must be in function!"}

currentScope :: Evaluator SymbolTable
currentScope = do
    env <- get
    return $ head $ scopes env

getAttr :: String -> Value -> Evaluator (Maybe Value)
getAttr attr (Object _ ref) = do
    dict <- liftIO $ readIORef ref
    return $ Map.lookup attr dict
getAttr attr (Class _ ref) = do
    dict <- liftIO $ readIORef ref
    return $ Map.lookup attr dict
getAttr _ _ = fail "Only classes and objects have attrs!"

getClassAttr :: String -> Value -> Evaluator (Maybe Value)
getClassAttr attr (Object cls _) = getAttr attr cls
getClassAttr _ _ = fail "Only objects have class attrs!"

setAttr :: String -> Value -> Value -> Evaluator ()
setAttr attr value (Object _ ref)   = liftIO $ modifyIORef ref (Map.insert attr value)
setAttr attr value (Class _ ref)    = liftIO $ modifyIORef ref (Map.insert attr value)
setAttr _ _ _                       = fail "Only objects have attrs!"

lookupSymbol :: String -> Evaluator Value
lookupSymbol name = do
    scope <- currentScope
    case Map.lookup name scope of
        Nothing -> fail $ "Unknown symbol: " ++ name
        Just v  -> return v

updateSymbol :: String -> Value -> Evaluator ()
updateSymbol name value = do
    scope <- currentScope

    let updatedScope = Map.insert name value scope
    modify $ \env -> env { scopes = updatedScope : tail (scopes env) }

eval :: Statement -> Evaluator ()
eval (Def name params body) = updateSymbol name function
  where
    function = Function name params body

eval (ModuleDef statements) = evalBlock statements

eval (ClassDef name _ statements) = do
    pushScope
    evalBlock statements
    dict <- popScope

    updateSymbol name $ Class name dict

  where
    pushScope = do
        let dict = Map.empty
        modify $ \env -> env { scopes = dict : scopes env }

    popScope = do
        env <- get
        let dict = head $ scopes env
        put env { scopes = tail $ scopes env }
        liftIO $ newIORef dict

eval (Assignment (Name var) expr) = do
    value <- evalExpr expr
    updateSymbol var value

eval (Assignment (Attribute var attr) expr) = do
    value <- evalExpr expr
    target <- evalExpr var
    setAttr attr value target

eval (Assignment{}) = fail "Syntax error!"

eval (Break) = do
    flow <- ask
    loopBreak flow ()

eval (Continue) = do
    flow <- ask
    loopContinue flow ()

eval (If clauses elseBlock) = evalClauses clauses
  where
    evalClauses [] = evalBlock elseBlock
    evalClauses (IfClause condition block : rest) = do
        result <- evalExpr condition
        if isTruthy result
            then evalBlock block
            else evalClauses rest

eval (Return expression) = do
    value <- evalExpr expression

    env <- get
    fnReturn env value

eval (While condition block elseBlock) = callCC $ \break ->
        fix $ \loop -> do
            callCC $ \continue ->
                local (\f -> f{ loopBreak = break, loopContinue = continue }) $ do
                    result <- evalExpr condition
                    unless (isTruthy result) $ do
                        evalBlock elseBlock
                        break ()
                    evalBlock block
            loop

eval (Pass) = return ()

eval (Assert e _) = do
    result <- evalExpr e
    unless (isTruthy result) (fail "Assertion failed!")

eval s@(Del {}) = unimplemented s

eval (Expression e) = do
    _ <- evalExpr e
    return ()

evalExpr :: Expression -> Evaluator Value
evalExpr (UnaryOp Not (Constant (Bool v))) =
    return $ Bool (not v)

evalExpr (UnaryOp Pos (Constant v@(Int {}))) =
    return v

evalExpr (UnaryOp Pos (Constant v@(Float {}))) =
    return v

evalExpr (UnaryOp Neg (Constant (Int v))) =
    return $ Int (- v)

evalExpr (UnaryOp Neg (Constant (Float v))) =
    return $ Float (- v)

evalExpr (UnaryOp Complement (Constant (Int v))) =
    return $ Int (complement v)

evalExpr (UnaryOp op (Constant r)) =
    fail $ printf "Unsupported operand type for %s: %s" (show op) (toString r)

evalExpr (UnaryOp op expr) = do
    r <- evalExpr expr
    evalExpr $ UnaryOp op (Constant r)

evalExpr (BinOp (ArithOp op) (Constant (Int l)) (Constant (Int r)))
    | op == Add = return $ Int (l + r)
    | op == Sub = return $ Int (l - r)
    | op == Mul = return $ Int (l * r)
    | op == Div = return $ Float (fromInteger l / fromInteger r)
    | op == Mod = return $ Int (l `mod` r)
    | op == FDiv = return $ Int (floorInt (fromIntegral l / fromIntegral r))
    | op == Pow = return $ Int (l ^ r)
  where
    floorInt = floor :: Double -> Integer

evalExpr (BinOp (BitOp BitAnd) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (l .&. r)

evalExpr (BinOp (BitOp BitOr) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (l .|. r)

evalExpr (BinOp (BitOp BitXor) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (xor l r)

evalExpr (BinOp (BitOp LShift) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (shiftL l (fromIntegral r))

evalExpr (BinOp (BitOp RShift) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (shiftR l (fromIntegral r))

evalExpr (BinOp (ArithOp op) (Constant (Float l)) (Constant (Float r)))
    | op == Add = return $ Float (l + r)
    | op == Sub = return $ Float (l - r)
    | op == Mul = return $ Float (l * r)
    | op == Div = return $ Float (l / r)
    | op == Mod = return $ Float (l `mod'` r)
    | op == FDiv = return $ Float (fromInteger (floor (l / r)))
    | op == Pow = return $ Float (l ** r)

-- Promote ints to floats in binary operators
evalExpr (BinOp op (Constant (Int l)) (Constant (Float r))) =
    evalExpr $ BinOp op (Constant (Float (fromIntegral l))) (Constant (Float r))

evalExpr (BinOp op (Constant (Float l)) (Constant (Int r))) =
    evalExpr $ BinOp op (Constant (Float l)) (Constant (Float (fromIntegral r)))

-- String + String
evalExpr (BinOp (ArithOp Add) (Constant (String l)) (Constant (String r))) =
    return $ String (l ++ r)

-- Int * String
evalExpr (BinOp (ArithOp Mul) (Constant (Int l)) (Constant (String r))) =
    return $ String (concat $ replicate (fromInteger l) r)

-- String * Int
evalExpr (BinOp (ArithOp Mul) (Constant (String l)) (Constant (Int r))) =
    return $ String (concat $ replicate (fromInteger r) l)

-- Int [=|!=|<|<=|>|>=] Int
evalExpr (BinOp (CompOp op) (Constant (Int l)) (Constant (Int r))) =
    return $ Bool (fn op l r)
  where
    fn Eq               = (==)
    fn NotEq            = (/=)
    fn LessThan         = (<)
    fn LessThanEq       = (<=)
    fn GreaterThan      = (>)
    fn GreaterThanEq    = (>=)

evalExpr (BinOp (CompOp op) (Constant (Float l)) (Constant (Float r))) =
    return $ Bool (fn op l r)
  where
    fn Eq               = (==)
    fn NotEq            = (/=)
    fn LessThan         = (<)
    fn LessThanEq       = (<=)
    fn GreaterThan      = (>)
    fn GreaterThanEq    = (>=)

evalExpr (BinOp (CompOp Eq) (Constant l) (Constant r)) =
    return $ Bool (l == r)

evalExpr (BinOp (CompOp NotEq) (Constant l) (Constant r)) =
    return $ Bool (l /= r)

evalExpr (BinOp op (Constant l) (Constant r)) =
    fail $ printf "Unsupported operand type(s) for %s: %s %s" (show op) (toString l) (toString r)

evalExpr (BinOp op l r) = do
    left <- evalExpr l
    right <- evalExpr r
    evalExpr $ BinOp op (Constant left) (Constant right)

evalExpr (Call (Name "print") args) = do
    arg <- liftM toString (evalExpr (head args))
    liftIO $ putStrLn arg
    return None

evalExpr (Call (Attribute obj name) args) = do
    receiver <- evalExpr obj
    evalArgs <- mapM evalExpr args
    method <- getClassAttr name receiver

    case method of
        Just f  -> evalCall f (receiver: evalArgs)
        Nothing -> fail $ "Unknown method: " ++ name

evalExpr (Call e args) = do
    f <- evalExpr e
    evalArgs <- mapM evalExpr args
    evalCall f evalArgs

evalExpr (Attribute target name) = do
    receiver <- evalExpr target
    attribute <- getAttr name receiver
    case attribute of
        Just v  -> return v
        Nothing -> fail $ "No attribute " ++ name

evalExpr (TernOp condExpr thenExpr elseExpr) = do
    condition <- evalExpr condExpr
    evalExpr $ if isTruthy condition
        then thenExpr
        else elseExpr

evalExpr (TupleDef exprs) = do
    values <- mapM evalExpr exprs
    return $ Tuple values

evalExpr (Name var) = lookupSymbol var
evalExpr (Constant c) = return c

evalBlock :: [Statement] -> Evaluator ()
evalBlock = mapM_ traceEval
  where
    traceEval :: Statement -> Evaluator ()
    traceEval s = do
        tracing <- liftIO $ lookupEnv "TRACE"

        case tracing of
            Just _  -> (trace $ traceStmt s) eval s
            Nothing -> eval s

    traceStmt s = "*** Evaluating: " ++ show s

evalCall :: Value -> [Value] -> Evaluator Value
evalCall cls@(Class {}) args = do
    dict <- liftIO $ newIORef (Map.fromList [("__class__", cls)])
    let obj = Object cls dict
    ctor <- getAttr "__init__" cls

    _ <- case ctor of
        Just f  -> evalCall f (obj : args)
        Nothing -> return None

    return obj

evalCall (Function _ params body) args = do
    env <- get

    let previousReturnCont = fnReturn env
    let previousScopes = scopes env
    let scope = Map.union (Map.fromList $ zip params args) (last $ scopes env)

    result <- callCC $ \returnCont -> do
        put env { fnReturn = returnCont, scopes = scope : previousScopes }
        evalBlock body
        return None

    modify $ \e -> e{ fnReturn = previousReturnCont, scopes = previousScopes }

    return result

evalCall v _ = fail $ "Unable to call " ++ toString v

isTruthy :: Value -> Bool
isTruthy (Int 0) = False
isTruthy (Bool False) = False
isTruthy (None) = False
isTruthy _ = True

toString :: Value -> String
toString (None) = "None"
toString (Bool v) = show v
toString (String v) = v
toString (Int v) = show v
toString (Float v) = show v
toString (Imaginary v)
    | realPart v == 0   = show (imagPart v) ++ "j"
    | otherwise         = show v
toString (Function name _ _) = printf "<%s>" name
toString (Class name _) = printf "<class '__main__.%s'>" name
toString (Object (Class name _) _) = printf "<%s object>" name
toString (Object _ _) = fail "Object must be associated with a class!"
toString (Tuple values) =
    printf "(%s%s)" (intercalate ", " stringValues) trailer
  where
    stringValues = map toString values
    trailer = case values of
        [_]   -> ","
        _     -> ""


parseEval :: String -> String -> Evaluator ()
parseEval _ code = do
    let statements = parse code
    eval statements

defaultFlowControl :: FlowControl
defaultFlowControl = FlowControl {
    loopBreak = error "Must be in loop",
    loopContinue = error "Must be in loop"
}

main :: IO ()
main = do
    [filename] <- getArgs
    code <- readFile filename

    _ <- runStateT (runReaderT (runContT (parseEval filename code) return) defaultFlowControl) defaultEnv
    return ()
