{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import Control.Exception (SomeException, fromException)
import System.IO (hSetBuffering, stdout, BufferMode(LineBuffering))
import qualified Data.String
import Web.Scotty
import Network.Wai (requestMethod, remoteHost, mapResponseHeaders)
import Network.Wai.Handler.Warp (defaultSettings, setHost, setPort)
import Network.HTTP.Types.Status
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import GHC.Generics (Generic)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.ByteString as B
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (convertToBase, Base(Base16))
import qualified Crypto.KDF.Argon2 as Argon
import Crypto.Error (CryptoFailable(..))
import Crypto.Random (getRandomBytes)
import Crypto.Hash (hash, Digest, SHA256)
import Database.SQLite.Simple
import Control.Concurrent.MVar
import Control.Monad (when, unless)
import Data.Time
import Data.Time.Clock.POSIX
import qualified Data.Map.Strict as M
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data Credentials = Credentials {name :: Maybe T.Text, email :: T.Text, password :: T.Text} deriving (Generic)
instance FromJSON Credentials

data ExpenseInput = ExpenseInput {amount :: Int, category :: T.Text, date :: T.Text, note :: T.Text} deriving (Generic)
instance FromJSON ExpenseInput

data BudgetInput = BudgetInput {month :: T.Text, budget :: Int} deriving (Generic)
instance FromJSON BudgetInput

data ProfileInput = ProfileInput {displayName :: T.Text} deriving (Generic)
instance FromJSON ProfileInput

data Expense = Expense {id :: Int, amountCents :: Int, expenseCategory :: T.Text, expenseDate :: T.Text, expenseNote :: T.Text} deriving (Generic)
instance ToJSON Expense
instance FromRow Expense where fromRow = Expense <$> field <*> field <*> field <*> field <*> field

type DB = MVar Connection
type Limiter = MVar (M.Map T.Text (Int,Integer))

db :: DB -> (Connection -> IO a) -> IO a
db = withMVar

now :: IO Integer
now = floor <$> getPOSIXTime

randomToken :: IO T.Text
randomToken = TE.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 32 :: IO B.ByteString)

hashToken :: T.Text -> T.Text
hashToken t = T.pack (show (hash (TE.encodeUtf8 t) :: Digest SHA256))

passwordHash :: T.Text -> T.Text -> T.Text
passwordHash p salt = case Argon.hash argonOptions (TE.encodeUtf8 p) (TE.encodeUtf8 salt) 32 :: CryptoFailable B.ByteString of
  CryptoPassed b -> TE.decodeUtf8 (convertToBase Base16 b)
  CryptoFailed e -> error (show e)
  where argonOptions = Argon.defaultOptions {Argon.variant = Argon.Argon2id, Argon.iterations = 3, Argon.memory = 65536, Argon.parallelism = 1}

failApi :: Status -> T.Text -> ActionM a
failApi s message = status s >> json (object ["error" .= message]) >> finish

validDay :: T.Text -> Bool
validDay t = T.length t == 10 && case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack t) :: Maybe Day of
  Just d -> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" d) == t
  Nothing -> False

validMonth :: T.Text -> Bool
validMonth m = T.length m == 7 && validDay (m <> "-01")

categories :: [T.Text]
categories = ["Food", "Transport", "Shopping", "Bills", "Health", "Education", "Entertainment", "Other"]

validateExpense :: ExpenseInput -> ActionM ()
validateExpense e = unless (amount e > 0 && amount e <= 1000000000 && category e `elem` categories && validDay (date e) && T.length (note e) <= 240) $ failApi badRequest400 "Check the amount, category, date and note (240 characters maximum)."

cookieToken :: ActionM T.Text
cookieToken = do
  value <- header "Cookie"
  pure $ case value of
    Nothing -> ""
    Just v -> case [T.drop 4 x | x <- map T.strip (T.splitOn ";" (TL.toStrict v)), "sid=" `T.isPrefixOf` x] of
      x:_ -> x
      [] -> ""

