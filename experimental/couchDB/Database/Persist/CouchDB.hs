{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Database.Persist.CouchDB
    ( module Database.Persist
    , withCouchDBConn
    , CouchContext
    ) where

import Database.Persist
import Database.Persist.Sql hiding (ConnectionPool)
import Database.Persist.Types
-- import Database.Persist.Store
-- import Database.Persist.Query.Internal

import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans.Reader hiding (ask)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Base (MonadBase (liftBase))
import Control.Monad.Trans.Class (MonadTrans (..))
import "MonadCatchIO-transformers" Control.Monad.CatchIO
import Control.Monad.Trans.Control
  ( ComposeSt
  , defaultLiftBaseWith
  , defaultRestoreM
  , MonadBaseControl (..)
  , MonadTransControl (..)
  )
import Control.Applicative (Applicative)
import Control.Comonad.Env hiding (ask)
import Control.Monad.Catch
import Control.Monad.IO.Unlift

import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString as BS
import Data.Char
import Data.Either
import Data.List (intercalate, nub) -- , nubBy)
import Data.Pool
import Data.Maybe
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.HashMap.Strict as HashMap
import Data.HashMap.Strict (HashMap)
import qualified Data.Vector as Vector
import Data.Vector (Vector)
import Data.Digest.Pure.SHA
import Data.String.ToString
import Data.Text.Encoding
import Data.Time.Calendar
import Data.Time.Clock
-- import Data.Object
-- import Data.Neither (MEither (..), meither)
-- import Data.Enumerator (Stream (..), Step (..), Iteratee (..), returnI, run_, ($$))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
-- import qualified Data.Enumerator.List as EL
import qualified Database.CouchDB as DB
import qualified Control.Exception.Base as E
import Data.Aeson (Value (Object, Number), (.:), (.:?), (.!=), FromJSON(..))
import Data.Aeson.Types
import Data.Time (NominalDiffTime)
import Data.Attoparsec.Number
import qualified Text.JSON
import Web.PathPieces
import Web.HttpApiData
import Network.HTTP.Types.URI
import Data.Proxy

data IDGAFException = IDGAFException String Value deriving (Show, Eq)
instance Exception IDGAFException

data CouchContext =
  CouchContext
    { couchInstanceConn :: DB.CouchConn
    , couchInstanceDB :: DB.DB
    }

data CouchMonadT m a = CouchMonadT (ReaderT CouchContext m a)
  
instance HasPersistBackend CouchContext where
  type BaseBackend CouchContext = CouchContext
  persistBackend = id

instance PersistCore CouchContext where
  newtype BackendKey CouchContext = CouchKey { unCouchKey :: Text }
    deriving (Show, Read, Eq, Ord, PersistField)

instance PathPiece (BackendKey CouchContext) where
  fromPathPiece = Just . CouchKey
  toPathPiece (CouchKey k) = k

instance ToHttpApiData (BackendKey CouchContext) where
  toUrlPiece (CouchKey k) = toUrlPiece k
  toEncodedUrlPiece (CouchKey k) = toEncodedUrlPiece k
  toHeader (CouchKey k) = toHeader k
  toQueryParam (CouchKey k) = toQueryParam k

instance FromHttpApiData (BackendKey CouchContext) where
  parseUrlPiece = Right . CouchKey
  parseQueryParam = Right . CouchKey

instance PersistFieldSql (BackendKey CouchContext) where
  sqlType _ = sqlType (Proxy :: Proxy Text)

aesonToJSONResult :: Result a -> Text.JSON.Result a
aesonToJSONResult (Error str) = Text.JSON.Error str
aesonToJSONResult (Success a) = Text.JSON.Ok a

aesonToJSONValue :: Value -> Text.JSON.JSValue
aesonToJSONValue Null = Text.JSON.JSNull
aesonToJSONValue (Bool b) = Text.JSON.JSBool b
aesonToJSONValue (Number r) = Text.JSON.JSRational False (toRational r)
aesonToJSONValue (String t) = Text.JSON.JSString $ Text.JSON.toJSString $ T.unpack t
aesonToJSONValue (Array a) = Text.JSON.JSArray $ aesonToJSONValue <$> Vector.toList a
aesonToJSONValue (Object o) =
  Text.JSON.JSObject $
    Text.JSON.toJSObject $ (\(k,v) -> (T.unpack k, aesonToJSONValue v)) <$> HashMap.toList o

