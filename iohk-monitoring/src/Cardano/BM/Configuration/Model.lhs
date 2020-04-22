
\subsection{Cardano.BM.Configuration.Model}
\label{code:Cardano.BM.Configuration.Model}

%if style == newcode
\begin{code}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE ViewPatterns          #-}

{-@ LIQUID "--max-case-expand=4" @-}

module Cardano.BM.Configuration.Model
    ( Configuration (..)
    , ConfigurationInternal (..)
    , empty
    , evalFilters
    , exportConfiguration
    , findSubTrace
    , getAggregatedKind
    , getAcceptAt
    , getBackends
    , getCachedScribes
    , getDefaultBackends
    , getEKGport
    , getForwardTo
    , getGUIport
    , getGraylogPort
    , getMapOption
    , getMonitors
    , getOption
    , getPrometheusBindAddr
    , getScribes
    , getSetupBackends
    , getSetupScribes
    , getTextOption
    , inspectSeverity
    , minSeverity
    , setAggregatedKind
    , setBackends
    , setCachedScribes
    , setDefaultAggregatedKind
    , setDefaultBackends
    , setDefaultScribes
    , setEKGport
    , setForwardTo
    , setGUIport
    , setGraylogPort
    , setMinSeverity
    , setMonitors
    , setOption
    , setPrometheusBindAddr
    , setScribes
    , setSetupBackends
    , setSetupScribes
    , setSeverity
    , setSubTrace
    , setTextOption
    , setup
    , setupFromRepresentation
    , testSubTrace
    , toRepresentation
    , updateOption
    ) where

import           Control.Applicative (Alternative ((<|>)))
import           Control.Arrow ((***))
import           Control.Concurrent.MVar (MVar, newMVar, readMVar,
                     modifyMVar_)
import           Control.Monad (when)
import           Data.Aeson ((.:))
import           Data.Aeson.Types (parseMaybe)
import qualified Data.HashMap.Strict as HM
import           Data.Maybe (maybe, catMaybes, fromMaybe)
import qualified Data.Text as T
import           Data.Text (Text, pack, unpack)
import qualified Data.Vector as Vector
import           Data.Yaml as Yaml

import           Cardano.BM.Data.AggregatedKind (AggregatedKind(..))
import           Cardano.BM.Data.BackendKind
import qualified Cardano.BM.Data.Configuration as R
import           Cardano.BM.Data.Configuration (RemoteAddr(..), RemoteAddrNamed(..))
import           Cardano.BM.Data.LogItem
                    ( LogObject (..), LoggerName, LOContent (..), SMaybe (..)
                    , consLoggerName, loggerNameFromText, loggerNameRest, loggerNameText
                    , severity)
import           Cardano.BM.Data.MonitoringEval (MEvExpr, MEvPreCond, MEvAction)
import           Cardano.BM.Data.Output (ScribeDefinition (..), ScribeId,
                     ScribeKind (..))
import           Cardano.BM.Data.Rotation (RotationParameters (..))
import           Cardano.BM.Data.Severity
import           Cardano.BM.Data.SubTrace

\end{code}
%endif

\subsubsection{Configuration.Model}\label{code:Configuration}
\begin{figure}[ht]
\centering{
  \includegraphics[scale=0.54]{ConfigurationModel.pdf}
}
\caption{Configuration model}\label{fig:configuration}
\end{figure}

\begin{code}
type ConfigurationMVar = MVar ConfigurationInternal
newtype Configuration = Configuration
    { getCG :: ConfigurationMVar }

