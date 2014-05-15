{-# LANGUAGE TupleSections #-}
module PiCalculus where

import Control.Arrow (second)
import Control.Concurrent (forkIO, myThreadId, threadDelay)
import qualified Control.Concurrent.Chan as Chans
import Control.Monad (liftM, liftM2, unless)
import Control.Monad.Error (throwError)
import Control.Monad.Trans (liftIO)
import Control.Monad.Trans.Except (ExceptT(..), catchE, runExceptT, throwE)
import Data.IORef (IORef, newIORef, readIORef,writeIORef)
import Data.List (intercalate)
import Data.Maybe (isJust)
import System.Environment (getArgs, getProgName)
import System.IO (Handle, hFlush, hGetLine, hPrint, stderr, stdin, stdout)
import Text.ParserCombinators.Parsec

import Data.Map (Map)
import qualified Data.Map as Map

data PiProcess = Null
               | In   Term Term
               | Out  Term Term
               | New  Term
               | PiProcess `Seq`   PiProcess -- Sequential Composition
               | PiProcess `Conc`  PiProcess -- Parallel   Composition
               | Replicate PiProcess         -- Infinite parallel replication
               | Let Term Value (Maybe PiProcess)
               | If Condition PiProcess PiProcess
                 deriving (Eq)

data Term = TVar Name 
          | TStr String
          | TNum Integer
          | TBool Bool
          | TPair (Term, Term)
          | TFun Name [Term] Int
            deriving (Eq)

data Value = Proc PiProcess 
           | Term Term
           | Chan Channel
           | PrimitiveFunc TermFun
           | Func {params :: [String] , body :: Value, closure :: Env}

data PiError = NumArgs Name Integer [Value]
             | TypeMismatch String [Value]
             | Parser ParseError
             | UnboundVar String String
             | NotTerm Name Value
             | NotFunction String String
             | NotChannel String
             | Default String

data Channel = Channel { 
               ch          :: Chans.Chan Value
             , handle      :: Handle
             , chanType    :: Type
             , send        :: Channel -> Value -> IO ()
             , receive     :: Channel -> IO Value
             }

type IOThrowsError = ExceptT PiError IO 
type ThrowsError   = Either  PiError

type Name      = String
type Type      = String
data Condition = Term `Equals` Term deriving (Eq)

type Env = IORef (Map String Value)

nullEnv :: IO Env
nullEnv = newIORef Map.empty

isBound :: Env -> String -> IO Bool
isBound envRef var = liftM (isJust . Map.lookup var) $ readIORef envRef

getVar :: Env -> String -> IOThrowsError Value 
getVar envRef var = do env <- liftIO $ readIORef envRef
                       maybe (throwE $ UnboundVar "Getting an unbound variable" var)
                             return
                             (Map.lookup var env)

setVar :: Env -> String -> Value -> IOThrowsError Value
setVar envRef var val = do env <- liftIO $ readIORef envRef
                           maybe (throwE $ UnboundVar "Setting an unbound variable" var)
                                 (return $ liftIO $ writeIORef envRef $ Map.insert var val env)
                                 (Map.lookup var env)
                           return val
                           
defineVar :: Env -> String -> Value -> IOThrowsError Value
defineVar envRef var val = do
    alreadyDefined <- liftIO $ isBound envRef var
    if alreadyDefined
        then setVar envRef var val >> return val
        else liftIO $ do
            env      <- readIORef envRef
            writeIORef envRef $ Map.insert var val env
            return val

showValue :: Value -> String
showValue (Proc p)  = show p
showValue (Term t)  = show t
showValue (Chan c)  = chanType c
showValue (PrimitiveFunc _)  = "<primitive>" 
showValue (Func {})          = "<user function>"  

eqvVal :: Value -> Value -> Bool
eqvVal (Proc p1)  (Proc p2) = p1 == p2
eqvVal (Term t1)  (Term t2) = t1 == t2
eqvVal _ _ = False

instance Eq Value where (==) = eqvVal

showPi :: PiProcess -> String
showPi Null = "0"
showPi (In c m) =  "in(" ++ show c ++ "," ++ show m ++ ")"
showPi (Out c m) =  "out(" ++ show c ++ "," ++  show m ++ ")"
showPi (Replicate proc) =  "!(" ++ show proc ++ ")"
showPi (p1 `Conc` p2) = show p1 ++ "|\n" ++ show p2
showPi (p1 `Seq` Null) = show p1
showPi (p1 `Seq` p2) = show p1 ++ ";\n" ++ show p2 
showPi (New n)   = "new " ++ show n
showPi (If c p1 Null) = "if " ++ show c ++ " then " ++ show p1 
showPi (If c p1 p2)   = "if " ++ show c ++ " then " ++ show p1 ++ " else " ++ show p2
showPi (Let n t p)    = "let " ++ show n ++ " = " ++ show t ++ " in\n" ++ show p

showTerm :: Term -> String
showTerm (TVar x)   = x
showTerm (TStr str) = str
showTerm (TNum num) = show num
showTerm (TBool b ) = if b then "true()" else "false()"
showTerm (TPair (a,b)) = "pair("++ show a ++ ","++ show b ++ ")"
showTerm (TFun n ts _ ) = n ++ "(" ++ intercalate "," (map show ts) ++ ")"

showCond :: Condition -> String
showCond (t1 `Equals` t2) = show t1 ++ " == " ++ show t2

showError :: PiError -> String
showError (UnboundVar message var)      = message ++ ": " ++ var
showError (NotFunction message fun)     = message ++ ": " ++ fun
showError (NotChannel chan)             = "Not a channel: " ++ chan 
showError (NotTerm name var)            = "Expecting " ++ name ++ " to be a Term, found: " ++ show var
showError (NumArgs name expected found) = "Expected " ++ show name ++ show expected ++ " args; found values "
                                          ++ unwordsList found
showError (TypeMismatch expected found) = "Invalid type: expected " ++ expected ++ ", found "
                                          ++ show found
showError (Parser parseErr)             = "Parse error at " ++ show parseErr
showError (Default msg)                 = msg

instance Show PiProcess where show = showPi
instance Show Term      where show = showTerm
instance Show Condition where show = showCond
instance Show Value     where show = showValue
instance Show PiError   where show = showError

unwordsList :: [Value] -> String
unwordsList = unwords . map show

parseNull :: Parser PiProcess
parseNull = do
            paddedChar '0'
            return Null

parseIn :: Parser PiProcess
parseIn = do
            _ <- string "in("
            name <- parseTerm
            paddedComma
            var  <- parseTerm
            _ <- char ')'
            parseSeq $ In name var 

parseOut :: Parser PiProcess
parseOut = do
            _ <- string "out("
            name <- parseTerm
            paddedComma
            term  <- parseTerm
            _ <- char ')'
            parseSeq $ Out name term 

parseReplicate :: Parser PiProcess
parseReplicate = do
            _ <- string "!("
            process <- parseProcess
            _ <- char ')'
            return $ Replicate process

paddedChar :: Char ->  Parser ()
paddedChar ch = do
            spaces
            _ <- char ch
            spaces

paddedStr :: String -> Parser ()
paddedStr str = do
            spaces
            _ <- string str
            spaces

parseSeq :: PiProcess -> Parser PiProcess
parseSeq p1 = do
            p2 <- try (do {paddedChar ';' ; parseProcess}) <|> return Null
            return $ p1 `Seq` p2

parseNew :: Parser PiProcess
parseNew = do
            _ <- string "new"
            spaces
            name <- parseTerm
            parseSeq $ New name

parseIf :: Parser PiProcess
parseIf = do
            _ <- string "if" 
            spaces
            cond <- parseCondition
            paddedStr "then"
            p1 <- parseProcess
            p2 <- try (do {paddedStr "else" ; parseProcess}) <|> return Null
            return $ If cond p1 p2

parseLet :: Parser PiProcess
parseLet = do
            _ <- string "let"
            spaces
            name <- parseTerm
            paddedChar '='
            val <- liftM Term parseTerm <|> liftM Proc parseProcess
            p <- try (do 
                paddedStr "in"
                proc <- parseProcess
                return $ Just proc) <|> return Nothing
            return $ Let name val p

parseCondition :: Parser Condition
parseCondition = do
            t1 <- parseTerm
            paddedChar '='
            t2 <- parseTerm
            return $ t1 `Equals` t2

parseTVar :: Parser Term
parseTVar = liftM TVar readVar 

parseTFun :: Parser Term
parseTFun = do
            name <- readVar
            spaces
            args <- bracketed $ sepBy parseTerm paddedComma
            return $ TFun name args (length args) 

parseTStr :: Parser Term
parseTStr = do
        _ <- char '"'
        x <- many $ noneOf "\""
        _ <- char '"'
        return $ TStr x

parseTNum :: Parser Term
parseTNum = liftM (TNum . read) (many1 digit)
        
readVar :: Parser Name
readVar = do
        frst <- letter
        rest <- many $ letter <|> digit <|> symbol
        return $ frst:rest

symbol :: Parser Char
symbol = oneOf "'._"

paddedComma :: Parser ()
paddedComma = paddedChar ','

parseTerm :: Parser Term
parseTerm =  try parseTFun
         <|> parseTNum
         <|> parseTVar
         <|> parseTStr

parseProcess :: Parser PiProcess
parseProcess = liftM (fold Conc) $ sepBy parseProcess' (paddedChar '|')
    where
    parseProcess'  = bracketed parseProcess'' <|> parseProcess''
    parseProcess'' = parseNull 
                 <|> try parseIf
                 <|> parseIn 
                 <|> parseOut
                 <|> parseReplicate
                 <|> parseNew
                 <|> parseLet
    fold _ [] = Null
    fold f xs = foldr1 f xs

bracketed :: Parser a -> Parser a
bracketed parser = do
                    _ <- char '('
                    spaces
                    res <- parser
                    spaces
                    _ <- char ')'
                    return res

type TermFun = [Term] -> ThrowsError Term

bindVars :: Env -> [(String , Value)] -> IO Env
bindVars envRef bindings = do
                env <- readIORef envRef
                newIORef $ Map.union (Map.fromList bindings) env

coreBindings :: IO Env
coreBindings = do
                n <- nullEnv 
                e1 <- bindVars n (map (second PrimitiveFunc) primitives) 
                bindVars e1 (map (second Chan) nativeChannels)

stdStrChan :: Handle -> Channel
stdStrChan h = Channel dummyChan h "string" write rd
    where
        write chan = hPrint (handle chan)
        rd  chan = do 
            msg <- hGetLine (handle chan)
            return $ Term $ extractValue $ readTerm msg

dummyChan :: Chans.Chan a
dummyChan = error "If this has happened, it is an error in my programming"

nativeChannels :: [(String   , Channel)]
nativeChannels = [ ("stdin"  , stdStrChan stdin) 
                 , ("0"      , stdStrChan stdin) 
                 , ("stdout" , stdStrChan stdout)
                 , ("1"      , stdStrChan stdout)
                 , ("stderr" , stdStrChan stderr)
                 , ("2"      , stdStrChan stderr)
                 ]

primitives :: [(String      , TermFun)]
primitives = [ ("true"      , true)
             , ("false"     , false)
             , ("fst"       , first)
             , ("snd"       , secnd)
             , ("hash"      , unaryId "hash")
             , ("pk"        , unaryId "pk")
             , ("http"      , http)
             , ("getmsg"    , getmsg)
             , ("pair"      , binaryId "pair")
             , ("sdec"      , sdec)
             , ("senc"      , binaryId "senc")
             , ("adec"      , adec)
             , ("aenc"      , binaryId "aenc")
             , ("sign"      , binaryId "sign")
             , ("checksign" , checksign)
             , ("mac"       , binaryId "mac")
             ]

true :: TermFun 
true [] = return $ TBool True
true e  = throwError $ NumArgs "true" 0 (map Term e)

false :: TermFun
false [] = return $ TBool False
false e = throwError $ NumArgs "false" 0 (map Term e)

constId :: String -> TermFun
constId name [] = return $ TFun name [] 0
constId name e  = throwError $ NumArgs name 0 (map Term e)

unaryId :: String -> TermFun
unaryId name [x] =  return $ TFun name [x] 1
unaryId name e  = throwError $ NumArgs name 1 (map Term e)

binaryId :: String ->  TermFun
binaryId name [x,y] = return $ TFun name [x,y] 2 
binaryId name e  = throwError $ NumArgs name 2 (map Term e)

getmsg :: TermFun
getmsg [TFun "sign" [_,y] 2] = return y
getmsg e = throwError $ TypeMismatch "sign" $ map Term e

first :: TermFun
first [TFun "pair" [x, _] 2] = return x
first e = throwError $ TypeMismatch "pair" $ map Term e 

secnd :: TermFun
secnd [TFun "pair" [_,y] 2] = return y
secnd e = throwError $ TypeMismatch "pair" $ map Term e 

http :: TermFun
http [TVar _] = undefined
http _        = undefined

sdec :: TermFun
sdec [k1, TFun "senc" [k2,y] 2]
    |k1 == k2  = return y
    |otherwise = throwError $ Default "keys not the same in sdec"
sdec e = throwError $ TypeMismatch "(var,senc(var,var))" $ map Term e

adec :: TermFun
adec [x , TFun "aenc" [TFun "pk" [k] 1, y ] 2]
    | x == k = return y
    | otherwise= throwError $ Default "keys not same in adec" 
adec e = throwError $ TypeMismatch "(var,aenc(pk(var),var))" $ map Term e

checksign :: TermFun
checksign [TFun "pk" [k1] 1 , TFun "sign" [k2,_] 2 ]
    | k1 == k2  = true []
    | otherwise = false [] 
checksign e = throwError $ TypeMismatch "(pk(var),sign(var,var))" $ map Term e

main :: IO ()
main = do
        name <- getProgName
        args <- getArgs
        pilude <- readFile "pilude.pi"
        case args of
            []  -> runRepl coreBindings
            [x] -> runProcess coreBindings x
            _   -> do
                    putStrLn "Use:"
                    putStrLn $ name ++ " -- Enter the REPL"
                    putStrLn $ name ++ " [process] -- Run single process"
        
readProgram :: String ->  ThrowsError PiProcess
readProgram input = case parse parseProcess "pi-calculus" input of
                        Left  err -> throwError $ Parser err
                        Right val -> return val 

evalCond :: Env -> Condition -> IOThrowsError Bool
evalCond env (t1 `Equals` t2) = liftM2 (==) (evalTerm env t1) (evalTerm env t2)

evalTerm :: Env -> Term -> IOThrowsError Value
evalTerm env (TVar name) = getVar env name
evalTerm _   (TNum num) = return $ Term $ TNum num
evalTerm _   (TStr str) = return $ Term $ TStr str
evalTerm _   (TBool b ) = return $ Term $ TBool b
evalTerm _   (TFun "fileChan" [TStr _] 1) = throwE $ Default "fileChans incomplete"
evalTerm _   (TFun "dummy" [] 0) = do
            c <- liftIO Chans.newChan
            let write = Chans.writeChan . ch
            let rd  = Chans.readChan . ch 
            return $ Chan $ Channel c stdout "" write rd
evalTerm _   (TFun "httpChan" [_] 1) = throwE $ Default "http channels undefined"
evalTerm env (TFun name args _) = do
            fun <- getVar env name
            argVals <- mapM (evalTerm env) args
            apply fun argVals

apply :: Value -> [Value] -> IOThrowsError Value 
apply (PrimitiveFunc fun) args = do
                        ts <- extracTerms args
                        res <- liftThrows $ fun ts
                        return $ Term res
apply (Func params body closure) args =
    if num params /= num args 
        then throwE $ NumArgs "user-defined" (num params) args
        else do
             clos <- liftIO (bindVars closure $ zip params args)
             case body of
                Term t -> evalTerm clos t
                Proc p -> eval clos p >> return body
                _      -> throwE $ Default "this function makes no sense"
    where
        num = toInteger . length
apply e _ = throwE $ NotFunction "expecting a function found" $ show e

extracTerms :: [Value] -> IOThrowsError [Term]
extracTerms ts
        | all isTerm ts = return $ map (\(Term t) -> t) ts
        | otherwise     = throwE $ Default "not all terms"
        
isTerm :: Value -> Bool
isTerm (Term _) = True
isTerm _ = False
        
liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows = either throwE return 

extractValue :: ThrowsError a -> a 
extractValue (Right v) = v
extractValue (Left  e) = error $ show e

eval :: Env -> PiProcess -> IOThrowsError () 
eval _ Null = liftIO $ do
                threadId <- myThreadId
                putStrLn $ "Stopping Process : " ++ show threadId
eval env (In a (TVar name)) = do
                chan <- evalChan env a
                received <- receiveIn chan
                _ <- defineVar env name received 
                liftIO $ putStrLn $ "Receiving " ++ show received ++ " On " ++ show a
eval env (Out a b) = do 
                chan <- evalChan env a
                bVal <- evalTerm env b
                sendOut chan bVal
                liftIO $ putStrLn $ "Sending " ++ show bVal ++ " On " ++ show a
eval env (Replicate proc) = liftIO (threadDelay 1000000) >> eval env (proc `Conc` Replicate proc)
eval env (p1 `Conc` p2) = do
                _ <- liftIO $ forkIO $ do {_ <- runExceptT $ eval env p1; return ()} -- there must be a better way
                eval env p2
eval env (p1 `Seq` p2) = do
                eval env p1
                eval env p2
eval env (New var@(TVar name)) = do
                _ <- defineVar env name $ Term var
                return ()
eval env (If b p1 p2) = do
                cond <- evalCond env b
                eval env (if cond then p1 else p2)
eval env (Let (TVar name) (Term t2) (Just p)) = do
                val <- evalTerm env t2 
                newEnv <- liftIO $ bindVars env [(name,val)]
                eval newEnv p
eval env (Let (TVar name) (Term t2) Nothing) = do
                val <- evalTerm env t2
                _ <- defineVar env name val
                return ()
eval env (Let (TFun name args _) t2 (Just p)) = 
            defineLocalFun env name args t2 p
eval env (Let (TFun name args _) t2 Nothing)  = 
            defineGlobalFun env name args t2
eval _ _ = throwE $ Default "undefined action"

defineGlobalFun :: Env -> String -> [Term] -> Value -> IOThrowsError ()
defineGlobalFun env name args term = do
            _ <- defineVar env name $ makeFun args term env
            return ()
defineLocalFun :: Env -> String -> [Term] -> Value -> PiProcess -> IOThrowsError ()
defineLocalFun env name args term p = do
            clos <- liftIO $ bindVars env [(name, makeFun args term env)]
            eval clos p


makeFun :: [Term] -> Value -> Env -> Value
makeFun args = Func (map show args)


evalString :: Env -> String -> IO String
evalString env expr = runIOThrows $ liftM show $ liftThrows (readProgram expr) >>= eval env

runIOThrows :: IOThrowsError String -> IO String
runIOThrows action = liftM extractValue $ runExceptT (trapError action)

trapError :: IOThrowsError String -> IOThrowsError String
trapError action = catchE action (return . show)

readTerm :: String -> ThrowsError Term 
readTerm str = case parse parseTerm "Term" str of
                Left  err -> throwError $ Parser err
                Right val -> return val 

evalAndPrint :: Env -> String -> IO ()
evalAndPrint _   []   = return () 
evalAndPrint env expr = evalString env expr >>= putStrLn

runProcess :: IO Env -> String -> IO ()
runProcess core expr = core >>= flip evalAndPrint expr

runRepl :: IO Env -> IO ()
runRepl core = core >>= until_ quit (readPrompt "phi >> ") . evalAndPrint
        where
            quit = flip any [":quit",":q"] . (==)

until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ pre prompt action = do
    result <- prompt
    unless (pre result) $ action result >> until_ pre prompt action

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

sendOut :: Channel -> Value -> IOThrowsError () 
sendOut chan val = liftIO $ send chan chan val

receiveIn :: Channel -> IOThrowsError Value
receiveIn chan = liftIO $  receive chan chan

evalChan :: Env -> Term -> IOThrowsError Channel
evalChan env t = do
            chan <- evalTerm env t
            case chan of
                Chan c -> return c
                _      -> throwE $ NotChannel $ show t