jsonToAesonValue :: Text.JSON.JSValue -> Value
jsonToAesonValue Text.JSON.JSNull = Null
jsonToAesonValue (Text.JSON.JSBool b) = Bool b
jsonToAesonValue (Text.JSON.JSRational _ r) = Number (fromRational r)
jsonToAesonValue (Text.JSON.JSString s) = String $ T.pack $ Text.JSON.fromJSString s
jsonToAesonValue (Text.JSON.JSArray a) = Array $ Vector.fromList $ jsonToAesonValue <$> a
jsonToAesonValue (Text.JSON.JSObject o) = Object $ HashMap.fromList $ (\(k,v) -> (T.pack k, jsonToAesonValue v)) <$> Text.JSON.fromJSObject o

instance (ToJSON a, FromJSON a) => Text.JSON.JSON a where
  readJSON v = aesonToJSONResult $ fromJSON $ jsonToAesonValue v
  showJSON a = aesonToJSONValue $ toJSON a
  readJSONs (Text.JSON.JSArray v) =
    let
      (errors, goods) = partitionEithers $ (parseEither parseJSON . jsonToAesonValue) <$> v
    in
    case (errors, goods) of
      ([], good) -> Text.JSON.Ok good
      (errors, _) -> Text.JSON.Error $ intercalate ";" errors
  readJSONs x = Text.JSON.Error "need an array"
  showJSONs xs = Text.JSON.JSArray $ (aesonToJSONValue . toJSON) <$> xs

instance ToJSON (BackendKey CouchContext) where
  toJSON (CouchKey k) = String k

instance FromJSON (BackendKey CouchContext) where
  parseJSON (String s) = pure $ CouchKey s
  parseJSON _ = fail "Not a matching type for key"

instance PersistStoreRead CouchContext where
  get k = do
    CouchContext {..} <- ask
    let
      doc = keyToDoc k
      conn = couchInstanceConn
      db = couchInstanceDB
    result <- run conn $ DB.getDoc db doc
    return $
          maybe
            Nothing
            (\(_, _, v) ->
               either
                 (\e -> error $ "Get error: " ++ T.unpack e)
                 Just $
                 wrapFromPersistValues (entityDef $ Just $ dummyFromKey k) v
            ) result
  getMany = getMany

instance PersistQueryRead CouchContext where
  selectSourceRes filts opts = selectSourceRes filts opts
  selectFirst filts opts = selectFirst filts opts
  selectKeysRes filts opts = selectKeysRes filts opts
  count = count

instance PersistQueryWrite CouchContext where
  updateWhere filts updates = updateWhere filts updates
  deleteWhere = deleteWhere

maybeHead :: [a] -> Maybe a
maybeHead [] = Nothing
maybeHead (x:_) = Just x

couchDBGetBy
  :: forall m record .
     ( PersistStoreRead CouchContext
     , MonadIO m
     , PersistRecordBackend record CouchContext
     , PersistEntityBackend record ~ CouchContext
     )
  => Unique record
  -> ReaderT CouchContext m (Maybe (Entity record))
couchDBGetBy u = do
  let
    names = map (T.unpack . unDBName . snd) $ persistUniqueToFieldNames u
    values = uniqueToJSON $ persistUniqueToValues u
    t = entityDef $ Just $ dummyFromUnique u
    name = viewName names
    design = designName t
  ctx <- ask
  x <- runView ctx design name [("key", values)] [DB.ViewMap name $ defaultView t names ""]
  let justKey = (\(k, v) -> docToKey $ k) =<< maybeHead (x :: [(DB.Doc, PersistValue)])
  case isNothing justKey of
    True -> return Nothing
    False -> do
      let key = fromJust justKey
      y <- get key
      return $ fmap (\v -> Entity key v) y

instance PersistUniqueRead CouchContext where
  getBy = couchDBGetBy

instance PersistStoreWrite CouchContext where
  insert = insert
  insert_ = insert_
  insertMany = insertMany
  insertMany_ = insertMany_
  insertEntityMany = insertEntityMany
  insertKey k = insertKey k
  repsert k = repsert k
  repsertMany = repsertMany
  replace k = replace k
  delete = delete
  update k = update k
  updateGet k = updateGet k