-- Our internal state; see {-"\nameref{fig:configuration}"-}
data ConfigurationInternal = ConfigurationInternal
    { cgMinSeverity       :: Severity
    -- minimum severity level of every object that will be output
    , cgDefRotation       :: Maybe RotationParameters
    -- default rotation parameters
    , cgOptions           :: HM.HashMap Text Value
    -- options needed for tracing, logging and monitoring
    , cgDefBackendKs      :: [BackendKind]
    -- backends that will be used if a set of backends for the
    -- specific loggername is not set
    , cgSetupBackends     :: [BackendKind]
    -- backends to setup; every backend to be used must have
    -- been declared here
    , cgDefScribes        :: [ScribeId]
    -- katip scribes that will be used if a set of scribes for the
    -- specific loggername is not set
    , cgSetupScribes      :: [ScribeDefinition]
    -- katip scribes to setup; every scribe to be used must have
    -- been declared here
    , cgDefAggregatedKind :: AggregatedKind
    -- kind of Aggregated that will be used if a set of scribes for the
    -- specific loggername is not set
    , cgPortEKG           :: Int
    -- port for EKG server
    , cgPortGraylog       :: Int
    -- port to Graylog server
    , cgBindAddrPrometheus :: Maybe (String, Int)
    -- host/port to bind Prometheus server at
    , cgForwardTo         :: Maybe RemoteAddr
    -- trace acceptor to forward to
    , cgAcceptAt          :: Maybe [RemoteAddrNamed]
    -- accept remote traces at this address
    , cgPortGUI           :: Int
    -- port for changes at runtime

    -- Hierarchically-organised namespaces:
    , cgMapBackend        :: HM.HashMap LoggerName [BackendKind]
    -- backends that will be used for the specific loggername
    , cgMapSeverity       :: HM.HashMap LoggerName Severity
    -- severity filter per loggername
    , cgMapSubtrace       :: HM.HashMap LoggerName SubTrace
    -- type of trace per loggername
    , cgMapScribe         :: HM.HashMap LoggerName [ScribeId]
    -- katip scribes that will be used for the specific loggername
    , cgMonitors          :: HM.HashMap LoggerName (MEvPreCond, MEvExpr, [MEvAction])
    , cgMapAggregatedKind :: HM.HashMap LoggerName AggregatedKind
    -- kind of Aggregated that will be used for the specific loggername

    -- Caches for expensive hierarchical lookups:
    , cgMapBackendCache   :: HM.HashMap LoggerName [BackendKind]
    , cgMapScribeCache    :: HM.HashMap LoggerName [ScribeId]
    , cgMapSubtraceCache  :: HM.HashMap LoggerName SubTrace
    } deriving (Show, Eq)

lookupHierarchyCached
  :: forall a
  .  LoggerName
  -> HM.HashMap LoggerName a
  -> Maybe (HM.HashMap LoggerName a)
  -> Maybe a
  -> (LoggerName -> Maybe a -> IO ())
  -> IO (Maybe a)
lookupHierarchyCached name namespace mCache nullResult updateCache = do
    when needCacheUpdate $
      updateCache name result
    pure result
  where
      needCacheUpdate :: Bool
      result :: Maybe a
      (needCacheUpdate, result) =
        -- full string name -> [a] cache lookup
        case mCache of
          Nothing -> (False, find_s $ SJust name)
          Just cache -> case HM.lookup name cache of
            Just os -> (False, Just os)
            -- Cache miss; do the expensive hierarchical lookup for
            -- inheritance and request a cache update.
            Nothing -> (True, find_s $ SJust name)

      find_s :: SMaybe LoggerName -> Maybe a
      find_s = \case
        SNothing -> nullResult
        SJust ln -> case HM.lookup ln namespace of
          r@Just{} -> r
          Nothing -> find_s $ loggerNameRest ln

\end{code}

\subsubsection{Backends configured in the |Switchboard|}
For a given context name return the list of backends configured,
or, in case no such configuration exists, return the default backends.
\begin{code}
getBackends :: Configuration -> LoggerName -> IO [BackendKind]
getBackends conf name = do
    cg <- readMVar $ getCG conf
    fromMaybe [] <$> lookupHierarchyCached name
      (cgMapBackend cg)
      Nothing -- (cgMapBackendCache cg)
      (Just $ cgDefBackendKs cg)
      (setCachedBackends conf)

setCachedBackends :: Configuration -> LoggerName -> Maybe [BackendKind] -> IO ()
setCachedBackends configuration name xs =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapBackendCache = HM.alter (\_ -> xs) name (cgMapBackendCache cg) }

