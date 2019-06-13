{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
module Main (main) where

import           Control.Exception
import           Control.Lens
import           Control.Monad
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as BSC
import           Data.ElfEdit
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HMap
import           Data.List ((\\), nub, stripPrefix, intercalate)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Parameterized.Some
import           Data.Version
import           Numeric
import           System.Console.CmdArgs.Explicit
import           System.Environment (getArgs)
import           System.Exit (exitFailure)
import           System.IO
import           System.IO.Error
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (</>), (<>))

import           Data.Macaw.DebugLogging
import           Data.Macaw.Discovery
import           Data.Macaw.Memory
import           Data.Macaw.Memory.LoadCommon
import           Data.Macaw.X86

import           Reopt
import           Reopt.CFG.FnRep.X86 ()
import qualified Reopt.CFG.LLVM as LLVM
import qualified Reopt.CFG.LLVM.X86 as LLVM
import           Reopt.Header

import           Paths_reopt (version)

reoptVersion :: String
reoptVersion = "Reopt binary reoptimizer (reopt) "  ++ versionString ++ "."
  where [h,l,r] = versionBranch version
        versionString = show h ++ "." ++ show l ++ "." ++ show r


-- | Write a builder object to a file if defined or standard out if not.
writeOutput :: Maybe FilePath -> (Handle -> IO a) -> IO a
writeOutput Nothing f = f stdout
writeOutput (Just nm) f =
  bracket (openBinaryFile nm WriteMode) hClose f

------------------------------------------------------------------------
-- Utilities

unintercalate :: String -> String -> [String]
unintercalate punct str = reverse $ go [] "" str
  where
    go acc "" [] = acc
    go acc thisAcc [] = (reverse thisAcc) : acc
    go acc thisAcc str'@(x : xs)
      | Just sfx <- stripPrefix punct str' = go ((reverse thisAcc) : acc) "" sfx
      | otherwise = go acc (x : thisAcc) xs

-- | We'll use stderr to log error messages
logger :: String -> IO ()
logger = hPutStrLn stderr

------------------------------------------------------------------------
-- Action

-- | Action to perform when running
data Action
   = DumpDisassembly -- ^ Print out disassembler output only.
   | ShowCFG         -- ^ Print out control-flow microcode.
   | ShowFunctions   -- ^ Print out generated functions
   | ShowLLVM        -- ^ Print out LLVM in textual format
   | ShowObject      -- ^ Print out the object file.
   | ShowHelp        -- ^ Print out help message
   | ShowVersion     -- ^ Print out version
   | Reopt           -- ^ Perform a full reoptimization
  deriving (Show)

------------------------------------------------------------------------
-- Args

-- | Command line arguments.
data Args
   = Args { _reoptAction  :: !Action
          , programPath  :: !FilePath
            -- ^ Path to input program to optimize/export
          , _debugKeys    :: [DebugClass]
            -- Debug information ^ TODO: See if we can omit this.
          , outputPath   :: !(Maybe FilePath)
            -- ^ Path to output
            --
            -- Only used when reoptAction is @Relink@ and @Reopt@.
          , headerPath :: !(Maybe FilePath)
            -- ^ Filepath for C header file that helps provide
            -- information about program.
          , llvmVersion  :: !LLVMConfig
            -- ^ LLVM version to generate LLVM for.
            --
            -- Only used when generating LLVM.
          , optPath      :: !FilePath
            -- ^ Path to LLVM opt command.
            --
            -- Only used when generating LLVM to be optimized.
          , optLevel     :: !Int
            -- ^ Optimization level to pass to opt and llc
            --
            -- This defaults to 2
          , llcPath      :: !FilePath
            -- ^ Path to LLVM `llc` command
            --
            -- Only used when generating assembly file.
          , llvmMcPath      :: !FilePath
            -- ^ Path to llvm-mc
            --
            -- Only used when generating object file from assembly generated by llc.
          , _includeAddrs   :: ![String]
            -- ^ List of entry points for translation
          , _excludeAddrs :: ![String]
            -- ^ List of function entry points that we exclude for translation.
          , _loadOpts :: !LoadOptions
            -- ^ Options affecting initial memory construction
          , _discOpts :: !DiscoveryOptions
            -- ^ Options affecting discovery
          , unnamedFunPrefix :: !BS.ByteString
            -- ^ Prefix for unnamed functions
          }

