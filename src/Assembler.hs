{-# LANGUAGE BangPatterns #-}

module Assembler
(
  assemble,
  packBits,
  toBits
)
where

import Debug.Trace

import Common
import Parser
import Definitions
import Data.Word
import Data.Bits
import Data.Bool
import Data.List

import Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as HM

import Data.Maybe
import Data.Foldable
import Data.Monoid
import Control.Applicative
import Control.Monad
import Control.Monad.State.Strict

assemble :: [Line] -> Maybe [[Word8]]
assemble ls = runAssembler 0 mempty $ do
  firstPass ls
  resetAddress
  secondPass ls

type Address = Word32 -- | 1MB Address
type SymbolTable = HashMap String Address -- | Symbol table
type Assembler a = State (Address, SymbolTable) a -- | Assembler monad

-- | Run your assembler.
runAssembler :: Address -> SymbolTable -> Assembler a -> a
runAssembler a st ass = evalState ass (a, st)

-- | Get the current address.
address :: Assembler Address
address = fst <$> get

-- | Set the current address 
setAddress :: Address -> Assembler ()
setAddress addr = state $ \(_, st) -> ((), (addr, st))

-- | Set the current address to the start of the program.
-- Use this instead of @setAddress 0@ because 'Assembler'
-- may change to support START and END better.
resetAddress :: Assembler ()
resetAddress = setAddress 0

-- | Advance the current address by @by@
advanceAddress :: Address -> Assembler ()
advanceAddress by = address >>= setAddress . (+) by

-- | The symbol table.
symbolTable :: Assembler SymbolTable
symbolTable = snd <$> get

-- | Sets a symbol in the symbol table
setSymbol :: String -> Address -> Assembler ()
setSymbol sym a = state $ \(addr, st) -> ((), (addr, HM.insert sym a st))

-- | Gets a symbol from the symbol table
getSymbol :: String -> Assembler (Maybe Address)
getSymbol sym = HM.lookup sym <$> symbolTable

--
-- First Pass
--

-- | Does the first pass of assembly, finding all of
-- the labels and recording them in the symtab.
firstPass :: [Line] -> Assembler ()
firstPass xs = f xs
  where
    f [] = return ()
    f (l@(Line mlbl _ _):ls) = do
      case mlbl of
        Just lbl -> address >>= setSymbol lbl
        Nothing -> return ()
      ms <- sizeofLine l
      case ms of
        Just s -> advanceAddress s >> f ls
        Nothing -> return ()

--
-- Second Pass (High Level)
--

-- | Does the second pass of assembly, assembling
-- all of the lines of assembly code into object code 
secondPass :: [Line] -> Assembler (Maybe [[Word8]])
secondPass ls = sequence <$> mapM assembleLine ls

-- | Determine the format of a line of SIC/XE assembler.
lineFormat :: Line -> Assembler (Maybe Int)
lineFormat (Line _ (Mnemonic m extended) oprs) = maybe (return Nothing) f $ lookupMnemonic m
  where
    f = findM (valid oprs) . opdescFormats
    -- | @valid@ is a predicate that validates
    -- the line's operands with regard to the
    -- instruction format(s) dictated by the mnemonic. 
    valid []     1 = return True
    valid (x:xs) 2 = return $ and $ map (isJust . simpleToByte) (x:xs)
    valid (x:_)  3
      | extended = return False
      | reqAbs x = return True
      | otherwise = do
        addrc <- address
        addrx <- fromMaybe addrc <$> getAddr x
        let disp = (fromIntegral addrc) - (fromIntegral addrx)
        return $ disp >= -2048 || disp < 4096
    valid _      3 = return True
    valid _      4 = return True
    valid _      _ = return False

-- | Determine the size of a line (directive or instruction) of SIC/XE
-- assembler code without accessing the symbol table or assembling code.
sizeofLine :: Line -> Assembler (Maybe Word32)
sizeofLine l@(Line _ (Mnemonic m _) oprs) = do
  lf <- lineFormat l
  return $ (fromIntegral <$> lf) <|>  ds m oprs
  where
    ds :: String -> [Operand] -> Maybe Word32
    ds "BYTE" [Operand (Left v) OpImmediate] = Just $ fromIntegral $ length $ integerToBytes v
    ds "WORD" [Operand (Left v) OpSimple] = Just 3
    ds "RESB" [Operand (Left n) OpSimple] = Just $ fromIntegral n
    ds "RESW" [Operand (Left n) OpSimple] = Just $ 3 * (fromIntegral n)
    ds "START" [Operand (Left n) OpSimple] = Just $ fromIntegral n
    ds "END" _ = Just 0
    ds _ _ = Nothing

-- | Assembles a line of SIC/XE ASM as parsed by Parser.
-- Returns a list of bytes in Big Endian order and the next address.
assembleLine :: Line -> Assembler (Maybe [Word8])
assembleLine l@(Line _ (Mnemonic m _) oprs) = do
  lf <- lineFormat l
  g $ (,) <$> lf <*> lookupMnemonic m
  where
    g (Just (f, OpDesc opc _ _)) = mkinstr opc f oprs
    g Nothing                    = mkdirec m oprs
    mkinstr :: Word8 -> Int -> [Operand] -> Assembler (Maybe [Word8])
    mkinstr opc 1 _      = Just <$> format1 opc
    mkinstr opc 2 [a]    = mayapply (format2 opc) (simpleToByte a) (Just 0)
    mkinstr opc 2 [a, b] = mayapply (format2 opc) (simpleToByte a) (simpleToByte b)
    mkinstr opc 3 [a, b] = getAddr a >>= mayapply (format3 (reqAbs a) opc (getN a) (getI a)) (return $ getX a b)
    mkinstr opc 3 [a]    = getAddr a >>= mayapply (format3 (reqAbs a) opc (getN a) (getI a)) (return False)
    mkinstr opc 3 []     = Just <$> format3 True opc True True False 0
    mkinstr opc 4 [a, b] = getAddr a >>= mayapply (format4 opc (getN a) (getI a)) (return $ getX a b)
    mkinstr opc 4 [a]    = getAddr a >>= mayapply (format4 opc (getN a) (getI a)) (return False)
    mkinstr opc 4 []     = Just <$> format4 opc True True False 0
    mkdirec "BYTE" [Operand (Left v) OpImmediate] = Just <$> byte v
    mkdirec "WORD" [Operand (Left v) OpSimple] = Just <$> word v
    mkdirec "RESB" [Operand (Left n) OpSimple] = Just <$> resb (fromIntegral n)
    mkdirec "RESW" [Operand (Left n) OpSimple] = Just <$> resw (fromIntegral n)
    mkdirec "START" [Operand (Left n) OpSimple] = Just <$> start (fromIntegral n)
    mkdirec "END" _ = return $ Just []
    mkdirec a o = return $ Nothing

-- | Calculates the absolute address contained in an operand.
getAddr :: Operand -> Assembler (Maybe Address)
getAddr (Operand (Left s) _) = return $ Just $ fromIntegral s
getAddr (Operand (Right s) _) = getSymbol s
 
--
-- Helpers
--

-- | Determines if @operand@ is the index register.
isIndexingReg :: Operand -> Bool
isIndexingReg (Operand (Right v) OpSimple) = v == fst indexingRegister
isIndexingReg _ = False

-- | Determines if @operand@ should be absolute in format 3.
reqAbs :: Operand -> Bool
reqAbs (Operand (Left _) OpImmediate) = True
reqAbs _                              = False

-- | Determines if @operand@ is a given 'OperandType'
isType :: OperandType -> Operand -> Bool
isType t2 (Operand _ t) = t == t2

-- | DRY to calculate X of nixbpe.
getX :: Operand -> Operand -> Bool
getX a b = isIndexingReg b && isType OpSimple a

-- | DRY to calculate I of nixbpe
getI :: Operand -> Bool
getI a = isType OpImmediate a || isType OpSimple a

-- | DRY to calculate N of nixbpe
getN :: Operand -> Bool
getN a = isType OpIndirect a || isType OpSimple a

-- | Calculates the address displacement given
-- the start of the current instruction (@addr@)
-- and the offset to calc displacement for @memoff@
calcDisp :: Num a => a -> a -> a
calcDisp addr memoff = memoff - (addr + 3) -- +3 comes from the fact that displacement is only used with format 3 instructions

isPCRelative :: (Ord a, Num a) => a -> Bool
isPCRelative v = v >= -2048 && v < 2048

isBaseRelative :: (Ord a, Num a) => a -> Bool
isBaseRelative v = (not $ isPCRelative v) && v >= 0 && v < 4096

lookupMnemonic :: String -> Maybe OpDesc
lookupMnemonic m = find ((==) m . opdescMnemonic) operations

-- | Turns an operand into either a register code or its integral value.
simpleToByte :: Operand -> Maybe Word8
simpleToByte (Operand (Right ident) OpSimple) = lookup ident registers
simpleToByte (Operand (Left i) OpSimple) = Just $ fromIntegral i
simpleToByte _ = Nothing

--
-- Second Pass (Low Level)
--

-- | Assembles a 24-bit word constant
word :: Integer -> Assembler [Word8]
word i = do
  advanceAddress 3
  return $ packBits $ reverse $ take 24 $ toBits ((fromIntegral i) :: Word32)

-- | Assembles a binary constant
byte :: Integer -> Assembler [Word8]
byte bs = do
  advanceAddress $ fromIntegral $ length bs'
  return bs'
  where bs' = integerToBytes bs

-- | Reserve bytes of space.
resb :: Word32 -> Assembler [Word8]
resb i = do
  advanceAddress i
  return $ replicate (fromIntegral i) 0x0

-- | Reserve words of space.
resw :: Word32 -> Assembler [Word8]
resw = resb . (* 3)

-- | Start directive.
start :: Word32 -> Assembler [Word8]
start = resb

-- | Assembles a Format 1 instruction.
format1 :: Word8 -> Assembler [Word8]
format1 w = do
  advanceAddress 1
  return [w]

-- | Assembles a Format 2 instruction.
format2 :: Word8 -> Word8 -> Word8 -> Assembler [Word8]
format2 op rega regb = do
  advanceAddress 2
  return [op, shiftL rega 4 .|. regb]

-- | Assembles a Format 3 instruction.
format3 :: Bool -> Word8 -> Bool -> Bool -> Bool -> Word32 -> Assembler [Word8]
format3 absolute op n i x memoff = do
  addr <- address
  let (b, p) = getBP addr memoff absolute 
  if b || p || absolute
    then do
      advanceAddress 3 
      return $ getBytes b p addr
    else format4 op n i x memoff
  where
    getBytes b p addr = packBits $ prefix ++ dispBits 
      where
        disp = bool (calcDisp addr memoff) memoff absolute
        prefix = format34DRY op n i x b p False
        dispBits = reverse $ take 12 $ toBits disp
    getBP _ off True = (False, False)
    getBP addr off False = (b, p)
      where b = isBaseRelative $ calcDisp addr off
            p = isPCRelative $ calcDisp (fromIntegral addr) (fromIntegral off)

-- | Assembles a Format 4 instruction
format4 :: Word8 -> Bool -> Bool -> Bool -> Word32 -> Assembler [Word8]
format4 op n i x addr = do
  advanceAddress 4
  return $ packBits $ prefix ++ addrBits
  where
    prefix = format34DRY op n i x False False True
    addrBits = reverse $ take 20 $ toBits addr

format34DRY :: Word8 -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> [Bool]
format34DRY op n i x b p e = op' ++ [n, i, x, b, p, e]
  where op' = take 6 $ reverse $ toBits op

-- | Turns a @FiniteBits a@ into a list of bits in bit endian order, with no special ordering of bits.
-- 'toBits' is dedicated to Fritz Wiedmer, my grandfather (~1925 to 2016). During
-- his time at IBM, he designed Bubbles memory and ECC for keyboards. Fritz is the
-- reason I became fascinated with computer science.
toBits :: FiniteBits a => a -> [Bool]
toBits x = map (testBit x) [0..finiteBitSize x - 1]
--   where toBitIdx idx = uncurry (+) $ (7 - mod idx 8, div idx 8)

orderBits :: [Bool] -> [Bool]
orderBits [] = []
orderBits bs = reverse b' ++ orderBits bs'
  where (b', bs') = splitAt 8 bs

-- | Packs a list of bits into a big endian list of bytes
packBits :: [Bool] -> [Word8]
packBits = unfoldr f
  where
    f [] = Nothing
    f xs = Just (b, xs')
      where (bits, xs') = splitAt 8 xs
            indeces = [7,6,5,4,3,2,1,0]
            b = sum $ map (uncurry bit') $ zipWith (,) indeces $ fillTo 8 False bits
    bit' i True = bit i
    bit' i False = zeroBits
    fillTo n d xs = xs' ++ replicate (n - length xs') d
      where xs' = take n xs