instance PersistUniqueWrite CouchContext where
  deleteBy = deleteBy
  insertUnique = insertUnique
  upsert rec = upsert rec
  upsertBy uniq rec = upsertBy uniq rec
  putMany = putMany

uniqueToJSON :: [PersistValue] -> Value
uniqueToJSON [] = Null
uniqueToJSON [x] = toJSON x
uniqueToJSON xs = Array $ Vector.fromList $ fmap toJSON xs

dummyFromUnique :: Unique v -> v
dummyFromUnique _ = error "dummyFromUnique"

#ifdef hmm
instance (MonadIO m) => MonadBaseControl b (ReaderT CouchContext m) where
  newtype StM (ReaderT CouchContext m) a = StMSP {unStMSP :: ComposeSt (ReaderT CouchContext m) a}
  liftBaseWith = defaultLiftBaseWith StMSP
  restoreM = defaultRestoreM unStMSP
#endif

#ifdef persist_has_this_already_now
instance FromJSON PersistValue where
    parseJSON (Null) = pure $ PersistNull
    parseJSON (Bool x) = pure $ PersistBool x
    parseJSON (Number x) = pure $ PersistDouble $ fromRational x
    parseJSON (String x) = pure $ PersistText x
    parseJSON (Array x) = do
      let
        (parsedErrors, parsedGood) :: ([String],[PersistValue]) =
          partitionEithers $ (parseEither parseJSON) <$> Vector.toList x
      case (parsedErrors, parsedGood) of
        ([], good) -> PersistList good
        (errors, _) -> fail $ intercalate ";" errors
    parseJSON (Object x) =
      let
        pairs :: [Either String (Text, PersistValue)] =
          (\(k,v) ->
             either
               (const $ Left (k, Null))
               (\decval -> Right (k,decval))
               (parseEither parseJSON v)
          ) <$> HashMap.fromList x
        (parsedErrors, parsedGood) = partitionEithers pairs
      in
      case (parsedErrors, parsedGood) of
        ([], good) -> PersistMap $ Map.fromList good
        (errors, _) -> fail $ intercalate ";" errors

instance ToJSON PersistValue where
    toJSON (PersistText x) = String . toString $ T.unpack x
    toJSON (PersistByteString x) = String . toString $ B.unpack x
    toJSON (PersistInt64 x) = Number $ fromIntegral x
    toJSON (PersistDouble x) = Number $ toRational x
    toJSON (PersistBool x) = Bool x
    toJSON (PersistDay x) = String . toString $ show x
    toJSON (PersistTimeOfDay x) = String . toString $ show x
    toJSON (PersistUTCTime x) = String . toString $ show x
    toJSON (PersistNull) = Null
    toJSON (PersistList x) = Array $ map toJSON x
    toJSON (PersistMap x) = Object $ HashMap.fromList $ map (\(k, v) -> (T.unpack k, toJSON v)) x
    toJSON (PersistObjectId _) = error "PersistObjectId is not supported."
#endif

wrapFromPersistValues :: (PersistEntity val) => EntityDef -> PersistValue -> Either Text val
wrapFromPersistValues e doc = fromPersistValues reorder
    where clean (PersistMap x) = filter (\(k, _) -> T.head k /= '_') x
          reorder = match (map (unDBName . fieldDB) $ (entityFields e)) (clean doc) []
              where match [] [] values = values
                    match (c:cs) fields values = let (found, unused) = matchOne fields []
                                                  in match cs unused (values ++ [snd found])
                        where matchOne (f:fs) tried = if c == fst f
                                                         then (f, tried ++ fs)
                                                         else matchOne fs (f:tried)
                              matchOne fs tried = error $ "reorder error: field doesn't match"
                                                          ++ (show c) ++ (show fs) ++ (show tried)
                    match cs fs values = error $ "reorder error: fields don't match"
                                                 ++ (show cs) ++ (show fs) ++ (show values)

entityToJSON :: forall record. (PersistEntity record, PersistEntityBackend record ~ CouchContext) => record -> Value
entityToJSON x = Object $ HashMap.fromList $ zip names values
    where
      names = map (unDBName . fieldDB) $ entityFields $ entityDef $ Just x
      values = map (toJSON . toPersistValue) $ toPersistFields x

run :: (MonadIO m) => DB.CouchConn -> DB.CouchMonad a -> m a
run conn x = liftIO . DB.runCouchDBWith conn $ x