-- | Action to perform when running
reoptAction :: Simple Lens Args Action
reoptAction = lens _reoptAction (\s v -> s { _reoptAction = v })

-- | Which debug keys (if any) to output
debugKeys :: Simple Lens Args [DebugClass]
debugKeys = lens _debugKeys (\s v -> s { _debugKeys = v })

-- | Function entry points to translate (overrides notrans if non-empty)
includeAddrs :: Simple Lens Args [String]
includeAddrs = lens _includeAddrs (\s v -> s { _includeAddrs = v })

-- | Function entry points that we exclude for translation.
excludeAddrs :: Simple Lens Args [String]
excludeAddrs = lens _excludeAddrs (\s v -> s { _excludeAddrs = v })

-- | Options for controlling loading binaries to memory.
loadOpts :: Simple Lens Args LoadOptions
loadOpts = lens _loadOpts (\s v -> s { _loadOpts = v })

-- | Options for controlling discovery
discOpts :: Simple Lens Args DiscoveryOptions
discOpts = lens _discOpts (\s v -> s { _discOpts = v })

-- | Initial arguments if nothing is specified.
defaultArgs :: Args
defaultArgs = Args { _reoptAction = Reopt
                   , programPath = ""
                   , _debugKeys = []
                   , outputPath = Nothing
                   , headerPath = Nothing
                   , llvmVersion = latestLLVMConfig
                   , optPath = "opt"
                   , optLevel  = 2
                   , llcPath = "llc"
                   , llvmMcPath = "llvm-mc"
                   , _includeAddrs = []
                   , _excludeAddrs  = []
                   , _loadOpts     = defaultLoadOptions
                   , _discOpts     = defaultDiscoveryOptions
                   , unnamedFunPrefix = "reopt"
                   }

------------------------------------------------------------------------
-- Loading flags

resolveHex :: String -> Maybe Integer
resolveHex ('0':'x':wval) | [(w,"")] <- readHex wval = Just w
resolveHex ('0':'X':wval) | [(w,"")] <- readHex wval = Just w
resolveHex _ = Nothing

-- | Define a flag that forces the region index to 0 and adjusts
-- the base pointer address.
--
-- Primarily used for loading shared libraries at a fixed address.
loadForceAbsoluteFlag :: Flag Args
loadForceAbsoluteFlag = flagReq [ "force-absolute" ] upd "OFFSET" help
  where help = "Load a relocatable file at a fixed offset."
        upd :: String -> Args -> Either String Args
        upd val args =
          case resolveHex val of
            Just off -> Right $
               args & loadOpts %~ \opt -> opt { loadRegionIndex = Just 0
                                              , loadRegionBaseOffset = off
                                              }
            Nothing -> Left $
              "Expected a hexadecimal address of form '0x???', passsed "
              ++ show val

------------------------------------------------------------------------
-- Other Flags

disassembleFlag :: Flag Args
disassembleFlag = flagNone [ "disassemble", "d" ] upd help
  where upd  = reoptAction .~ DumpDisassembly
        help = "Show raw disassembler output."

cfgFlag :: Flag Args
cfgFlag = flagNone [ "c", "cfg" ] upd help
  where upd  = reoptAction .~ ShowCFG
        help = "Show recovered control-flow graphs."

funFlag :: Flag Args
funFlag = flagNone [ "fns", "functions" ] upd help
  where upd  = reoptAction .~ ShowFunctions
        help = "Show recovered functions."

llvmFlag :: Flag Args
llvmFlag = flagNone [ "llvm" ] upd help
  where upd  = reoptAction .~ ShowLLVM
        help = "Show generated LLVM."

objFlag :: Flag Args
objFlag = flagNone [ "object" ] upd help
  where upd  = reoptAction .~ ShowObject
        help = "Write recompiled object code to output file."

outputFlag :: Flag Args
outputFlag = flagReq [ "o", "output" ] upd "PATH" help
  where upd s old = Right $ old { outputPath = Just s }
        help = "Path to write new binary."