getDefaultBackends :: Configuration -> IO [BackendKind]
getDefaultBackends configuration =
    cgDefBackendKs <$> (readMVar $ getCG configuration)

setDefaultBackends :: Configuration -> [BackendKind] -> IO ()
setDefaultBackends configuration bes =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgDefBackendKs = bes }

setBackends :: Configuration -> LoggerName -> Maybe [BackendKind] -> IO ()
setBackends configuration name be =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapBackend = HM.alter (\_ -> be) name (cgMapBackend cg) }

\end{code}

\subsubsection{Backends to be setup by the |Switchboard|}
Defines the list of |Backend|s that need to be setup by the |Switchboard|.
\begin{code}
setSetupBackends :: Configuration -> [BackendKind] -> IO ()
setSetupBackends configuration bes =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgSetupBackends = bes }

getSetupBackends :: Configuration -> IO [BackendKind]
getSetupBackends configuration =
    cgSetupBackends <$> (readMVar $ getCG configuration)

\end{code}

\subsubsection{Scribes configured in the |Log| backend}
For a given context name return the list of scribes to output to,
or, in case no such configuration exists, return the default scribes to use.
\begin{code}
getScribes :: Configuration -> LoggerName -> IO [ScribeId]
getScribes conf name = do
    cg <- readMVar $ getCG conf
    fromMaybe [] <$> lookupHierarchyCached name
      (cgMapScribe cg)
      (Just $ cgMapScribeCache cg)
      (Just $ cgDefScribes cg)
      (setCachedScribes conf)

getCachedScribes :: Configuration -> LoggerName -> IO (Maybe [ScribeId])
getCachedScribes configuration name = do
    cg <- readMVar $ getCG configuration
    return $ HM.lookup name $ cgMapScribeCache cg

setScribes :: Configuration -> LoggerName -> Maybe [ScribeId] -> IO ()
setScribes configuration name scribes =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapScribe = HM.alter (\_ -> scribes) name (cgMapScribe cg) }

setCachedScribes :: Configuration -> LoggerName -> Maybe [ScribeId] -> IO ()
setCachedScribes configuration name scribes =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapScribeCache = HM.alter (\_ -> scribes) name (cgMapScribeCache cg) }

setDefaultScribes :: Configuration -> [ScribeId] -> IO ()
setDefaultScribes configuration scs =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgDefScribes = scs }

\end{code}

\subsubsection{Scribes to be setup in the |Log| backend}
Defines the list of |Scribe|s that need to be setup in the |Log| backend.
\begin{code}
setSetupScribes :: Configuration -> [ScribeDefinition] -> IO ()
setSetupScribes configuration sds =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgSetupScribes = sds }

getSetupScribes :: Configuration -> IO [ScribeDefinition]
getSetupScribes configuration =
    cgSetupScribes <$> readMVar (getCG configuration)

\end{code}

\subsubsection{|AggregatedKind| to define the type of measurement}
For a given context name return its |AggregatedKind| or in case no
such configuration exists, return the default |AggregatedKind| to use.
\begin{code}
getAggregatedKind :: Configuration -> LoggerName -> IO AggregatedKind
getAggregatedKind configuration name = do
    cg <- readMVar $ getCG configuration
    let outs = HM.lookup name (cgMapAggregatedKind cg)
    case outs of
        Nothing -> return $ cgDefAggregatedKind cg
        Just os -> return $ os

setDefaultAggregatedKind :: Configuration -> AggregatedKind -> IO ()
setDefaultAggregatedKind configuration defAK =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgDefAggregatedKind = defAK }

setAggregatedKind :: Configuration -> LoggerName -> Maybe AggregatedKind -> IO ()
setAggregatedKind configuration name ak =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapAggregatedKind = HM.alter (\_ -> ak) name (cgMapAggregatedKind cg) }

\end{code}

\subsubsection{Access port numbers of EKG, Prometheus, GUI}
\begin{code}
getEKGport :: Configuration -> IO Int
getEKGport configuration =
    cgPortEKG <$> (readMVar $ getCG configuration)

