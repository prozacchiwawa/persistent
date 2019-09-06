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
    , aesonToJSONResult
    , aesonToJSONValue
    , jsonToAesonValue
    ) where

import Database.Persist
import Database.Persist.Sql hiding (ConnectionPool)
import Database.Persist.Types
-- import Database.Persist.Store
-- import Database.Persist.Query.Internal

import qualified Control.Error.Util as CE
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

import Data.Acquire
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString as BS
import Data.Char
import Data.Conduit
import qualified Data.Conduit.List as ConduitList
import Data.Either
import Data.List (intercalate, nub, nubBy, uncons)
import Data.Pool
import Data.Ratio
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

-- Actually tried pulling in Data.Either.Extra but doesn't appear to contain mapLeft with the
-- package set we have
mapLeft :: forall a b c . (a -> b) -> Either a c -> Either b c
mapLeft f (Left a) = Left (f a)
mapLeft f (Right x) = Right x

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

getSchemaFromObject :: Value -> String
getSchemaFromObject (Object o) =
  case HashMap.lookup "$schema" o of
    Just (String s) -> T.unpack s
    _ -> ""

placeSchemaLetter letter (k,fld) =
  let
    newFld =
      case (letter,fld) of
        (_,String s) -> String $ T.pack $ [letter] ++ T.unpack s
        ('r',Number v) ->
          let
            rat :: Rational = toRational v
          in
          String $ T.pack $ "r" ++ (show $ numerator rat) ++ "%" ++ (show $ denominator rat)
        (_,v) -> v
  in
  (k,newFld)

getSchemaLetter :: PersistValue -> Char
getSchemaLetter (PersistText _) = 's'
getSchemaLetter (PersistByteString _) = 'b'
getSchemaLetter (PersistInt64 _) = 'i'
getSchemaLetter (PersistDouble _) = 'd'
getSchemaLetter (PersistRational _) = 'r'
getSchemaLetter (PersistBool _) = 'b'
getSchemaLetter (PersistTimeOfDay _) = 't'
getSchemaLetter (PersistUTCTime _) = 'u'
getSchemaLetter PersistNull = '!'
getSchemaLetter (PersistList _) = '#'
getSchemaLetter (PersistMap _) = '%'
getSchemaLetter (PersistObjectId _) = 'o'
getSchemaLetter (PersistDbSpecific _) = 'p'

makeSchemaString :: [PersistValue] -> String
makeSchemaString pv = getSchemaLetter <$> pv

rehydrate :: String -> [(Text,Value)] -> Either Text [(Text,PersistValue)]
rehydrate schema vs =
  let
    (errors,good) = partitionEithers $ convertItem <$> uncurry placeSchemaLetter <$> zip schema vs
  in
  case (errors,good) of
    ([], good) -> Right good
    (errors, _) -> Left $ T.pack $ intercalate ";" $ errors
  where
    convertItem (k,v) =
      let
        converted = parseEither parseJSON v
      in
      (\cvt -> (k,cvt)) <$> converted

wrapFromValues
  :: EntityDef
  -> Value
  -> Either Text [(Text,Value)]
wrapFromValues e doc = reorder
    where
      match :: [Text] -> [(Text, Value)] -> [(Text,Value)] -> Either Text [(Text,Value)]
      match [] fields values = Right values
      match (c:cs) fields values =
        let
          found = uncons $ filter (\f -> fst f == c) fields
        in
        maybe
          (Left $ T.pack $ "could not find " ++ T.unpack c)
          (\((_,f),_) -> match cs fields (values ++ [(c,f)]))
          found

      clean (Object o) = filter (\(k, _) -> T.head k /= '_' && k /= "id" && k /= "$schema") $ HashMap.toList o
      reorder = match (map (unDBName . fieldDB) $ (entityFields e)) (clean doc) []

couchDBGet
  :: forall m record .
     (MonadIO m, PersistRecordBackend record CouchContext)
  => CouchContext
  -> Key record
  -> DB.Doc
  -> m (Maybe record)
couchDBGet CouchContext {..} k doc = do
  liftIO $ putStrLn $ "key " ++ show k
  let
    conn = couchInstanceConn
    db = couchInstanceDB
  result :: Maybe (DB.Doc, DB.Rev, Text.JSON.JSValue) <- run conn $ DB.getDoc db doc
  liftIO $ putStrLn $ "val " ++ show result
  outRecord <-
    either
      (\e -> error e)
      (\(_, _, v) -> do
         let
           edef = entityDef $ Just $ dummyFromKey k
           toDecode = jsonToAesonValue v
           schemaString = getSchemaFromObject toDecode
           fields =
             case toDecode of
               Object o -> HashMap.toList o
               _ -> [("$", toDecode)]
           unwrappedForDecode = wrapFromValues edef toDecode
           
         liftIO $ putStrLn $ "wrapFromValues " ++ show schemaString ++ " " ++ show unwrappedForDecode
         
         let
           aboutTo :: Either Text [(Text,Value)] =
             (\l -> uncurry placeSchemaLetter <$> zip schemaString l) <$> unwrappedForDecode
           res :: Either Text [(Text,PersistValue)] =
             rehydrate schemaString =<< unwrappedForDecode

         liftIO $ putStrLn $ "about to " ++ show aboutTo
         liftIO $ putStrLn $ "got values " ++ show res

         decoded :: Either Text val <-
           either
             (\e -> do
                 liftIO $ putStrLn $ "failed " ++ T.unpack e
                 pure $ Left e
             )
             (\v -> do
                 liftIO $ putStrLn $ "wrap ok"
                 pure $ Right v
             )
             (fromPersistValues =<< (\l -> snd <$> l) <$> res)

         pure decoded
      )
      (CE.note "could not decode as json" result)
  either
    (\e -> do
        liftIO $ putStrLn $ "nothing!! " ++ T.unpack e
        pure Nothing
    )
    (\rec -> do
        liftIO $ putStrLn "got a record"
        pure $ Just rec
    )
    outRecord