-- | Open one database connection.
withCouchDBConn
  :: forall m b .
     (MonadIO m)
  => String -- ^ database name
  -> String -- ^ host name (typically \"localhost\")
  -> Int    -- ^ port number (typically 5984)
  -> (CouchContext -> m b) -> m b
withCouchDBConn db host port fn = do
  conn <- open
  res <- fn conn
  close conn
  pure res
  where
    open = do
      unless (DB.isDBString db) $ error $ "Wrong database name: " ++ db
      conn <- liftIO $ DB.createCouchConn host port
      liftIO $ E.catch (run conn $ DB.createDB db)
        (\(E.ErrorCall _) -> return ())
      return $ CouchContext conn $ DB.db db

    close = liftIO . DB.closeCouchConn . couchInstanceConn

defaultView :: EntityDef -> [String] -> String -> String
defaultView t names extra = viewBody . viewConstraints (map (T.unpack . unDBName . fieldDB) $ entityFields t)
                            $ if null extra then viewEmit names [] else extra

viewBody :: String -> String
viewBody x = "(function (doc) {" ++ x ++ "})"

viewConstraints :: [String] -> String -> String
viewConstraints [] y = y
viewConstraints xs y = "if (" ++ (intercalate " && " $ map ("doc."++) xs) ++ ") {" ++ y ++ "}"

viewEmit :: [String] -> [String] -> String
viewEmit [] _ = viewEmit ["_id"] []
viewEmit arr obj = "emit(" ++ array arr ++ ", " ++ object obj ++ ");"
    where array [] = "doc._id"
          array [x] = "doc." ++ x
          array xs = "[" ++ (intercalate ", " $ map ("doc."++) xs) ++ "]"
          object [] = "doc._id"
          object [x] = "doc." ++ x
          object xs = "{" ++ (intercalate ", " $ map (\x -> "\"" ++ x ++ "\": " ++ "doc." ++ x) xs) ++ "}"

viewName :: [String] -> String
viewName [] = "default"
viewName xs = intercalate "_" xs

uniqueViewName :: [String] -> String -> String
uniqueViewName names text = viewName names ++ "_" ++ (showDigest . sha1 $ BL.pack text)

viewFilters :: (PersistEntity val) => [Filter val] -> String -> String
viewFilters [] x = x
viewFilters filters x = "if (" ++ (intercalate " && " $ map fKind filters) ++ ") {" ++ x ++ "}"
    where
      handleFilter (FilterValue t) = (BL.unpack . encode . toJSON . toPersistValue) t
      handleFilter (FilterValues t) = (BL.unpack . encode . Array . Vector.fromList . map (toJSON . toPersistValue)) t
      handleFilter (UnsafeValue u) = (BL.unpack . encode . toJSON . toPersistValue) u

      fKind (Filter field v NotIn) =
        "!(" ++ fKind (Filter field v In) ++ ")"
      fKind (Filter field v op) =
        "doc." ++ (T.unpack $ unDBName $ fieldDBName field) ++
        fOp op ++
        (handleFilter v)
      fKind (FilterOr fs) = "(" ++ (intercalate " || " $ map fKind fs) ++ ")"
      fKind (FilterAnd fs) = "(" ++ (intercalate " && " $ map fKind fs) ++ ")"
      fOp Eq = " == "
      fOp Ne = " != "
      fOp Gt = " > "
      fOp Lt = " < "
      fOp Ge = " >= "
      fOp Le = " <= "
      fOp In = " in "

filtersToNames :: (PersistEntity val) => [Filter val] -> [String]
filtersToNames = nub . concatMap f
    where f (Filter field _ _) = [T.unpack $ unDBName $ fieldDBName field]
          f (FilterOr fs) = concatMap f fs
          f (FilterAnd fs) = concatMap f fs

designName :: EntityDef -> DB.Doc
designName entity = DB.doc . (\(x:xs) -> toLower x : xs) $ (T.unpack $ unDBName $ entityDB entity)

runView :: (ToJSON a, FromJSON a, MonadIO m) => CouchContext -> DB.Doc -> String -> [(String, Value)] -> [DB.CouchView] -> m [(DB.Doc, a)]
runView CouchContext {..} design name dict views = do
  let
    conn = couchInstanceConn
    db = couchInstanceDB
    query = run conn $ DB.queryView db design (DB.doc name) $
            (\(k,v) -> (k,aesonToJSONValue v)) <$> dict
    -- The DB.newView function from the Database.CouchDB v 0.10 module is broken
    -- and fails with the HTTP 409 error when it is called more than once.
    -- Since there is no way to manipulate the _design area directly, we are using
    -- a modified version of the module.
    create = run conn $ DB.newView (show db) (show design) views
  liftIO $ E.catch query (\(E.ErrorCall _) -> create >> query)

docToKey
  :: forall record .
     ( PersistEntity record
     , PersistEntityBackend record ~ CouchContext
     )
  => DB.Doc
  -> Maybe (Key record)
docToKey doc = either (const Nothing) Just $ keyFromValues [PersistText $ T.pack $ show doc]

keyToDoc
  :: forall record .
     ( PersistEntity record
     , PersistEntityBackend record ~ CouchContext
     )
  => Key record
  -> DB.Doc
keyToDoc key =
  case keyToValues key of
    [PersistText val] -> DB.doc $ T.unpack val
    values -> DB.doc $ showDigest $ sha1 $ encode values

dummyFromKey :: Key v -> v
dummyFromKey _ = error "dummyFromKey"

dummyFromFilts :: [Filter v] -> v
dummyFromFilts _ = error "dummyFromFilts"

#ifdef notyet
instance MonadTransControl CouchReader where
    newtype StT CouchReader a = StReader {unStReader :: a}
    liftWith f = CouchReader . ReaderT $ \r -> f $ \t -> liftM StReader $ runReaderT (unCouchConn t) r
    restoreT = CouchReader . ReaderT . const . liftM unStReader

modify :: (JSON a, MonadIO m) => (t -> a -> IO a) -> Key backend entity -> t -> CouchReader m ()
modify f k v = do
    let doc = keyToDoc k
    (conn, db) <- CouchReader ask
    _ <- run conn $ DB.getAndUpdateDoc db doc (f v)
    return ()

{-
opts :: [SelectOpt a] -> [(String, Value)]
opts = nubBy (\(x, _) (y, _) -> x == "descending" && x == y) . map o
    -- The Asc and Desc options should be attribute dependent. Now, they just handle reversing of the output.
    where o (Asc _) = ("descending", JSBool False)
          o (Desc _) = ("descending", JSBool True)
          o (OffsetBy x) = ("skip", JSRational False $ fromIntegral x)
          o (LimitTo x) = ("limit", JSRational False $ fromIntegral x)
-}

-- This is not a very effective solution, since it takes the whole input in once. It should be rewritten completely.
{-
select :: (PersistEntity val, MonadIO m) => [Filter val] -> [(String, Value)]
    -> Step a' (CouchReader m) b -> [String] -> ((DB.Doc, PersistValue) -> a') -> Iteratee a' (CouchReader m) b
select f o (Continue k) vals process = do
    let names = filtersToNames f
        t = entityDef $ dummyFromFilts f
        design = designName t
        filters = viewFilters f $ viewEmit names vals
        name = uniqueViewName names filters
    (conn, db) <- lift $ CouchReader ask
    x <- runView conn db design name o [DB.ViewMap name $ defaultView t names filters]
    returnI $$ k . Chunks $ map process x
-}