setEKGport :: Configuration -> Int -> IO ()
setEKGport configuration port =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgPortEKG = port }

getGraylogPort :: Configuration -> IO Int
getGraylogPort configuration =
    cgPortGraylog <$> (readMVar $ getCG configuration)

setGraylogPort :: Configuration -> Int -> IO ()
setGraylogPort configuration port =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgPortGraylog = port }

getPrometheusBindAddr :: Configuration -> IO (Maybe (String, Int))
getPrometheusBindAddr configuration =
    cgBindAddrPrometheus <$> (readMVar $ getCG configuration)

setPrometheusBindAddr :: Configuration -> Maybe (String, Int) -> IO ()
setPrometheusBindAddr configuration mHostPort =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgBindAddrPrometheus = mHostPort }

getGUIport :: Configuration -> IO Int
getGUIport configuration =
    cgPortGUI <$> (readMVar $ getCG configuration)

setGUIport :: Configuration -> Int -> IO ()
setGUIport configuration port =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgPortGUI = port }

getAcceptAt :: Configuration -> IO (Maybe [RemoteAddrNamed])
getAcceptAt = fmap cgAcceptAt . readMVar . getCG

getForwardTo :: Configuration -> IO (Maybe RemoteAddr)
getForwardTo = fmap cgForwardTo . readMVar . getCG

setForwardTo :: Configuration -> Maybe RemoteAddr -> IO ()
setForwardTo cf mra =
    modifyMVar_ (getCG cf) $ \cg ->
        return cg { cgForwardTo = mra }

\end{code}

\subsubsection{Options}
\begin{code}
getMapOption' :: HM.HashMap Text Value -> Text -> Maybe Object
getMapOption' m (flip HM.lookup m -> Just (Object x)) = Just x
getMapOption' _ _ = Nothing

getTextOption' :: HM.HashMap Text Value -> Text -> Maybe Text
getTextOption' m (flip HM.lookup m -> Just (String x)) = Just x
getTextOption' _ _ = Nothing

getOption :: Configuration -> Text -> IO (Maybe Value)
getOption configuration name =
  HM.lookup name . cgOptions <$> readMVar (getCG configuration)

getTextOption :: Configuration -> Text -> IO (Maybe Text)
getTextOption configuration name =
  flip getTextOption' name . cgOptions <$> readMVar (getCG configuration)

getMapOption :: Configuration -> Text -> IO (Maybe Object)
getMapOption configuration name =
  flip getMapOption' name . cgOptions <$> readMVar (getCG configuration)

updateOption :: Configuration -> Text -> (Maybe Value -> Value) -> IO ()
updateOption configuration name f =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgOptions = HM.alter (Just . f) name (cgOptions cg) }

setOption :: Configuration -> Text -> Value -> IO ()
setOption configuration name = updateOption configuration name . const

setTextOption :: Configuration -> Text -> Text -> IO ()
setTextOption configuration name = setOption configuration name . String

\end{code}

\subsubsection{Global setting of minimum severity}
\begin{code}
minSeverity :: Configuration -> IO Severity
minSeverity configuration =
    cgMinSeverity <$> (readMVar $ getCG configuration)

setMinSeverity :: Configuration -> Severity -> IO ()
setMinSeverity configuration sev =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMinSeverity = sev }

\end{code}

\subsubsection{Relation of context name to minimum severity}
\begin{code}
inspectSeverity :: Configuration -> LoggerName -> IO (Maybe Severity)
inspectSeverity configuration name = do
    cg <- readMVar $ getCG configuration
    return $ HM.lookup name (cgMapSeverity cg)

setSeverity :: Configuration -> LoggerName -> Maybe Severity -> IO ()
setSeverity configuration name sev =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapSeverity = HM.alter (\_ -> sev) name (cgMapSeverity cg) }

\end{code}

\subsubsection{Relation of context name to SubTrace}\label{code:findSubTrace}\label{code:setSubTrace}
A new context may contain a different type of |Trace|.
The function |appendName| will look up the |SubTrace| for the context's name.
\begin{code}
findSubTrace :: Configuration -> LoggerName -> IO (Maybe SubTrace)
findSubTrace configuration name =
    HM.lookup name <$> cgMapSubtrace <$> (readMVar $ getCG configuration)