--  return $ either (const Nothing) Just outRecord

instance PersistStoreRead CouchContext where
  get k = do
    ctx <- ask
    couchDBGet ctx k (keyToDoc k)
  getMany = getMany

-- This is not a very effective solution, since it takes the whole input in once. It should be rewritten completely.
couchDBSelect
  :: forall m record a .
     (MonadIO m, PersistRecordBackend record CouchContext)
  => CouchContext
  -> [Filter record]
  -> [(String, Value)]
  -> [String]
  -> m [Entity record]
couchDBSelect ctx f o vals = do
    let names = filtersToNames f
        t = entityDef $ Just $ dummyFromFilts f
        design = designName t
        filters = viewFilters f $ viewEmit names vals
        name = uniqueViewName names filters
    x :: [(DB.Doc, Value)] <- runView ctx design name o [DB.ViewMap name $ defaultView t names filters]
    liftIO $ putStrLn $ show x
    y :: [Maybe (Entity record)] <-
      mapM
        (\(k,v) -> do
            let
              key =
                case v of
                  (String s) ->
                    either (const Nothing) id $
                      fromPersistValue (PersistDbSpecific $ encodeUtf8 s)
                  _ -> Nothing

            result :: Maybe (Entity record) <-
              maybe
                (pure Nothing)
                (\k -> do
                    doc :: Maybe record <- couchDBGet ctx k (keyToDoc k)
                    pure $ (Entity k) <$> doc
                )
                key

            pure result
        ) x

    return $ catMaybes y

opts :: [SelectOpt a] -> [(String, Value)]
opts = nubBy (\(x, _) (y, _) -> x == "descending" && x == y) . map o
    -- The Asc and Desc options should be attribute dependent. Now, they just handle reversing of the output.
    where o (Asc _) = ("descending", Bool False)
          o (Desc _) = ("descending", Bool True)
          o (OffsetBy x) = ("skip", Number $ fromIntegral x)
          o (LimitTo x) = ("limit", Number $ fromIntegral x)

couchDBSelectSourceRes
  :: forall m record .
     (MonadIO m
     , PersistRecordBackend record CouchContext
     , PersistEntityBackend record ~ CouchContext
     )
  => CouchContext
  -> [Filter record]
  -> [SelectOpt record]
  -> m [Entity record]
couchDBSelectSourceRes ctx f o = do
  let
    entity = entityDef $ Just $ dummyFromFilts f

  couchDBSelect ctx f (opts o) (map (T.unpack . unDBName . fieldDB) $ entityFields entity)

instance PersistQueryRead CouchContext where
  selectSourceRes filts opts = do
    ctx <- ask
    let
      resourceGuardOverConduit =
        mkAcquire
          (do
              results <- couchDBSelectSourceRes ctx filts opts
              pure $ ConduitList.sourceList results
          )
          (const $ pure ())
    pure resourceGuardOverConduit
    
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
  => CouchContext
  -> Unique record
  -> m (Maybe (Entity record))
couchDBGetBy ctx u = do
  let
    names = map (T.unpack . unDBName . snd) $ persistUniqueToFieldNames u
    values = uniqueToJSON $ persistUniqueToValues u
    t = entityDef $ Just $ dummyFromUnique u
    name = viewName names
    design = designName t
  liftIO $ putStrLn $ "u " ++ show names ++ ":" ++ show values
  x <- runView ctx design name [("key", values)] [DB.ViewMap name $ defaultView t names ""]
  let justKey = (\(k, v) -> docToKey $ k) =<< maybeHead (x :: [(DB.Doc, Value)])
  liftIO $ putStrLn $ "justKey " ++ show justKey
  case isNothing justKey of
    True -> return Nothing
    False -> do
      let key = fromJust justKey
      y <- couchDBGet ctx key (keyToDoc key)
      return $ fmap (\v -> Entity key v) y

instance PersistUniqueRead CouchContext where
  getBy k = do
    ctx <- ask
    couchDBGetBy ctx k

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

isNotUndefined :: String -> String
isNotUndefined x = x ++ " !== undefined"

viewConstraints :: [String] -> String -> String
viewConstraints [] y = y
viewConstraints xs y = "if (" ++ (intercalate " && " $ map ("doc."++) $ isNotUndefined <$> xs) ++ ") {" ++ y ++ "}"

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
    [PersistByteString val] -> DB.doc $ T.unpack $ decodeUtf8 val
    [PersistObjectId val] -> DB.doc $ T.unpack $ decodeUtf8 val
    [PersistDbSpecific val] -> DB.doc $ T.unpack $ decodeUtf8 val
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
                                              (entityDef $ dummyFromKey k) v)

instance (MonadIO m) => PersistUnique CouchReader m where
    getBy u = do
        let names = map (T.unpack . unDBName . snd) $ persistUniqueToFieldNames u
            values = uniqueToJSON $ persistUniqueToValues u
            t = entityDef $ dummyFromUnique u
            name = viewName names
            design = designName t
        (conn, db) <- CouchReader ask
        x <- runView conn design name [("key", values)] [DB.ViewMap name $ defaultView t names ""]
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