instance (MonadIO m) => PersistStore CouchReader m where
    insert v = do
        (conn, db) <- CouchReader ask
        (doc, _) <- run conn $ DB.newDoc db (entityToJSON v)
        return $ docToKey doc

    replace = modify $ const . return . entityToJSON

    delete k = do
        let doc = keyToDoc k
        (conn, db) <- CouchReader ask
        _ <- run conn $ DB.forceDeleteDoc db doc
        return ()

    get k = do
        let doc = keyToDoc k
        (conn, db) <- CouchReader ask
        result <- run conn $ DB.getDoc db doc
        return $ maybe Nothing (\(_, _, v) -> either (\e -> error $ "Get error: " ++ T.unpack e) Just $
                                              wrapFromPersistValues (entityDef $ dummyFromKey k) v) result

instance (MonadIO m) => PersistUnique CouchReader m where
    getBy u = do
        let names = map (T.unpack . unDBName . snd) $ persistUniqueToFieldNames u
            values = uniqueToJSON $ persistUniqueToValues u
            t = entityDef $ dummyFromUnique u
            name = viewName names
            design = designName t
        (conn, db) <- CouchReader ask
        x <- runView conn db design name [("key", values)] [DB.ViewMap name $ defaultView t names ""]
        let justKey = fmap (\(k, _) -> docToKey k) $ maybeHead (x :: [(DB.Doc, PersistValue)])
        if isNothing justKey
           then return Nothing
           else do let key = fromJust justKey
                   y <- get key
                   return $ fmap (\v -> Entity key v) y

    {-
    deleteBy u = do
        mEnt <- getBy u
        case mEnt of
          Just (Entity key _) -> delete key
          Nothing -> return ()
          -}
             