setSubTrace :: Configuration -> LoggerName -> Maybe SubTrace -> IO ()
setSubTrace configuration name trafo =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapSubtrace = HM.alter (\_ -> trafo) name (cgMapSubtrace cg) }

\end{code}

\subsubsection{Monitors}

\begin{spec}
Just (
  fromList [
    ("chain.creation.block", Array [
      Object (fromList [("monitor", String "((time > (23 s)) Or (time < (17 s)))")]),
      Object (fromList [("actions", Array [
        String "AlterMinSeverity \"chain.creation\" Debug"])])])
  , ("#aggregation.critproc.observable", Array [
      Object (fromList [("monitor", String "(mean >= (42))")]),
      Object (fromList [("actions", Array [
        String "CreateMessage \"exceeded\" \"the observable has been too long too high!\"",
        String "AlterGlobalMinSeverity Info"])]) ]) ] )
\end{spec}

\begin{code}
getMonitors :: Configuration -> IO (HM.HashMap LoggerName (MEvPreCond, MEvExpr, [MEvAction]))
getMonitors configuration = do
    cg <- readMVar $ getCG configuration
    return (cgMonitors cg)

setMonitors :: Configuration -> HM.HashMap LoggerName (MEvPreCond, MEvExpr, [MEvAction]) -> IO ()
setMonitors configuration monitors =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMonitors = monitors }
\end{code}

\subsubsection{Parse configuration from file}
Parse the configuration into an internal representation first. Then, fill in |Configuration|
after refinement.
\begin{code}
setup :: FilePath -> IO Configuration
setup fp = do
    r <- R.readRepresentation fp
    setupFromRepresentation r

parseMonitors :: Maybe (HM.HashMap LoggerName Value) -> HM.HashMap LoggerName (MEvPreCond, MEvExpr, [MEvAction])
parseMonitors Nothing = HM.empty
parseMonitors (Just hmv) = HM.mapMaybe mkMonitor hmv
    where
    mkMonitor :: Value -> Maybe (MEvPreCond, MEvExpr, [MEvAction])
    mkMonitor = parseMaybe $ \v ->
                    (withObject "" $ \o ->
                        (,,) <$> o .:? "monitor-if"
                             <*> o .:  "monitor"
                             <*> o .:  "actions") v
                    <|> parseJSON v

