
{-# LANGUAGE PatternGuards, ForeignFunctionInterface #-}

module Main where

import Config
import ConfigHandler
import Files
import Handlelike
import Notification
import ServerMonad
import Utils

import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.Trans
import Data.Char
import Data.List
import Data.Maybe
import Data.Time.Format
import Data.Time.LocalTime
import Network.Socket
import OpenSSL
import OpenSSL.PEM
import OpenSSL.Session
import OpenSSL.X509
import Prelude hiding (catch)
import System.Directory
import System.Environment
import System.FilePath
import System.IO
import System.Locale
import System.Posix.Env
import System.Posix.Signals

main :: IO ()
main = do hSetBuffering stdout LineBuffering
          hSetBuffering stderr LineBuffering
          args <- getArgs
          case args of
              []              -> withSocketsDo $ withOpenSSL $ runServer Normal
              ["-v"]          -> withSocketsDo $ withOpenSSL $ runServer Verbose
              ["init"]        -> initServer
              ["add", client] -> addClient client
              _               -> die "Bad args"

initServer :: IO ()
initServer = do -- XXX We really ought to catch an already-exists
                -- exception and handle it properly
                createDirectory baseDir
                createDirectory (baseDir </> "clients")
                createDirectory (baseDir </> "web")
                createDirectory (baseDir </> "web" </> "builders")

addClient :: String -> IO ()
addClient client
 | null client = die "Null client name!"
 | not (isAlpha (head client)) = die "Bad client name"
 | not (all isOKChar client) = die "Bad client name"
 | otherwise = do -- XXX We really ought to catch an already-exists
                  -- exception and handle it properly
                  let clientDir = baseDir </> "clients" </> client
                  createDirectory clientDir
                  createDirectory (clientDir </> "builds")
                  writeToFile (clientDir </> "last_build_num_uploaded")
                              (0 :: BuildNum)
                  writeToFile (clientDir </> "last_build_num_allocated")
                              (0 :: BuildNum)
                  createDirectory (baseDir </> "web/builders" </> client)
                  putStrLn "OK, client added"
    where isOKChar c = isAlphaNum c || c == '-' || c == '_'

runServer :: Verbosity -> IO ()
runServer v =
    do notifierVar <- newEmptyMVar
       configHandlerVar <- newEmptyMVar
       persistentThread v "Notification" (notifier notifierVar)
       persistentThread v "Config handler" (configHandler configHandlerVar)
       installHandler sigHUP (Catch (gotSigHUP v configHandlerVar)) Nothing
       addrinfos <- getAddrInfo Nothing (Just "0.0.0.0") (Just (show port))
       let serveraddr = head addrinfos
       bracket (socket (addrFamily serveraddr) Stream defaultProtocol)
               sClose
               (listenForClients v notifierVar configHandlerVar serveraddr)

gotSigHUP :: Verbosity -> CHVar -> IO ()
gotSigHUP v chv = do verbose' v Main "Reloading config"
                     putMVar chv ReloadConfig

persistentThread :: Verbosity -> String -> IO () -> IO ()
persistentThread v title f
 = do let thread = f `catch` \e -> do verbose' v Notifier (exceptionMsg e)
                                      thread
      _ <- forkIO thread
      return ()
    where exceptionMsg e = unlines [title ++ " thread got an exception:",
                                    show (e :: SomeException),
                                    "Restarting..."]

listenForClients :: Verbosity -> NVar -> CHVar -> AddrInfo -> Socket -> IO ()
listenForClients v nv chv serveraddr sock
 = do bindSocket sock (addrAddress serveraddr)
      listen sock 1
      let mainLoop = do (conn, _) <- Network.Socket.accept sock
                        _ <- forkIO $ startSsl v conn nv chv
                        mainLoop
      mainLoop

fpServerPem :: FilePath
fpServerPem = "certs/server.pem"

fpRootPem :: FilePath
fpRootPem = "certs/root.pem"

startSsl :: Verbosity -> Socket -> NVar -> CHVar -> IO ()
startSsl v s nv chv
 = do msg <- hlGetLine' s
      verbose' v Unauthed ("Received: " ++ show msg)
      case msg of
          "START SSL" ->
              do serverPem <- readFile fpServerPem
                 serverX509 <- readX509 serverPem
                 serverPrivateKey <- readPrivateKey serverPem (PwStr "password")
                 sslContext <- context
                 contextSetCertificate sslContext serverX509
                 contextSetPrivateKey sslContext serverPrivateKey
                 contextSetCAFile sslContext fpRootPem
                 ssl <- OpenSSL.Session.connection sslContext s
                 OpenSSL.Session.accept ssl
                 mUser <- verifySsl ssl
                 sendHandle v ssl respOK "Welcome to SSL"
                 authClient v (Ssl ssl) nv chv mUser
          "NO SSL" ->
              do sendHandle v s respOK "OK, no SSL"
                 authClient v (Socket s) nv chv Nothing
          _ -> do sendHandle v s respHuh "Expected SSL instructions"
                  startSsl v s nv chv

verifySsl :: SSL -> IO (Maybe User)
verifySsl ssl
 = do verified <- getVerifyResult ssl
      unless verified $ die "Certificate doesn't verify"
      mPeerCert <- getPeerCertificate ssl
      case mPeerCert of
          Nothing ->
              -- XXX We're hitting this branch. Is that expected?
              -- die "No peer certificate"
              return Nothing
          Just peerCert ->
              do mapping <- getSubjectName peerCert False
                 case lookup "CN" mapping of
                     Just user ->
                         return (Just user)
                     Nothing ->
                         die "Certificate has no CN"

authClient :: Verbosity -> HandleOrSsl -> NVar -> CHVar -> Maybe User -> IO ()
authClient v h nv chv mu
 = do msg <- hlGetLine' h
      verbose' v Unauthed ("Received: " ++ show msg)
      case stripPrefix "AUTH " msg of
          Just xs ->
              case break (' ' ==) xs of
                  (user, ' ' : pass) ->
                      case lookup user clients of
                      Nothing ->
                          authFailed ("User " ++ show user ++ " unknown")
                      Just ui
                       | ui_password ui /= pass ->
                          authFailed "Wrong password"
                       | isJust mu && (Just user /= mu) ->
                          authFailed "User doesn't match SSL certificate CN"
                       | otherwise ->
                          do tod <- getTODinTZ (ui_timezone ui)
                             sendHandle v h respOK "authenticated"
                             let serverState = mkServerState
                                                   h user v nv chv tod
                             evalServerMonad handleClient serverState
                                 `finally`
                                 verbose' v (User user) "Disconnected"
                  _ ->
                      do sendHandle v h respHuh "I don't understand"
                         authClient v h nv chv mu
          Nothing ->
              case msg of
                  "HELP" ->
                      -- XXX
                      do sendHandle v h respHuh "I don't understand"
                         authClient v h nv chv mu
                  _ ->
                      do sendHandle v h respHuh "I don't understand"
                         authClient v h nv chv mu
    where authFailed reason = do verbose' v Unauthed ("Auth failed: " ++ reason)
                                 sendHandle v h respAuthFailed "auth failed"
                                 authClient v h nv chv mu

verbose :: String -> ServerMonad ()
verbose str = do v <- getVerbosity
                 u <- getUser
                 liftIO $ verbose' v (User u) str

verbose' :: Verbosity -> Who -> String -> IO ()
verbose' v w str
 = when (v >= Verbose) $
       do tod <- getTODinTZ "UTC"
          let fmt = "[%Y-%m-%d %H:%M:%S]"
              t = formatTime defaultTimeLocale fmt tod
          putStrLn (unwords [t, pprWho w, str])

data Who = User User | Unauthed | Notifier | Main

pprWho :: Who -> String
pprWho (User u) = "[U:" ++ u ++ "]"
pprWho Unauthed = "[unauthed]"
pprWho Notifier = "[notifier]"
pprWho Main     = "[main]"

sendHandle :: Handlelike h => Verbosity -> h -> Response -> String -> IO ()
sendHandle v h resp str
 = do let respStr = show resp ++ " " ++ str
      verbose' v Unauthed ("Sending: " ++ show respStr)
      hlPutStrLn' h respStr

sendClient :: Response -> String -> ServerMonad ()
sendClient resp str
 = do let respStr = show resp ++ " " ++ str
      verbose ("Sending: " ++ show respStr)
      hlPutStrLn respStr

handleClient :: ServerMonad ()
handleClient = do msg <- hlGetLine
                  verbose ("Received: " ++ show msg)
                  case msg of
                      -- XXX "HELP"
                      "BUILD INSTRUCTIONS" ->
                          withUserInfo answerBuildInstructions
                      "LAST UPLOADED" ->
                          answerLastUploaded
                      "RESET TIME" ->
                          withUserInfo answerResetTime
                      "READY" ->
                          withUserInfo answerReady
                      _
                       | Just xs <- stripPrefix "UPLOAD " msg,
                         (ys, ' ' : zs) <- break (' ' ==) xs,
                         Just buildNum <- maybeRead ys,
                         Just buildStepNum <- maybeRead zs ->
                          receiveBuildStep buildNum buildStepNum
                       | Just xs <- stripPrefix "RESULT " msg,
                         Just buildNum <- maybeRead xs ->
                          receiveBuildResult buildNum
                       | otherwise ->
                          sendClient respHuh "I don't understand"
                  handleClient

withUserInfo :: (UserInfo -> ServerMonad ()) -> ServerMonad ()
withUserInfo f
 = do mui <- getUserInfo
      case mui of
          Nothing ->
              sendClient respIForgotYou "I forgot you"
          Just ui ->
              f ui

answerBuildInstructions :: UserInfo -> ServerMonad ()
answerBuildInstructions ui
 = do sendClient respSendSizedThing "What sort?"
      instructions <- readSizedThing
      user <- getUser
      let lastBuildNumFile = baseDir </> "clients" </> user </> "last_build_num_allocated"
      lastBuildNum <- readFromFile lastBuildNumFile
      let thisBuildNum = lastBuildNum + 1
      writeToFile lastBuildNumFile thisBuildNum
      let bss = case instructions of
                StartBuild _ ->
                    ui_buildInstructions ui
                Idle ->
                    -- XXX The client did something odd if we get here
                    ui_buildInstructions ui
      sendClient respSizedThingFollows "Instructions follow"
      sendSizedThing $ mkBuildInstructions instructions thisBuildNum bss
      sendClient respOK "That's it"

answerLastUploaded :: ServerMonad ()
answerLastUploaded
 = do sendClient respSizedThingFollows "Build number follows"
      user <- getUser
      let lastBuildNumFile = baseDir </> "clients" </> user </> "last_build_num_uploaded"
      lastBuildNum <- readFromFile lastBuildNumFile
      sendSizedThing (lastBuildNum :: BuildNum)
      sendClient respOK "That's it"

answerResetTime :: UserInfo -> ServerMonad ()
answerResetTime ui = do let tz = ui_timezone ui
                        current <- getTODinTZ tz
                        setLastReadyTime current
                        sendClient respOK "Done"

answerReady :: UserInfo -> ServerMonad ()
answerReady ui
 = do let scheduled = ui_buildTime ui
      what <- case scheduled of
              Other why ->
                  return (StartBuild (Other why))
              Continuous ->
                  return (StartBuild Continuous)
              Timed tod ->
                  do prev <- getLastReadyTime
                     let tz = ui_timezone ui
                     current <- getTODinTZ tz
                     setLastReadyTime current
                     if scheduledTimePassed prev current tod
                         then return (StartBuild scheduled)
                         else return Idle
      sendClient respSizedThingFollows
                 "Your mission, should you choose to accept it, is to:"
      sendSizedThing what
      verbose ("Sent instructions: " ++ show what)
      sendClient respOK "Off you go"

receiveBuildStep :: BuildNum -> BuildStepNum -> ServerMonad ()
receiveBuildStep buildNum buildStepNum
 = do user <- getUser
      let root = Server (baseDir </> "clients") user
          userDir = baseDir </> "clients" </> user
          buildDir = userDir </> "builds" </> show buildNum
          stepsDir = buildDir </> "steps"
          buildStepDir = stepsDir </> show buildStepNum
      liftIO $ createDirectoryIfMissing False buildDir
      liftIO $ createDirectoryIfMissing False stepsDir
      liftIO $ createDirectoryIfMissing False buildStepDir
      -- Get the name
      sendClient respSendSizedThing "Send name"
      mname <- getMaybeSizedThing
      putMaybeBuildStepName root buildNum buildStepNum mname
      -- Get the subdir
      sendClient respSendSizedThing "Send subdir"
      msubdir <- getMaybeSizedThing
      putMaybeBuildStepSubdir root buildNum buildStepNum msubdir
      -- Get the program
      sendClient respSendSizedThing "Send program"
      mprog <- getMaybeSizedThing
      putMaybeBuildStepProg root buildNum buildStepNum mprog
      -- Get the args
      sendClient respSendSizedThing "Send args"
      margs <- getMaybeSizedThing
      putMaybeBuildStepArgs root buildNum buildStepNum margs
      -- Get the exit code
      sendClient respSendSizedThing "Send exit code"
      mec <- getMaybeSizedThing
      putMaybeBuildStepExitcode root buildNum buildStepNum mec
      -- Get the output
      sendClient respSendSizedThing "Send output"
      moutput <- getMaybeSizedThing
      putMaybeBuildStepOutput root buildNum buildStepNum moutput
      -- and tell the client that we're done, so it can delete its copy
      -- of the files
      sendClient respOK "Got it, thanks!"

receiveBuildResult :: BuildNum -> ServerMonad ()
receiveBuildResult buildNum
 = do user <- getUser
      let root = Server (baseDir </> "clients") user
          userDir = baseDir </> "clients" </> user
          buildDir = userDir </> "builds" </> show buildNum
      liftIO $ createDirectoryIfMissing False buildDir
      -- Get the result
      sendClient respSendSizedThing "Send instructions"
      minstrs <- getMaybeSizedThing
      putMaybeBuildInstructions root buildNum minstrs
      sendClient respSendSizedThing "Send result"
      mres <- getMaybeSizedThing
      putMaybeBuildResult root buildNum mres
      -- update the "last buildnum uploaded" record
      let lastFile = userDir </> "last_build_num_uploaded"
      l <- readFromFile lastFile
      when (buildNum > l) $ writeToFile lastFile buildNum
      -- and tell the client that we're done, so it can delete its copy
      -- of the files
      nv <- getNotifierVar
      liftIO $ putMVar nv (user, buildNum)
      sendClient respOK "Got it, thanks!"

mkBuildInstructions :: Instructions -> BuildNum -> [BuildStep] -> BuildInstructions
mkBuildInstructions instructions bn buildSteps
 = BuildInstructions {
       bi_instructions = instructions,
       bi_buildNum = bn,
       bi_buildSteps = zip [1..] buildSteps
   }

scheduledTimePassed :: TimeOfDay -> TimeOfDay -> TimeOfDay -> Bool
scheduledTimePassed lastTime curTime scheduledTime
      -- the simple case, where the time has passed:
    = ((lastTime < scheduledTime) && (scheduledTime <= curTime))
      -- the time has passed, but then the clock has wrapped:
   || ((lastTime < scheduledTime) && (curTime < lastTime))
      -- the clock has wrapped, then the time has passed:
   || ((scheduledTime <= curTime) && (curTime < lastTime))

-- getTODinTZ ought to be in Utils, but by putting it here we don't have
-- to worry about whether setEnv and tzset exist on the client platforms

getTODinTZ :: MonadIO m => String -> m TimeOfDay
getTODinTZ tz = do liftIO $ setEnv "TZ" tz True
                   liftIO tzset
                   t <- liftIO getZonedTime
                   return $ localTimeOfDay $ zonedTimeToLocalTime t

foreign import ccall "time.h tzset" tzset :: IO ()