fieldName ::  forall record typ.  (PersistEntity record) => EntityField record typ -> Text
fieldName = unDBName . fieldDB . persistFieldDef

instance PersistQuery CouchReader where
    update key = modify (\u x -> return $ foldr field x u) key
        where -- e = entityDef $ dummyFromKey key
              field (Update updField value up) doc = case up of
                                                   Assign -> execute doc $ const val
                                                   Add -> execute doc $ op (+) val
                                                   Subtract -> execute doc $ op (-) val
                                                   Multiply -> execute doc $ op (*) val
                                                   Divide -> execute doc $ op (/) val
                  where name = fieldName updField
                        val = toPersistValue value
                        execute (PersistMap x) g = PersistMap $ map (\(k, v) -> if k == name then (k, g v) else (k, v)) x
                        op o (PersistInt64 x) (PersistInt64 y) = PersistInt64 . truncate $ (fromIntegral y) `o` (fromIntegral x)
                        op o (PersistDouble x) (PersistDouble y) = PersistDouble $ y `o` x

    {-
    updateWhere f u = run_ $ selectKeys f $$ EL.mapM_ (flip update u)

    deleteWhere f = run_ $ selectKeys f $$ EL.mapM_ delete
    -}

    {-
    selectSource f o k = let entity = entityDef $ dummyFromFilts f
                        in select f (opts o) k (map fieldDB $ entityFields entity)
                                  (\(x, y) -> (docToKey x, either (\e -> error $ "SelectEnum error: " ++ e)
                                                                  id $ wrapFromPersistValues entity y))
    -}

    -- selectKeys f k = select f [] k [] (docToKey . fst)

    -- It is more effective to use a MapReduce view with the _count function, but the Database.CouchDB module
    -- expects the id attribute to be present in the result, which is e.g. {"rows":[{"key":null,"value":10}]}.
    -- For now, it is possible to write a custom function or to catch the exception and parse the count from it,
    -- but that is just plain ugly.
    -- count f = run_ $ selectKeys f $$ EL.fold ((flip . const) (+1)) 0

-- | Information required to connect to a CouchDB database.
data CouchConf = CouchConf
    { couchDatabase :: String
    , couchHost     :: String
    , couchPort     :: Int
    , couchPoolSize :: Int
    }

newtype NoOrphanNominalDiffTime = NoOrphanNominalDiffTime NominalDiffTime
                                deriving (Show, Eq, Num)
instance FromJSON NoOrphanNominalDiffTime where
    parseJSON (Number (I x)) = (return . NoOrphanNominalDiffTime . fromInteger) x
    parseJSON (Number (D x)) = (return . NoOrphanNominalDiffTime . fromRational . toRational) x
    parseJSON _ = fail "couldn't parse diff time"

instance PersistConfig CouchConf where
    type PersistConfigBackend CouchConf = CouchReader
    type PersistConfigPool CouchConf = CouchContext
    -- createPoolConfig (CouchConf db host port poolsize) = withCouchDBPool db host port poolsize
    runPool _ = runCouchDBConn
    loadConfig (Object o) = do
        db   <- o .: "database"
        host               <- o .:? "host" .!= "127.0.0.1"
        port               <- o .:? "port" .!= 5984 -- (PortNumber 5984)
        pool               <- o .:? "poolsize" .!= 1
        {-
        poolStripes        <- o .:? "poolstripes" .!= 1
        stripeConnections  <- o .:  "connections"
        -- (NoOrphanNominalDiffTime connectionIdleTime) <- o .:? "connectionIdleTime" .!= 20
        mUser              <- o .:? "user"
        mPass              <- o .:? "password"
        -}

        return $ CouchConf { couchDatabase = T.unpack db
                           , couchHost = T.unpack host
                           , couchPort = port
                           , couchPoolSize = pool
                           }
    loadConfig _ = mzero
#endif
