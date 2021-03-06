module Aiger where

import Literal
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.List as List
import Data.Array as Array
import Data.Array.Unboxed as UArray
import Data.Traversable
import Data.Bits
import Data.Maybe (catMaybes)

class AigerC a where
  aigerInputs :: a -> [Var]
  aigerLatches :: a -> [(Var,Bool,Var)]
  aigerOutputs :: a -> [Lit]
  aigerGates :: a -> [(Var,Var,Bool,Var,Bool)]
  getGate :: Var -> a -> (Var,Bool,Var,Bool)
  getLatch :: Var -> a -> (Var,Bool)
  getSymbol :: Var -> a -> Symbol
  getSymbolName :: Var -> a -> Maybe String

instance Literal lit => AigerC (Aiger lit) where
  aigerInputs x = fmap litVar (aigerInputs' x)
  aigerLatches x = [ (litVar l_from,litIsP l_to,litVar l_to) | (l_from,l_to) <- aigerLatches' x ]
  aigerOutputs = fmap (\x -> lit (litVar x) (litIsP x)) . aigerOutputs'
  aigerGates x = [ (litVar g,litVar g1,litIsP g1,litVar g2,litIsP g2) | (g,g1,g2) <- aigerGates' x ]
  getSymbol x aiger = if List.elem x (fmap litVar $ aigerInputs' aiger)
                      then Input
                      else (case List.find (\(latch,_) -> litVar latch==x) (aigerLatches' aiger) of
                               Just _ -> Latch
                               Nothing -> Gate)
  getGate gate aiger = case List.find (\(gt,_,_) -> litVar gt == gate) (aigerGates' aiger) of
    Just (_,in1,in2) -> (litVar in1,litIsP in1,litVar in2,litIsP in2)
  getLatch latch aiger = case List.find (\(latch',_) -> litVar latch' == latch) (aigerLatches' aiger) of
    Just (_,latch_from) -> (litVar latch_from,litIsP latch_from)
  getSymbolName gate aiger = case List.findIndex (\inp -> litVar inp == gate) (aigerInputs' aiger) of
    Just i -> case List.find (\(sym,n,_) -> sym==Input && n==i) (aigerSymbols aiger) of
      Just (_,_,name) -> Just name
      Nothing -> Nothing
    Nothing -> case List.findIndex (\(latch,_) -> litVar latch==gate) (aigerLatches' aiger) of
      Just i -> case List.find (\(sym,n,_) -> sym==Latch && n==i) (aigerSymbols aiger) of
        Just (_,_,name) -> Just name
        Nothing -> Nothing
      Nothing -> case List.findIndex (\outp -> litVar outp==gate) (aigerOutputs' aiger) of
        Just i -> case List.find (\(sym,n,_) -> sym==Output && n==i) (aigerSymbols aiger) of
          Just (_,_,name) -> Just name
          Nothing -> Nothing
        Nothing -> Nothing


instance AigerC OptimizedAiger where
  aigerInputs x = [Var i | i <- [0..(optAigerInputs x)-1]]
  aigerLatches x = [ (Var (i+(optAigerInputs x)),(latch .&. 1) == 0,Var $ latch `div` 2) | (i,latch) <- UArray.assocs (optAigerLatches x) ]
  aigerOutputs x = [ Lit v | v <- UArray.elems (optAigerOutputs x) ]
  aigerGates x = [ (Var g,Var $ g1 `div` 2,(g1 .&. 1)==0,Var $ g2 `div` 2,(g2 .&. 1)==0)
                 | ((g,g1),(_,g2)) <- zip (UArray.assocs (optAigerGatesLHS x)) (UArray.assocs (optAigerGatesRHS x)) ]
  getSymbol (Var gate) aiger = if gate < optAigerInputs aiger
                               then Input
                               else (if gate < (optAigerInputs aiger) + (snd $ UArray.bounds $ optAigerLatches aiger) + 1
                                     then Latch
                                     else Gate)
  getGate (Var gate) aiger = let idx = gate-(optAigerInputs aiger)-(snd $ UArray.bounds $ optAigerLatches aiger)-1
                                 in1 = (optAigerGatesLHS aiger) UArray.! idx
                                 in2 = (optAigerGatesRHS aiger) UArray.! idx
                             in (Var $ in1 `div` 2,(in1 .&. 1)==0,Var $ in2 `div` 2,(in2 .&. 1)==0)
  getLatch (Var latch) aiger = let idx = latch-(optAigerInputs aiger)
                                   latch_from = (optAigerLatches aiger) UArray.! idx
                               in (Var $ latch_from `div` 2,(latch_from .&. 1)==0)
  getSymbolName (Var gate) aiger = if gate < optAigerInputs aiger
                                   then Map.lookup gate (optAigerInputSymbols aiger)
                                   else (if gate < (optAigerInputs aiger) + (snd $ UArray.bounds $ optAigerLatches aiger) + 1
                                         then Map.lookup (gate-(optAigerInputs aiger)) (optAigerLatchSymbols aiger)
                                         else Map.lookup (gate-(optAigerInputs aiger)-(snd $ UArray.bounds $ optAigerLatches aiger)-1) (optAigerOutputSymbols aiger))

data Aiger lit = Aiger { aigerMaxVar :: lit
                       , aigerInputs' :: [lit]
                       , aigerLatches' :: [(lit,lit)]
                       , aigerOutputs' :: [lit]
                       , aigerGates' :: [(lit,lit,lit)]
                       , aigerSymbols :: [(Symbol,Int,String)]
                       , aigerComments :: [String]
                       } deriving (Show)

data OptimizedAiger = OptimizedAiger { optAigerInputs :: Int
                                     , optAigerLatches :: UArray Int Int
                                     , optAigerOutputs :: UArray Int Int
                                     , optAigerGatesLHS :: UArray Int Int
                                     , optAigerGatesRHS :: UArray Int Int
                                     , optAigerInputSymbols :: Map Int String
                                     , optAigerLatchSymbols :: Map Int String
                                     , optAigerOutputSymbols :: Map Int String
                                     } deriving (Show)

data Symbol = Input
            | Latch
            | Output
            | Gate
            | Unknown
            deriving (Show,Eq,Ord)

readAiger :: Read lit => String -> Aiger lit
readAiger str = case lines str of
  header:rest -> case words header of
    ("aag":max_var:n_inp:n_latch:n_outp:n_and:extras)
      -> let (inp_lines,rest1) = splitAt (read n_inp) rest
             (latch_lines,rest2) = splitAt (read n_latch) rest1
             (outp_lines,rest3) = splitAt (read n_outp) rest2
             (and_lines,rest4) = splitAt (read n_and) rest3
             rest5 = drop (sum $ fmap read extras) rest4
             (syms,comms) = parseSymbols rest5
         in Aiger { aigerMaxVar = read max_var
                  , aigerInputs' = [ read ln | ln <- inp_lines ]
                  , aigerLatches' = [ (read l1,read l2) | [l1,l2] <- fmap words latch_lines ]
                  , aigerOutputs' = [ read ln | ln <- outp_lines ]
                  , aigerGates' = [ (read l1,read l2,read l3) | [l1,l2,l3] <- fmap words and_lines ]
                  , aigerSymbols = syms
                  , aigerComments = comms
                  }
    ("aig":_) -> error "Binary aiger format not yet supported."
    _ -> error "Wrong header of aiger file."
  where
    parseSymbols :: [String] -> ([(Symbol,Int,String)],[String])
    parseSymbols [] = ([],[])
    parseSymbols (x:xs) = case x of
      "c" -> ([],xs)
      sym:rest -> let (num,_:name) = span (/=' ') rest
                      sym' = case sym of
                        'i' -> Input
                        'l' -> Latch
                        'o' -> Output
                        _ -> Unknown
                      (syms,comms) = parseSymbols xs
                  in ((sym',read num,name):syms,comms)

optimizeAiger :: (Show lit,Literal lit) => Aiger lit -> OptimizedAiger
optimizeAiger aiger = OptimizedAiger { optAigerInputs = n_inp
                                     , optAigerLatches = latches
                                     , optAigerOutputs = outps
                                     , optAigerGatesLHS = gatesL
                                     , optAigerGatesRHS = gatesR
                                     , optAigerInputSymbols = syms_inp
                                     , optAigerLatchSymbols = syms_latch
                                     , optAigerOutputSymbols = syms_outp
                                     }
  where
    (n_inp,mp1) = foldl (\(cn,cmp) lit -> (cn+1,Map.insert (litVar lit) cn cmp)) (0,Map.empty) (aigerInputs' aiger)
    ((n_latch,mp2),latch_entrs) = mapAccumL (\(i,cmp) (latch_to,latch_from) -> ((i+1,Map.insert (litVar latch_to) (i+n_inp) cmp),(i,case Map.lookup (litVar latch_from) mp_res of
                                                                                                                                     Just entr -> if litIsP latch_from
                                                                                                                                                  then entr*2
                                                                                                                                                  else entr*2+1
                                                                                                                                     Nothing -> error ("Latch origin "++show latch_from++" not found.")))
                                            ) (0,mp1) (aigerLatches' aiger)
    latches = UArray.array (0,n_latch-1) latch_entrs
    (n_outp,outp_entrs) = mapAccumL (\i outp -> case Map.lookup (litVar outp) mp_res of
                                        Just entr -> (i+1,Just (i,if litIsP outp
                                                                  then entr*2
                                                                  else entr*2+1))
                                        Nothing -> (i,Nothing)
                                    ) 0 (aigerOutputs' aiger)
    outps = UArray.array (0,n_outp-1) (catMaybes outp_entrs)
    ((n_gates,mp3),gate_entrs) = mapAccumL (\(i,cmp) (gate,g1,g2) -> ((i+1,Map.insert (litVar gate) (i+n_inp+n_latch) cmp),(i,case Map.lookup (litVar g1) mp_res of
                                                                                                                               Just g1' -> case Map.lookup (litVar g2) mp_res of
                                                                                                                                 Just g2' -> (if litIsP g1
                                                                                                                                              then g1'*2
                                                                                                                                              else g1'*2+1,
                                                                                                                                              if litIsP g2
                                                                                                                                              then g2'*2
                                                                                                                                              else g2'*2+1)))
                                           ) (0,mp2) (aigerGates' aiger)
    gatesL = UArray.array (0,n_gates-1) [ (i,l) | (i,(l,_)) <- gate_entrs ]
    gatesR = UArray.array (0,n_gates-1) [ (i,r) | (i,(_,r)) <- gate_entrs ]
    mp_res = mp3
    (syms_inp,syms_latch,syms_outp) = foldl (\(cinp,clatch,coutp) (sym,n,name) -> case sym of
                                                Input -> (Map.insert n name cinp,clatch,coutp)
                                                Latch -> (cinp,Map.insert n name clatch,coutp)
                                                Output -> (cinp,clatch,Map.insert n name coutp)
                                                Unknown -> (cinp,clatch,coutp)
                                            ) (Map.empty,Map.empty,Map.empty) (aigerSymbols aiger)

countUses :: AigerC aiger => aiger -> Map Var Int
countUses aiger = let inc key = Map.alter (\entr -> case entr of
                                              Nothing -> Just 1
                                              Just n -> Just (n+1)
                                          ) key
                      mp1 = foldl (\cmp (_,_,latch_from) -> inc latch_from cmp) Map.empty (aigerLatches aiger)
                      mp2 = foldl (\cmp outp -> inc (litVar outp) cmp) mp1 (aigerOutputs aiger)
                      mp3 = foldl (\cmp (_,in1,_,in2,_) -> if in1==in2
                                                           then inc in1 cmp
                                                           else inc in1 (inc in2 cmp)) mp2 (aigerGates aiger)
                  in mp3

isInput :: Literal lit => Var -> Aiger lit -> Bool
isInput var aiger = case List.find (\lit -> litVar lit == var) (aigerInputs' aiger) of
  Nothing -> False
  Just _ -> True