headerFlag :: Flag Args
headerFlag = flagReq [ "header" ] upd "PATH" help
  where upd s old = Right $ old { headerPath = Just s }
        help = "Optional header with function declarations."

llvmVersionFlag :: Flag Args
llvmVersionFlag = flagReq [ "llvm-version" ] upd "VERSION" help
  where upd :: String -> Args -> Either String Args
        upd s old = do
          v <- case versionOfString s of
                 Just v -> Right v
                 Nothing -> Left $ "Could not interpret LLVM version."
          cfg <- case getLLVMConfig v of
                   Just c -> pure c
                   Nothing -> Left $ "Unsupported LLVM version " ++ show s ++ "."
          pure $ old { llvmVersion = cfg }

        help = "LLVM version (e.g. 3.5.2)"


parseDebugFlags ::  [DebugClass] -> String -> Either String [DebugClass]
parseDebugFlags oldKeys cl =
  case cl of
    '-' : cl' -> do ks <- getKeys cl'
                    return (oldKeys \\ ks)
    cl'       -> do ks <- getKeys cl'
                    return (nub $ oldKeys ++ ks)
  where
    getKeys "all" = Right allDebugKeys
    getKeys str = case parseDebugKey str of
                    Nothing -> Left $ "Unknown debug key `" ++ str ++ "'"
                    Just k  -> Right [k]

debugFlag :: Flag Args
debugFlag = flagOpt "all" [ "debug", "D" ] upd "FLAGS" help
  where upd s old = do let ks = unintercalate "," s
                       new <- foldM parseDebugFlags (old ^. debugKeys) ks
                       Right $ (debugKeys .~ new) old
        help = "Debug keys to enable.  This flag may be used multiple times, "
            ++ "with comma-separated keys.  Keys may be preceded by a '-' which "
            ++ "means disable that key.\n"
            ++ "Supported keys: all, " ++ intercalate ", " (map debugKeyName allDebugKeys)



-- | Flag to set path to opt.
optPathFlag :: Flag Args
optPathFlag = flagReq [ "opt" ] upd "PATH" help
  where upd s old = Right $ old { optPath = s }
        help = "Path to LLVM \"opt\" command for optimization."

-- | Flag to set llc path.
llcPathFlag :: Flag Args
llcPathFlag = flagReq [ "llc" ] upd "PATH" help
  where upd s old = Right $ old { llcPath = s }
        help = "Path to LLVM \"llc\" command for compiling LLVM to native assembly."

-- | Flag to set path to llvm-mc
llvmMcPathFlag :: Flag Args
llvmMcPathFlag = flagReq [ "llvm-mc" ] upd "PATH" help
  where upd s old = Right $ old { llvmMcPath = s }
        help = "Path to llvm-mc"

-- | Flag to set llc optimization level.
optLevelFlag :: Flag Args
optLevelFlag = flagReq [ "O", "opt-level" ] upd "PATH" help
  where upd s old =
          case reads s of
            [(lvl, "")] | 0 <= lvl && lvl <= 3 -> Right $ old { optLevel = lvl }
            _ -> Left "Expected optimization level to be a number between 0 and 3."
        help = "Optimization level."

-- | Used to add a new function to ignore translation of.
includeAddrFlag :: Flag Args
includeAddrFlag = flagReq [ "include" ] upd "ADDR" help
  where upd s old = Right $ old & includeAddrs %~ (s:)
        help = "Address of function to include in analysis (may be repeated)."

-- | Used to add a new function to ignore translation of.
excludeAddrFlag :: Flag Args
excludeAddrFlag = flagReq [ "exclude" ] upd "ADDR" help
  where upd s old = Right $ old & excludeAddrs %~ (s:)
        help = "Address of function to exclude in analysis (may be repeated)."

-- | Print out a trace message when we analyze a function
logAtAnalyzeFunctionFlag :: Flag Args
logAtAnalyzeFunctionFlag = flagBool [ "trace-function-discovery" ] upd help
  where upd b = discOpts %~ \o -> o { logAtAnalyzeFunction = b }
        help = "Report when starting analysis of each function."

