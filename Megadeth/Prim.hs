{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns    #-}
{-# LANGUAGE CPP             #-}
module Megadeth.Prim where

import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax

import           Control.Applicative
import           Control.Arrow
import           Control.Monad
import           Data.List

--import qualified Data.Text as T
import qualified Control.Monad.Trans.Class      as TC
import           Control.Monad.Trans.State.Lazy
import qualified Data.Graph                     as G
import qualified Data.Map.Strict                as M
import qualified Data.Set                       as S

-- TH 2.11 introduced kind type
#if MIN_VERSION_template_haskell(2,11,0)
#    define TH211MBKIND _maybe_kind
#else
#    define TH211MBKIND
#endif

-- | View Pattern for Types
data ConView = SimpleCon {nm :: Name, bf :: Integer, tt :: [Type]}

-- | Count 'how many times' a type is recursive to himself.
-- Used to make an arbitrary instance that reduce the size more accurate
countCons :: (Name -> Bool) -> Type -> Integer
countCons p ty =
  case ty of
    ForallT _ _ t  -> countCons p t
    AppT ty1 ty2   -> countCons p ty1 + countCons p ty2
    SigT t _       -> countCons p t
    ConT t         -> if p t then 1 else 0
    _              -> 0

varNames = map (('a':) . show) [0..]

paramNames :: [TyVarBndr] -> [Name]
paramNames = map f
  where f (PlainTV n) = n
        f (KindedTV n _) = n

applyTo :: TypeQ -> [TypeQ] -> TypeQ
applyTo = foldl appT

fixAppl :: Exp -> Exp
fixAppl (UInfixE e1@UInfixE {} op e2) = UInfixE (fixAppl e1) op e2
fixAppl (UInfixE con op e) = UInfixE con (VarE '(<$>)) e
fixAppl e = AppE (VarE 'return) e

-- | Look up  the first type name in a type structure.
-- This function is not complete, so it could fail and it will
-- with an error message with the case that is missing
headOf :: Type -> Name
headOf (AppT ListT ty) = headOf ty
headOf (AppT (TupleT _) ty) = headOf ty
headOf (AppT ArrowT e) = headOf e
headOf (AppT ty1 _) = headOf ty1
headOf (SigT ty _) = headOf ty
headOf (ConT n) = n
headOf (VarT n) = n
headOf e = error ("Missing :" ++ show e)

-- | Check whether a type is a Primitive Type.
-- Something like Int#, Bool#, etc.
isPrim :: Info -> Bool
isPrim PrimTyConI {} = True
isPrim _ = False

-- | View Pattern for Constructors
simpleConView :: Name -> Con -> ConView
simpleConView tyName c =
  let count = sum . map (countCons (== tyName))
  in case c of
  NormalC n sts -> let ts = map snd sts
                   in SimpleCon n (count ts) ts
#if MIN_VERSION_template_haskell(2,11,0)
  -- On ghc-8 the following source:
  --        data Keys a where
  --            Gamma       :: Keys Double
  --
  -- yields the following AST:
  --     GadtC [Codec.Picture.Metadata.Gamma] [] (AppT (ConT Codec.Picture.Metadata.Keys) (ConT GHC.Types.Double))
  -- Handle it exactly as NormalC.
  GadtC [n] sts _ -> let ts = map snd sts
                     in SimpleCon n (count ts) ts
#endif
  RecC n vsts   -> let ts = map proj3 vsts
                       proj3 (_,_,z) = z
                   in SimpleCon n (count ts) ts
  InfixC (_,t1) n (_,t2) ->
    SimpleCon n (countCons (== tyName) t1 + countCons (== tyName) t2) [t1,t2]
  ForallC _ _ innerCon -> simpleConView tyName innerCon
  _ -> error $ "simpleConView: failed on " ++ show c

-- | Get the first type in a type application.
-- Maybe we should improve this one
getTy :: Type -> Type
getTy (AppT t _) = getTy t
getTy t = t

isVarT (VarT _) = True
isVarT _ = False

-- | Find all simple Types that are part of another Type.
findLeafTypes :: Type -> [Type]
findLeafTypes (AppT ListT ty) = findLeafTypes ty
findLeafTypes (AppT (TupleT n) ty) = findLeafTypes ty
findLeafTypes (AppT p@(ConT _) ty) = p : findLeafTypes ty
findLeafTypes (AppT ty1 ty2) = findLeafTypes ty1 ++ findLeafTypes ty2
findLeafTypes (VarT _) = []
findLeafTypes (ForallT _ _ ty) = findLeafTypes ty
findLeafTypes ArrowT = []
findLeafTypes ListT = []
findLeafTypes StarT = []
findLeafTypes ty = [ty]

type StQ s a = StateT s Q a
type Names = [Name]

member :: Name -> StQ (M.Map Name Names) Bool
member t = do
    mk <- get
    return $ M.member t mk

addDep :: Name -> Names -> StQ (M.Map Name Names) ()
addDep n ns = do
    mapp <- get
    let newmapp = M.insert n ns mapp
    put newmapp

headOfNoVar :: Type -> [Name]
headOfNoVar (ConT n) = [n]
headOfNoVar (VarT _) = []
headOfNoVar (SigT t _ ) = headOfNoVar t
headOfNoVar (AppT ty1 ty2) = headOfNoVar ty1 ++ headOfNoVar ty2
headOfNoVar _ = []

getDeps :: Name -> (Name -> Q Bool) -> StQ (M.Map Name Names) ()
getDeps t ban = do
  visited <- member t
  b <- TC.lift $  ban t
  let cond = b || visited || hasArbIns t
  unless cond $
    do
      TC.lift $ runIO $ print $ "PreVisiting:" ++ show t
      tip <- TC.lift $ reify t
      TC.lift $ runIO $ print $ "Visiting: " ++ show tip
      case tip of
                    TyConI (DataD _ _ _ TH211MBKIND constructors _) -> do
                          let innerTypes = nub $ concat [ findLeafTypes ty | (simpleConView t -> SimpleCon _ _ tys) <- constructors, ty <- tys, not (isVarT ty) ]
                          let hof = foldr (\ x r ->
                                            case x of
                                                (TupleT 0) -> r
                                                x -> headOf x : r
                                ) [] innerTypes --map headOf innerTypes
                          addDep t hof
                          mapM_ getDeps' hof
                    TyConI (NewtypeD _ nm _ TH211MBKIND constructor _) -> do
                          let (SimpleCon _ 0 ts )= simpleConView nm constructor
                          let innerTypes = nub $ concatMap findLeafTypes $ filter (not . isVarT) ts
                          let hof = foldr (\ x r ->
                                            case x of
                                                (TupleT 0) -> r
                                                x -> headOf x : r
                                ) [] innerTypes --map headOf innerTypes
                          addDep t hof
                          mapM_ getDeps' hof
                    TyConI (TySynD _ _ m) -> do
                        addDep t (headOfNoVar m)
                        mapM_ getDeps' (headOfNoVar m)
                    d -> return ()
                        -- if (isPrim tip) then return () else return ()
    where
        getDeps' = flip getDeps $ ban


tocheck :: [TyVarBndr] -> Name -> Type
tocheck bndrs nm =
    let ns = map VarT $ paramNames bndrs in foldl AppT (ConT nm) ns

hasArbIns :: Name -> Bool
hasArbIns n = let sn = show n in
        isPrefixOf "GHC." sn
    ||  isPrefixOf "Data.Text" sn
    ||  isPrefixOf "Data.Vector" sn
    ||  isPrefixOf "Data.ByteString" sn
    ||  isPrefixOf "Codec.Picture.Types" sn
    ||  isPrefixOf "Codec.Picture.Metadata.Elem" sn
    ||  isPrefixOf "Codec.Picture.Metadata.Keys" sn
    ||  isPrefixOf "Data.Time" sn

doPreq :: Name -> Name -> [TyVarBndr] -> Q Bool
doPreq classname n [] = fmap not (isInstance classname [ConT n])
doPreq classname n xs = fmap not (isInstance classname [tocheck xs n])

isinsName :: Name -> Name -> Q Bool
isinsName className n = do
        inf <- reify n
        case inf of
            TyConI (DataD _ _ preq TH211MBKIND _ _) -> doPreq className n preq
            TyConI (NewtypeD _ _ preq TH211MBKIND _ _) -> doPreq className n preq
            TyConI (TySynD _ preq _ ) -> doPreq className n preq
            d -> do
                runIO $ print $ "Weird case:: " ++ show d
                doPreq className n []

prevDev :: Name -> (Name -> Q Bool) -> Q [Name]
prevDev t ban = do
        mapp <- execStateT (getDeps t ban) M.empty
        let rs = M.foldrWithKey (\ k d ds -> (k,k,d) : ds) [] mapp
        let (graph, v2ter, f) = G.graphFromEdges rs
        let topsorted = reverse $ G.topSort graph
        return (map (\p -> (let (n,_,_) = v2ter p in n)) topsorted)

megaderivePrim :: (Name -> Q [Dec]) -- ^ Instance generator
        -> (Name -> Q Bool) -- ^ Blacklist dependences before
        -> (Name -> Q Bool) -- ^ Instance name
        -> Name -> Q [Dec]
megaderivePrim inst prefil filt t = do
    ts' <- prevDev t prefil
    ts'' <- filterM filt ts' -- Remove already known instances
    ts <- mapM inst ts''
    return $ concat ts

megaderive :: (Name -> Q [Dec])
           -> (Name -> Q Bool) -- ^Instance name
           -> Name -> Q [Dec]
megaderive inst = megaderivePrim inst (const $ return False)
