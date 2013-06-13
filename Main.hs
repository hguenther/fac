module Main where

import Control.Monad
import Control.Monad.State
import Minisat
import Data.IORef
import Data.Map as Map hiding (foldl)
import Foreign.C
import Formula
import Aiger
import Literal
import qualified Data.IntSet as IntSet

data ProofNode = ProofRoot Clause
               | ProofChain [ProofNode] [Var]
               deriving Show

data ProofBuilder = ProofBuilder { proofNodes :: Map CInt ProofNode
                                 , nextNode :: CInt }

proofBuilder :: ProofBuilder
proofBuilder = ProofBuilder Map.empty 0

proofBuilderRoot :: [Lit] -> ProofBuilder -> ProofBuilder
proofBuilderRoot lits builder = builder { proofNodes = Map.insert (nextNode builder) (ProofRoot $ Clause $ IntSet.fromList $ fmap litId lits) (proofNodes builder)
                                        , nextNode = succ (nextNode builder)
                                        }

proofBuilderChain :: [CInt] -> [Var] -> ProofBuilder -> ProofBuilder
proofBuilderChain cls vars builder = let cls' = fmap ((proofNodes builder)!) cls
                                     in builder { proofNodes = Map.insert (nextNode builder) (ProofChain cls' vars) (proofNodes builder)
                                                , nextNode = succ (nextNode builder)
                                                }

proofBuilderDelete :: CInt -> ProofBuilder -> ProofBuilder
proofBuilderDelete cl builder = builder { proofNodes = Map.delete cl (proofNodes builder) }

proofBuilderGet :: ProofBuilder -> ProofNode
proofBuilderGet builder = (proofNodes builder)!(pred $ nextNode builder)

proofVerify :: ProofNode -> Clause
proofVerify (ProofRoot cl) = cl
proofVerify (ProofChain cls vars)
  = Clause $ foldl (\cset var -> IntSet.delete (litId $ lp var) $
                                 IntSet.delete (litId $ ln var) $
                                 cset
                   ) (IntSet.unions $ fmap (\(Clause cl) -> cl) (fmap proofVerify cls)) vars

main = do
  --print $ toCNF (And (Atom 1) (Or (Atom 2) (Not $ And (Atom 3) (Atom 4)))) 5
  print $ evalState (toCNF (do
                               nxt <- get
                               put $ nxt { varId = succ (varId nxt) }
                               return nxt)
                     (Or (And (Atom 1) (Atom 2)) (And (Atom 3) (Atom 4)))) (Var 5)
  solv <- solverNew
  {-
 1  2 -3 0
-1 -2  3 0
 2  3 -4 0
-2 -3  4 0
 1  3  4 0
-1 -3 -4 0
-1  2  4 0
 1 -2 -4 0
-}
  builder <- newIORef proofBuilder
  solverAddProofLog solv
    (modifyIORef builder . proofBuilderRoot)
    (\cls vars -> modifyIORef builder $ proofBuilderChain cls vars)
    (modifyIORef builder . proofBuilderDelete)
    (putStrLn "Done!")
  vars@[v1,v2,v3,v4] <- replicateM 4 (solverNewVar solv)
  print vars
  mapM_ (\cl -> do
            --solverOk solv >>= print
            --print cl
            solverAddClause solv cl)
    [[lp v1,lp v2,ln v3]
    ,[ln v1,ln v2,lp v3]
    ,[lp v2,lp v3,ln v4]
    ,[ln v2,ln v3,lp v4]
    ,[lp v1,lp v3,lp v4]
    ,[ln v1,ln v3,ln v4]
    ,[ln v1,lp v2,lp v4]
    ,[lp v1,ln v2,ln v4]]
  solverSolve solv >>= print
  solverGetModel solv >>= print
  proof <- fmap proofBuilderGet (readIORef builder)
  print $ proofVerify proof