-- | Print out a trace message when we analyze a function
logAtAnalyzeBlockFlag :: Flag Args
logAtAnalyzeBlockFlag = flagBool [ "trace-block-discovery" ] upd help
  where upd b = discOpts %~ \o -> o { logAtAnalyzeBlock = b }
        help = "Report when starting analysis of each basic block with a function."

exploreFunctionSymbolsFlag :: Flag Args
exploreFunctionSymbolsFlag = flagBool [ "include-syms" ] upd help
  where upd b = discOpts %~ \o -> o { exploreFunctionSymbols = b }
        help = "Include function symbols in discovery."

exploreCodeAddrInMemFlag :: Flag Args
exploreCodeAddrInMemFlag = flagBool [ "include-mem" ] upd help
  where upd b = discOpts %~ \o -> o { exploreCodeAddrInMem = b }
        help = "Include memory code addresses in discovery."

arguments :: Mode Args
arguments = mode "reopt" defaultArgs help filenameArg flags
  where help = reoptVersion ++ "\n" ++ copyrightNotice
        flags = [ -- General purpose options
                  flagHelpSimple (reoptAction .~ ShowHelp)
                , flagVersion (reoptAction .~ ShowVersion)
                , debugFlag
                  -- Redirect output to file.
                , outputFlag
                  -- Explicit Modes
                , disassembleFlag
                , cfgFlag
                , funFlag
                , llvmFlag
                , objFlag
                  -- Discovery options
                , logAtAnalyzeFunctionFlag
                , logAtAnalyzeBlockFlag
                , exploreFunctionSymbolsFlag
                , exploreCodeAddrInMemFlag
                , includeAddrFlag
                , excludeAddrFlag
                  -- Function options
                , headerFlag
                  -- Loading options
                , loadForceAbsoluteFlag
                  -- LLVM options
                , llvmVersionFlag
                  -- Compilation options
                , optLevelFlag
                , optPathFlag
                , llcPathFlag
                , llvmMcPathFlag
                ]

-- | Flag to set the path to the binary to analyze.
filenameArg :: Arg Args
filenameArg = Arg { argValue = setFilename
                  , argType = "FILE"
                  , argRequire = False
                  }
  where setFilename :: String -> Args -> Either String Args
        setFilename nm a = Right (a { programPath = nm })

getCommandLineArgs :: IO Args
getCommandLineArgs = do
  argStrings <- getArgs
  case process arguments argStrings of
    Left msg -> do
      logger msg
      exitFailure
    Right v -> return v


-- | Print out the disassembly of all executable sections.
--
-- Note.  This does not apply relocations.
dumpDisassembly :: Args -> IO ()
dumpDisassembly args = do
  bs <- checkedReadFile (programPath args)
  e <- parseElf64 (programPath args) bs
  let sections = filter isCodeSection $ e^..elfSections
  when (null sections) $ do
    hPutStrLn stderr "Binary contains no executable sections."
    exitFailure
  writeOutput (outputPath args) $ \h -> do
    forM_ sections $ \s -> do
      printX86SectionDisassembly h (elfSectionName s) (elfSectionAddr s) (elfSectionData s)

-- | Discovery symbols in program and show function CFGs.
showCFG :: Args -> IO String
showCFG args = do
  Some discState <-
    discoverBinary (programPath args) (args^.loadOpts) (args^.discOpts) (args^.includeAddrs) (args^.excludeAddrs)
  pure $ show $ ppDiscoveryStateBlocks discState

resolveHeader :: Args -> IO Header
resolveHeader args =
  case headerPath args of
    Nothing -> pure emptyHeader
    Just p -> parseHeader p

-- | Parse arguments to get information needed for function representation.
getFunctions :: Args
             -> IO ( X86OS
                   , RecoveredModule X86_64
                   )
getFunctions args = do
  hdr <- resolveHeader args
  (os, discState, addrSymMap, symAddrMap) <-
    discoverX86Binary (programPath args) (args^.loadOpts) (args^.discOpts) (args^.includeAddrs) (args^.excludeAddrs)
  let symAddrHashMap :: HashMap BSC.ByteString (MemSegmentOff 64)
      symAddrHashMap = HMap.fromList [ (nm,addr) | (nm,addr) <- Map.toList symAddrMap ]
  recMod <- getFns logger addrSymMap symAddrHashMap hdr (unnamedFunPrefix args)
                   (osPersonality os) discState
  pure (os, recMod)