setupFromRepresentation :: R.Representation -> IO Configuration
setupFromRepresentation r = do
    let getMap k           = rekeyMapToLoggerName <$> getMapOption' (R.options r) k
        mapbackends        = parseBackendMap $ getMap "mapBackends"
        mapscribes         = parseScribeMap $ getMap "mapScribes"
        mapsubtraces       = parseSubtraceMap $ getMap "mapSubtrace"
        defRotation        = R.rotation r

    cgref <- newMVar $ ConfigurationInternal
        { cgMinSeverity       = R.minSeverity r
        , cgDefRotation       = defRotation
        , cgMapSeverity       = parseSeverityMap $ getMap "mapSeverity"
        , cgMapSubtrace       = mapsubtraces
        , cgMapSubtraceCache  = mapsubtraces
        , cgOptions           = R.options r
        , cgMapBackend        = mapbackends
        , cgMapBackendCache   = mapbackends
        , cgDefBackendKs      = R.defaultBackends r
        , cgSetupBackends     = R.setupBackends r
        , cgMapScribe         = mapscribes
        , cgMapScribeCache    = mapscribes
        , cgDefScribes        = r_defaultScribes r
        , cgSetupScribes      = fillRotationParams defRotation (R.setupScribes r)
        , cgMapAggregatedKind = parseAggregatedKindMap $ getMap "mapAggregatedkinds"
        , cgDefAggregatedKind = StatsAK
        , cgMonitors          = parseMonitors $ getMap "mapMonitors"
        , cgPortEKG           = r_hasEKG r
        , cgPortGraylog       = r_hasGraylog r
        , cgBindAddrPrometheus = r_hasPrometheus r
        , cgPortGUI           = r_hasGUI r
        , cgForwardTo         = r_forward r
        , cgAcceptAt          = r_accept r
        }
    return $ Configuration cgref
  where
    rekeyMapToLoggerName :: HM.HashMap Text a -> HM.HashMap LoggerName a
    rekeyMapToLoggerName = HM.fromList . fmap (loggerNameFromText *** id) . HM.toList

    parseSeverityMap :: Maybe (HM.HashMap LoggerName Value) -> HM.HashMap LoggerName Severity
    parseSeverityMap Nothing = HM.empty
    parseSeverityMap (Just hmv) = HM.mapMaybe mkSeverity hmv
      where
        mkSeverity (String s) = Just (read (unpack s) :: Severity)
        mkSeverity _ = Nothing

    fillRotationParams :: Maybe RotationParameters -> [ScribeDefinition] -> [ScribeDefinition]
    fillRotationParams defaultRotation = map $ \sd ->
        if scKind sd == FileSK
        then
            sd { scRotation = maybe defaultRotation Just (scRotation sd) }
        else
            -- stdout, stderr, /dev/null and systemd cannot be rotated
            sd { scRotation = Nothing }

    parseBackendMap Nothing = HM.empty
    parseBackendMap (Just hmv) = HM.map mkBackends hmv
      where
        mkBackends (Array bes) = catMaybes $ map mkBackend $ Vector.toList bes
        mkBackends _ = []
        mkBackend :: Value -> Maybe BackendKind
        mkBackend = parseMaybe parseJSON

    parseScribeMap Nothing = HM.empty
    parseScribeMap (Just hmv) = HM.map mkScribes hmv
      where
        mkScribes (Array scs) = catMaybes $ map mkScribe $ Vector.toList scs
        mkScribes (String s) = [(s :: ScribeId)]
        mkScribes _ = []
        mkScribe :: Value -> Maybe ScribeId
        mkScribe = parseMaybe parseJSON

    parseSubtraceMap :: Maybe (HM.HashMap LoggerName Value) -> HM.HashMap LoggerName SubTrace
    parseSubtraceMap Nothing = HM.empty
    parseSubtraceMap (Just hmv) = HM.mapMaybe mkSubtrace hmv
      where
        mkSubtrace :: Value -> Maybe SubTrace
        mkSubtrace = parseMaybe parseJSON

    r_hasEKG repr = case (R.hasEKG repr) of
                       Nothing -> 0
                       Just p  -> p
    r_hasGraylog repr = case (R.hasGraylog repr) of
                       Nothing -> 0
                       Just p  -> p
    r_hasPrometheus repr = R.hasPrometheus repr
    r_hasGUI repr = case (R.hasGUI repr) of
                       Nothing -> 0
                       Just p  -> p
    r_forward repr = R.traceForwardTo repr
    r_accept repr = R.traceAcceptAt repr
    r_defaultScribes repr = map (\(k,n) -> pack(show k) <> "::" <> n) (R.defaultScribes repr)

parseAggregatedKindMap :: Maybe (HM.HashMap LoggerName Value) -> HM.HashMap LoggerName AggregatedKind
parseAggregatedKindMap Nothing    = HM.empty
parseAggregatedKindMap (Just hmv) = HM.mapMaybe mkAggregatedKind hmv
    where
    mkAggregatedKind :: Value -> Maybe AggregatedKind
    mkAggregatedKind (String s) = Just $ read $ unpack s
    mkAggregatedKind v = (parseMaybe parseJSON) v

\end{code}