-- The user ID always comes from the session, never from request JSON.
auth :: DB -> ActionM (Int, T.Text, T.Text, T.Text)
auth database = do
  token <- cookieToken
  t <- liftIO now
  rows <- liftIO $ db database $ \c -> query c "SELECT u.id,u.name,u.email,s.csrf FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires>?" (hashToken token,t) :: IO [(Int,T.Text,T.Text,T.Text)]
  case rows of
    u:_ -> do
      r <- request
      when (requestMethod r `notElem` ["GET","HEAD"]) $ do
        supplied <- header "X-CSRF-Token"
        unless (maybe False (\s -> TE.encodeUtf8 (TL.toStrict s) `constEq` TE.encodeUtf8 (fourth u)) supplied) $ failApi forbidden403 "Your session could not be verified. Reload and try again."
      pure u
    [] -> failApi unauthorized401 "Please sign in to continue."
  where fourth (_,_,_,x) = x

respondUser :: (Int,T.Text,T.Text,T.Text) -> ActionM ()
respondUser (uid,n,e,csrf) = json (object ["user" .= object ["id" .= uid,"name" .= n,"email" .= e],"csrf" .= csrf])

startSession :: DB -> Bool -> (Int,T.Text,T.Text) -> ActionM ()
startSession database secure (uid,n,e) = do
  old <- cookieToken
  token <- liftIO randomToken
  csrf <- liftIO randomToken
  t <- liftIO now
  liftIO $ db database $ \c -> withTransaction c $ do
    execute c "DELETE FROM sessions WHERE expires<=? OR token_hash=?" (t,hashToken old)
    execute c "INSERT INTO sessions(token_hash,user_id,csrf,expires) VALUES (?,?,?,?)" (hashToken token,uid,csrf,t+604800)
  setHeader "Set-Cookie" (TL.fromStrict ("sid=" <> token <> "; Path=/; HttpOnly; SameSite=Strict; Max-Age=604800" <> if secure then "; Secure" else ""))
  respondUser (uid,n,e,csrf)