-- | Write out functions discovered.
showFunctions :: Args -> IO ()
showFunctions args = do
  (_,recMod) <- getFunctions args
  writeOutput (outputPath args) $ \h -> do
    mapM_ (hPutStrLn h . show . pretty) (recoveredDefs recMod)


------------------------------------------------------------------------
--

-- | This command is called when reopt is called with no specific
-- action.
performReopt :: Args -> IO ()
performReopt args = do
  hdr <- resolveHeader args
  let funPrefix :: BSC.ByteString
      funPrefix = unnamedFunPrefix args
  (origElf, os, discState, addrSymMap, symAddrMap) <-
    discoverX86Elf (programPath args)
                   (args^.loadOpts)
                   (args^.discOpts)
                   (args^.includeAddrs)
                   (args^.excludeAddrs)
  let symAddrHashMap :: HashMap BSC.ByteString (MemSegmentOff 64)
      symAddrHashMap = HMap.fromList [ (nm,addr) | (nm,addr) <- Map.toList symAddrMap ]
  recMod <- getFns logger addrSymMap symAddrHashMap hdr funPrefix (osPersonality os) discState
  let llvmVer = llvmVersion args
  let archOps = LLVM.x86LLVMArchOps (show os)
  let obj_llvm = llvmAssembly llvmVer $ LLVM.moduleForFunctions archOps recMod
  objContents <-
    compileLLVM (optLevel args) (optPath args) (llcPath args) (llvmMcPath args) (osLinkName os) obj_llvm

  new_obj <- parseElf64 "new object" objContents
  -- Convert binary to LLVM
  let tgts = discoveryControlFlowTargets discState
      redirs = addrRedirection tgts addrSymMap funPrefix <$> recoveredDefs recMod
  -- Merge and write out
  putStrLn $ "Performing final relinking."
  let outPath = fromMaybe "a.out" (outputPath args)
  mergeAndWrite outPath origElf new_obj redirs

main' :: IO ()
main' = do
  args <- getCommandLineArgs
  setDebugKeys (args ^. debugKeys)
  case args^.reoptAction of
    DumpDisassembly -> do
      dumpDisassembly args
    ShowCFG ->
      writeOutput (outputPath args) $ \h -> do
        hPutStrLn h =<< showCFG args
    ShowFunctions -> do
      showFunctions args
    ShowLLVM -> do
      hPutStrLn stderr "Generating LLVM"
      (os,recMod) <- getFunctions args
      let archOps = LLVM.x86LLVMArchOps (show os)
      writeOutput (outputPath args) $ \h -> do
        Builder.hPutBuilder h $
          llvmAssembly (llvmVersion args) $ LLVM.moduleForFunctions archOps recMod
    ShowObject -> do
      outPath <-
        case outputPath args of
          Nothing -> do
            hPutStrLn stderr "Please specify output path for object."
            exitFailure
          Just p ->
            pure p
      (os,recMod) <- getFunctions args
      let llvmVer = llvmVersion args
      let archOps = LLVM.x86LLVMArchOps (show os)
      let obj_llvm =
            llvmAssembly llvmVer $
              LLVM.moduleForFunctions archOps recMod
      objContents <- compileLLVM (optLevel args) (optPath args) (llcPath args) (llvmMcPath args) (osLinkName os) obj_llvm
      BS.writeFile outPath objContents
    ShowHelp -> do
      print $ helpText [] HelpFormatAll arguments
    ShowVersion ->
      putStrLn (modeHelp arguments)
    Reopt -> do
      performReopt args

main :: IO ()
main = main' `catch` h
  where h e
          | isUserError e = do
            hPutStrLn stderr "User error"
            hPutStrLn stderr $ ioeGetErrorString e
          | otherwise = do
            hPutStrLn stderr "Other error"
            hPutStrLn stderr $ show e
            hPutStrLn stderr $ show (ioeGetErrorType e)