\subsubsection{Setup empty configuration}
\begin{code}
empty :: IO Configuration
empty = do
    cgref <- newMVar $ ConfigurationInternal
                           { cgMinSeverity       = Debug
                           , cgDefRotation       = Nothing
                           , cgMapSeverity       = HM.empty
                           , cgMapSubtrace       = HM.empty
                           , cgMapSubtraceCache  = HM.empty
                           , cgOptions           = HM.empty
                           , cgMapBackend        = HM.empty
                           , cgMapBackendCache   = HM.empty
                           , cgDefBackendKs      = []
                           , cgSetupBackends     = []
                           , cgMapScribe         = HM.empty
                           , cgMapScribeCache    = HM.empty
                           , cgDefScribes        = []
                           , cgSetupScribes      = []
                           , cgMapAggregatedKind = HM.empty
                           , cgDefAggregatedKind = StatsAK
                           , cgMonitors          = HM.empty
                           , cgPortEKG           = 0
                           , cgPortGraylog       = 0
                           , cgBindAddrPrometheus = Nothing
                           , cgPortGUI           = 0
                           , cgForwardTo         = Nothing
                           , cgAcceptAt          = Nothing
                           }
    return $ Configuration cgref

\end{code}

\subsubsection{toRepresentation}\label{code:toRepresentation}\index{toRepresentation}
\begin{code}
toRepresentation :: Configuration -> IO R.Representation
toRepresentation (Configuration c) = do
    cfg <- readMVar c
    let portEKG = cgPortEKG cfg
        portGraylog = cgPortGraylog cfg
        portGUI = cgPortGUI cfg
        otherOptions = cgOptions cfg
        defScribes = cgDefScribes cfg
        splitScribeId :: ScribeId -> (ScribeKind, Text)
        splitScribeId x =
            -- "(ScribeId)" = "(ScribeKind) :: (Filename)"
            let (a,b) = T.breakOn "::" x
            in
                (read $ unpack a, T.drop 2 b)
        rekeyMapFromLoggerName :: HM.HashMap LoggerName a -> HM.HashMap Text a
        rekeyMapFromLoggerName = HM.fromList . fmap (loggerNameText *** id) . HM.toList
        createOption :: Text -> (a -> Value) -> HM.HashMap Text a -> HM.HashMap Text Value
        createOption name f hashmap =
          if null hashmap
          then HM.empty
          else HM.singleton name $ Object (HM.map f hashmap)
        toString :: Show a => a -> Value
        toString = String . pack . show
        toObject :: (MEvPreCond, MEvExpr, [MEvAction]) -> Value
        toObject (Nothing, expr, actions) =
            object [ "monitor" .= expr
                   , "actions" .= actions
                   ]
        toObject (Just precond, expr, actions) =
            object [ "monitor-if" .= precond
                   , "monitor"    .= expr
                   , "actions"    .= actions
                   ]
        toJSON' :: [ScribeId] -> Value
        toJSON' [sid] = toJSON sid
        toJSON' ss    = toJSON ss
        mapSeverities, mapBackends, mapAggKinds, mapScribes, mapSubtrace, mapMonitors ::
          HM.HashMap Text Value
        mapSeverities = createOption "mapSeverity"        toJSON
          $ rekeyMapFromLoggerName $ cgMapSeverity        cfg
        mapBackends   = createOption "mapBackends"        toJSON
          $ rekeyMapFromLoggerName $ cgMapBackend         cfg
        mapAggKinds   = createOption "mapAggregatedkinds" toString
          $ rekeyMapFromLoggerName $ cgMapAggregatedKind  cfg
        mapScribes    = createOption "mapScribes"         toJSON'
          $ rekeyMapFromLoggerName $ cgMapScribe          cfg
        mapSubtrace   = createOption "mapSubtrace"        toJSON
          $ rekeyMapFromLoggerName $ cgMapSubtrace        cfg
        mapMonitors   = createOption "mapMonitors"        toObject
          $ rekeyMapFromLoggerName $ cgMonitors           cfg

    return $
        R.Representation
            { R.minSeverity     = cgMinSeverity cfg
            , R.rotation        = cgDefRotation cfg
            , R.setupScribes    = cgSetupScribes cfg
            , R.defaultScribes  = map splitScribeId defScribes
            , R.setupBackends   = cgSetupBackends cfg
            , R.defaultBackends = cgDefBackendKs cfg
            , R.hasEKG          = if portEKG == 0 then Nothing else Just portEKG
            , R.hasGraylog      = if portGraylog == 0 then Nothing else Just portGraylog
            , R.hasPrometheus   = cgBindAddrPrometheus cfg
            , R.hasGUI          = if portGUI == 0 then Nothing else Just portGUI
            , R.traceForwardTo  = cgForwardTo cfg
            , R.traceAcceptAt   = cgAcceptAt cfg
            , R.options         = mapSeverities `HM.union`
                                  mapBackends   `HM.union`
                                  mapAggKinds   `HM.union`
                                  mapSubtrace   `HM.union`
                                  mapScribes    `HM.union`
                                  mapMonitors   `HM.union`
                                  otherOptions
            }