limitAuth :: Limiter -> ActionM ()
limitAuth limiter = do
  marker <- header "X-Requested-With"
  unless (marker == Just "Masroufy") $ failApi forbidden403 "Invalid request origin."
  r <- request
  t <- liftIO now
  let key = T.takeWhile (/= ':') (T.pack (show (remoteHost r)))
  allowed <- liftIO $ modifyMVar limiter $ \m -> do
    let recent = M.filter (\(_,stamp) -> t-stamp<900) m
        (count,ts) = M.findWithDefault (0,t) key recent
    pure (M.insert key (count+1,ts) recent,count<30)
  unless allowed $ failApi tooManyRequests429 "Too many attempts. Please try again in 15 minutes."

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  createDirectoryIfMissing True "data"
  path <- maybe "data/masroufy.sqlite" Prelude.id <$> lookupEnv "DATABASE_PATH"
  connection <- open path
  execute_ connection "PRAGMA foreign_keys=ON"
  execute_ connection "PRAGMA journal_mode=WAL"
  execute_ connection "PRAGMA busy_timeout=5000"
  execute_ connection "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, salt TEXT NOT NULL, password_hash TEXT NOT NULL)"
  execute_ connection "CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), csrf TEXT NOT NULL, expires INTEGER NOT NULL)"
  execute_ connection "CREATE TABLE IF NOT EXISTS expenses (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), amount INTEGER NOT NULL CHECK(amount>0), category TEXT NOT NULL, date TEXT NOT NULL, note TEXT NOT NULL)"
  execute_ connection "CREATE INDEX IF NOT EXISTS expenses_owner_date ON expenses(user_id,date)"
  execute_ connection "CREATE TABLE IF NOT EXISTS budgets (user_id INTEGER NOT NULL REFERENCES users(id), month TEXT NOT NULL, amount INTEGER NOT NULL CHECK(amount>=0), PRIMARY KEY(user_id,month))"
  database <- newMVar connection
  limiter <- newMVar M.empty
  secure <- (== Just "1") <$> lookupEnv "SECURE_COOKIE"
  port <- maybe 3000 (maybe 3000 Prelude.id . readMaybe) <$> lookupEnv "PORT"
  host <- maybe "127.0.0.1" Prelude.id <$> lookupEnv "HOST"
  putStrLn ("Masroufy running at http://" ++ host ++ ":" ++ show port)
  scottyOpts (Options 0 (setPort port (setHost (fromStringHost host) defaultSettings)) True) $ do
    middleware $ \app req send -> app req $ \response -> send (mapResponseHeaders (securityHeaders ++) response)
    defaultHandler (Handler $ \(e :: SomeException) -> case fromException e :: Maybe ScottyException of
      Just _ -> status badRequest400 >> json (object ["error" .= ("Invalid request data." :: T.Text)])
      Nothing -> status internalServerError500 >> json (object ["error" .= ("Something went wrong. Please try again." :: T.Text)]))
    get "/" $ setHeader "Content-Type" "text/html; charset=utf-8" >> setHeader "Cache-Control" "no-store" >> file "static/index.html"
    get "/style.css" $ setHeader "Content-Type" "text/css; charset=utf-8" >> file "static/style.css"
    get "/app.js" $ setHeader "Content-Type" "application/javascript; charset=utf-8" >> file "static/app.js"
    get "/api/health" $ json (object ["status" .= ("ok" :: T.Text)])
    post "/api/signup" $ do
      limitAuth limiter
      input <- jsonData :: ActionM Credentials
      let n=T.strip (maybe "" Prelude.id (name input)); e=T.toLower (T.strip (email input)); p=password input
      unless (T.length n>=2 && T.length n<=60 && T.length e<=254 && T.count "@" e==1 && not (T.any (==' ') e) && T.isInfixOf "." (T.takeWhileEnd (/='@') e) && T.length p>=10 && T.length p<=128) $ failApi badRequest400 "Enter your name, a valid email, and a password of 10-128 characters."
      salt <- liftIO randomToken
      let digest=passwordHash p salt
      uid <- liftIO $ db database $ \c -> withTransaction c $ do
        existing <- query c "SELECT id FROM users WHERE email=?" (Only e) :: IO [Only Int]
        if not (null existing) then pure Nothing else do
          execute c "INSERT INTO users(name,email,salt,password_hash) VALUES (?,?,?,?)" (n,e,salt,digest)
          Just . fromIntegral <$> lastInsertRowId c
      case uid of
        Nothing -> failApi conflict409 "An account with that email already exists."
        Just u -> status created201 >> startSession database secure (u,n,e)
    post "/api/login" $ do
      limitAuth limiter
      input <- jsonData :: ActionM Credentials
      unless (T.length (password input)<=128 && T.length (email input)<=254) $ failApi unauthorized401 "Incorrect email or password."
      rows <- liftIO $ db database $ \c -> query c "SELECT id,name,email,salt,password_hash FROM users WHERE email=?" (Only (T.toLower (T.strip (email input)))) :: IO [(Int,T.Text,T.Text,T.Text,T.Text)]
      let (uid,n,e,salt,stored)=case rows of
            u:_ -> u
            [] -> (0,"","","dummy-salt-used-for-timing-123456",T.replicate 64 "0")
          matches = TE.encodeUtf8 (passwordHash (password input) salt) `constEq` TE.encodeUtf8 stored
      unless (matches && uid/=0) $ failApi unauthorized401 "Incorrect email or password."
      startSession database secure (uid,n,e)
    get "/api/me" $ auth database >>= respondUser
    post "/api/logout" $ do
      _ <- auth database
      token <- cookieToken
      liftIO $ db database $ \c -> execute c "DELETE FROM sessions WHERE token_hash=?" (Only (hashToken token))
      setHeader "Set-Cookie" "sid=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
      json (object ["ok" .= True])
    put "/api/profile" $ do
      (uid,_,_,_) <- auth database
      p <- jsonData :: ActionM ProfileInput
      let n=T.strip (displayName p)
      unless (T.length n>=2 && T.length n<=60) $ failApi badRequest400 "Name must be 2-60 characters."
      liftIO $ db database $ \c -> execute c "UPDATE users SET name=? WHERE id=?" (n,uid)
      json (object ["ok" .= True])
    get "/api/expenses" $ do
      (uid,_,_,_) <- auth database
      rows <- liftIO $ db database $ \c -> query c "SELECT id,amount,category,date,note FROM expenses WHERE user_id=? ORDER BY date DESC,id DESC" (Only uid) :: IO [Expense]
      json rows
    post "/api/expenses" $ do
      (uid,_,_,_) <- auth database
      e <- jsonData :: ActionM ExpenseInput
      validateExpense e
      newId <- liftIO $ db database $ \c -> do
        execute c "INSERT INTO expenses(user_id,amount,category,date,note) VALUES (?,?,?,?,?)" (uid,amount e,category e,date e,T.strip (note e))
        lastInsertRowId c
      status created201
      json (object ["id" .= newId])
    put "/api/expenses/:expenseId" $ do
      (uid,_,_,_) <- auth database
      eid <- pathParam "expenseId" :: ActionM Int
      e <- jsonData :: ActionM ExpenseInput
      validateExpense e
      changed <- liftIO $ db database $ \c -> do
        execute c "UPDATE expenses SET amount=?,category=?,date=?,note=? WHERE id=? AND user_id=?" (amount e,category e,date e,T.strip (note e),eid,uid)
        changes c
      when (changed==0) $ failApi notFound404 "Expense not found."
      json (object ["ok" .= True])
    delete "/api/expenses/:expenseId" $ do
      (uid,_,_,_) <- auth database
      eid <- pathParam "expenseId" :: ActionM Int
      changed <- liftIO $ db database $ \c -> execute c "DELETE FROM expenses WHERE id=? AND user_id=?" (eid,uid) >> changes c
      when (changed==0) $ failApi notFound404 "Expense not found."
      json (object ["ok" .= True])
    get "/api/summary" $ do
      (uid,_,_,_) <- auth database
      selected <- queryParam "month" :: ActionM T.Text
      unless (validMonth selected) $ failApi badRequest400 "Invalid month."
      (values,budgets) <- liftIO $ db database $ \c -> do
        es <- query c "SELECT amount FROM expenses WHERE user_id=? AND substr(date,1,7)=?" (uid,selected) :: IO [Only Int]
        bs <- query c "SELECT amount FROM budgets WHERE user_id=? AND month=?" (uid,selected) :: IO [Only Int]
        pure (es,bs)
      let total = sum [a | Only a <- values]
          planned = case budgets of Only a:_ -> Just a; [] -> Nothing
      json (object ["month" .= selected,"total" .= total,"count" .= length values,"budget" .= planned,"remaining" .= fmap (subtract total) planned])
    get "/api/budgets" $ do
      (uid,_,_,_) <- auth database
      rows <- liftIO $ db database $ \c -> query c "SELECT month,amount FROM budgets WHERE user_id=?" (Only uid) :: IO [(T.Text,Int)]
      json [object ["month" .= m,"amount" .= a] | (m,a)<-rows]
    put "/api/budget" $ do
      (uid,_,_,_) <- auth database
      b <- jsonData :: ActionM BudgetInput
      unless (validMonth (month b) && budget b>=0 && budget b<=1000000000) $ failApi badRequest400 "Enter a valid month and budget."
      liftIO $ db database $ \c -> execute c "INSERT INTO budgets(user_id,month,amount) VALUES (?,?,?) ON CONFLICT(user_id,month) DO UPDATE SET amount=excluded.amount" (uid,month b,budget b)
      json (object ["ok" .= True])
    notFound $ failApi notFound404 "Page not found."
  where
    fromStringHost = Data.String.fromString
    securityHeaders = [("X-Content-Type-Options","nosniff"),("X-Frame-Options","DENY"),("Referrer-Policy","same-origin"),("Cache-Control","no-store"),("Content-Security-Policy","default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")]








