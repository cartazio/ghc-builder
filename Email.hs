
module Email where

import Config
import Files
import SendMail
import ServerMonad
import Utils

import Control.Monad
import System.Exit
import System.FilePath

sendEmails :: User -> BuildNum -> IO ()
sendEmails u bn
 = do let buildsDir = baseDir </> "clients" </> u </> "builds"
          buildDir = buildsDir </> show bn
          stepsDir = buildDir </> "steps"
          root = Server (baseDir </> "clients") u
          mkStep bsn = do stepName <- readBuildStepName root bn bsn
                          ec <- readBuildStepExitcode root bn bsn
                          let res = case ec of
                                    ExitSuccess -> "Success"
                                    ExitFailure n -> "Failure: " ++ show n
                          return [stepName, res]
      bsns <- getSortedNumericDirectoryContents stepsDir
      steps <- mapM mkStep bsns
      result <- readBuildResult root bn
      let buildResult = case result of
                        Success -> "Build succeeded"
                        Failure -> "Build failed"
                        Incomplete -> "Build incomplete"
          description = u ++ ", build " ++ show bn
          bodyLines = [description,
                       "",
                       buildResult,
                       ""]
                   ++ showTable [rPad, noPad]
                                steps
                   ++ ["",
                       buildResult,
                       ""]
          subject = description
          body = unlines bodyLines
      unless (null emailAddresses) $
          sendMail fromAddress emailAddresses subject body Nothing []

