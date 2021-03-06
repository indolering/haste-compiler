{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances,
             GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | JS AST pretty printing monad.
module CodeGen.Javascript.PrettyM where
import qualified Data.Map as M
import CodeGen.Javascript.AST as AST
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State
import Control.Applicative
import Bag
import Data.Array

type Output = String

-- | Whitespace factory!
indent :: PrettyM a -> PrettyM a
indent printer = do
  opts <- ask
  let ind = indentLvl opts
      str = indentStr opts
  mapM_ out $ replicate ind str
  printer

-- | Indent the given pretty printer and terminate it with a newline.
line :: PrettyM a -> PrettyM a
line pp = do
  x <- indent pp
  endl
  return x

-- | Indent the given computation one level more than its parent computation.
indentFurther :: PrettyM a -> PrettyM a
indentFurther m =
  local oneMoreIndent m
  where
    oneMoreIndent opts = opts {indentLvl = indentLvl opts + indentStep opts}

-- | Options for the pretty printer
data PrettyOpts = PrettyOpts {
    indentLvl   :: Int,
    indentStep  :: Int,
    indentStr   :: Output,
    useNewline  :: Bool,
    printHeader :: Bool,
    extName     :: JSVar -> PrettyM JSLabel
  }

defaultOpts :: PrettyOpts
defaultOpts = PrettyOpts {
    indentLvl   = 0,
    indentStep  = 1,
    indentStr   = "    ",
    useNewline  = True,
    printHeader = True,
    extName     = realName
  }

-- | Print code using readable, but syntaxly incorrect, names, indentation,
--   newlines and dependency map header. Four spaces are used for indentation.
--   These settings produce the most readable code; it doesn't run though. Use
--   `pretty` for a compromise between readability and actually working.
pseudo :: PrettyOpts
pseudo = defaultOpts

-- | Like `pseudo`, except correct (but unreadable) names are used, the
--   dependency map header is not included and tabs are used for indentation
--   rather than spaces.
--   These settings produce code that actually works, unlike `pseudo`, but is
--   at least minimally readable, unlike `compact`.
pretty :: PrettyOpts
pretty = defaultOpts {
    extName     = append (commentExternal realName) genUnique,
    indentStr   = "\t",
    printHeader = False
  }

-- | Print code without indentation, newlines or any other readability
--   concerns, minimizing code size.
compact :: PrettyOpts
compact = defaultOpts {
    indentStep  = 0,
    indentStr   = "",
    useNewline  = False,
    extName     = genUnique,
    printHeader = False
  }

append :: (JSVar -> PrettyM JSLabel)
       -> (JSVar -> PrettyM JSLabel)
       -> JSVar
       -> PrettyM JSLabel
append back front var = do
  f <- front var
  b <- back var
  return $ f ++ b

comment :: (JSVar -> PrettyM JSLabel) -> JSVar -> PrettyM JSLabel
comment f var = do
  varName <- f var
  return $ "/*" ++ varName ++ "*/"

commentExternal :: (JSVar -> PrettyM JSLabel) -> JSVar -> PrettyM JSLabel
commentExternal f var = do
  varName <- f var
  case jsname var of
    External _ -> return $ "/*" ++ varName ++ "*/"
    _          -> return ""

realName :: JSVar -> PrettyM JSLabel
realName var =
  case jsname var of
    External n -> return $ jsmod var ++ "." ++ n
    Internal n -> return n
    Foreign n  -> return n

data VarStore = VarStore {
    next :: Int,
    vars :: M.Map JSVar Int
  }

emptyStore :: VarStore
emptyStore = VarStore {
    next = 0,
    vars = M.empty
  }

instance Monoid (Bag a) where
  mempty  = emptyBag
  mappend = unionBags

newtype PrettyM a = PM {
    unPretty :: StateT VarStore (WriterT (Bag Output) (Reader PrettyOpts)) a
  } deriving (Monad, Functor)

-- | Run a pretty printer using the given options.
runPretty :: PrettyOpts -> PrettyM a -> ((a, VarStore), Bag Output)
runPretty opts =
  flip runReader opts . runWriterT . flip runStateT emptyStore . unPretty

instance MonadReader PrettyOpts PrettyM where
  ask            = PM ask
  local f (PM m) = PM $ local f m

instance MonadWriter (Bag Output) PrettyM where
  tell   = PM . tell
  listen = PM . listen . unPretty
  pass   = PM . pass . unPretty

class PrettyJS a where
  emit :: a -> PrettyM ()

-- | Generate a unique ID for a var. If the var already exists, the ID it's
--   already got is returned.
genUnique :: JSVar -> PrettyM JSLabel
genUnique var = PM $ do
  VarStore nextID labels <- get
  case M.lookup var labels of
    Just n ->
      return $ idToLabel n
    _      -> do
      put $ VarStore (nextID+1) (M.insert var nextID labels)
      return $ idToLabel nextID

-- | Turn a var ID into a label.
idToLabel :: Int -> JSLabel
idToLabel 0     = "_0"
idToLabel varId = '_' : go varId ""
  where
    arrLen = 62
    chars = listArray (0,arrLen-1)
              $ "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    go 0 acc = acc
    go n acc = let (rest, ix) = n `quotRem` arrLen 
               in go rest ((chars ! ix) : acc)

-- | Emit a code fragment
out :: Output -> PrettyM ()
out = tell . unitBag

-- | Emit a newline
endl :: PrettyM ()
endl = do
  newl <- useNewline <$> ask
  if newl
    then out "\n"
    else return ()