\end{code}

\subsubsection{Export |Configuration| into a file}\label{code:exportConfiguration}\index{exportConfiguration}
Converts |Configuration| into the form of |Representation| and writes it to
the given file.
\begin{code}
exportConfiguration :: Configuration -> FilePath -> IO ()
exportConfiguration cfg file = do
    representation <- toRepresentation cfg
    Yaml.encodeFile file representation

\end{code}

\subsubsection{Evaluation of |FilterTrace|}\label{code:evalFilters}\index{evalFilters}\label{code:testSubTrace}\index{testSubTrace}

A filter consists of a |DropName| and a list of |UnhideNames|. If the context name matches
the |DropName| filter, then at least one of the |UnhideNames| must match the name to have
the evaluation of the filters return |True|.

\begin{code}
findRootSubTrace :: Configuration -> LoggerName -> IO (Maybe SubTrace)
findRootSubTrace conf name = do
    cg <- readMVar $ getCG conf
    lookupHierarchyCached name
      (cgMapSubtrace cg)
      Nothing -- (cgMapSubtraceCache cg)
      Nothing
      (setCachedSubtrace conf)

setCachedSubtrace :: Configuration -> LoggerName -> Maybe SubTrace -> IO ()
setCachedSubtrace configuration name xs =
    modifyMVar_ (getCG configuration) $ \cg ->
        return cg { cgMapSubtraceCache = HM.alter (\_ -> xs) name (cgMapSubtraceCache cg) }

testSubTrace :: Configuration -> LoggerName -> LogObject a -> IO (Maybe (LogObject a))
testSubTrace config loggername lo = do
    subtrace <- fromMaybe Neutral <$> findRootSubTrace config loggername
    return $ testSubTrace' lo subtrace
  where
    testSubTrace' :: LogObject a -> SubTrace -> Maybe (LogObject a)
    testSubTrace' _ NoTrace = Nothing
    testSubTrace' (LogObject _ _ (ObserveOpen _)) DropOpening = Nothing
    testSubTrace' o@(LogObject _ _ (LogValue vname _)) (FilterTrace filters) =
        if evalFilters filters (loggername `consLoggerName` vname )
        then Just o
        else Nothing
    testSubTrace' o (FilterTrace filters) =
        if evalFilters filters loggername
        then Just o
        else Nothing
    testSubTrace' o (SetSeverity sev) = Just $ o{ loMeta = (loMeta o){ severity = sev } }
    testSubTrace' o _ = Just o -- fallback: all pass

evalFilters :: [(DropName, UnhideNames)] -> LoggerName -> Bool
evalFilters fs nm =
    all (\(no, yes) -> if (dropFilter nm no) then (unhideFilter nm yes) else True) fs
  where
    dropFilter :: LoggerName -> DropName -> Bool
    dropFilter name (Drop sel) = (matchName name sel)
    unhideFilter :: LoggerName -> UnhideNames -> Bool
    unhideFilter _ (Unhide []) = False
    unhideFilter name (Unhide us) = any (\sel -> matchName name sel) us
    matchName :: LoggerName -> NameSelector -> Bool
    matchName n (Exact name') = loggerNameText n == name'
    matchName n (StartsWith prefix) = T.isPrefixOf prefix (loggerNameText n)
    matchName n (EndsWith postfix) = T.isSuffixOf postfix (loggerNameText n)
    matchName n (Contains name') = T.isInfixOf name' (loggerNameText n)
\end{code}
