-- http://blog.stermon.com/articles/2018/08/13/haskell-safe-base64-only-depending-on-prelude.html
{-# LANGUAGE Safe #-}

--------------------------------------------------------------------------------

module Database.Persist.B64
  ( decode
  , encode
  ) where

--------------------------------------------------------------------------------

import           Data.Bits
    ( Bits
    , shiftL
    , shiftR
    , (.|.)
    )
import           Data.Maybe
    ( fromMaybe
    )
import           Data.Word
    ( Word8
    )

--------------------------------------------------------------------------------

type ByteString = [ Word8 ]

--------------------------------------------------------------------------------

-- Network Working Group                                       S. Josefsson
-- Request for Comments: 4648                                           SJD
-- Obsoletes: 3548                                             October 2006
-- Category: Standards Track
--
-- The Base16, Base32, and Base64 Data Encodings
--
-- https://tools.ietf.org/html/rfc4648
--
-- 9.  Illustrations and Examples
--
-- https://tools.ietf.org/html/rfc4648#section-9
--
-- To translate between binary and a base encoding, the input is stored
-- in a structure, and the output is extracted.  The case for base 64 is
-- displayed in the following figure, borrowed from [5].
--
--          +--first octet--+-second octet--+--third octet--+
--          |7 6 5 4 3 2 1 0|7 6 5 4 3 2 1 0|7 6 5 4 3 2 1 0|
--          +-----------+---+-------+-------+---+-----------+
--          |5 4 3 2 1 0|5 4 3 2 1 0|5 4 3 2 1 0|5 4 3 2 1 0|
--          +--1.index--+--2.index--+--3.index--+--4.index--+
--
-- The following example of Base64 data is from [5], with corrections.
--
--    Input data:  0x14fb9c03d97e
--    Hex:     1   4    f   b    9   c     | 0   3    d   9    7   e
--    8-bit:   00010100 11111011 10011100  | 00000011 11011001 01111110
--    6-bit:   000101 001111 101110 011100 | 000000 111101 100101 111110
--    Decimal: 5      15     46     28       0      61     37     62
--    Output:  F      P      u      c        A      9      l      +
--
--    Input data:  0x14fb9c03d9
--    Hex:     1   4    f   b    9   c     | 0   3    d   9
--    8-bit:   00010100 11111011 10011100  | 00000011 11011001
--                                                    pad with 00
--    6-bit:   000101 001111 101110 011100 | 000000 111101 100100
--    Decimal: 5      15     46     28       0      61     36
--                                                       pad with =
--    Output:  F      P      u      c        A      9      k      =
--
--    Input data:  0x14fb9c03
--    Hex:     1   4    f   b    9   c     | 0   3
--    8-bit:   00010100 11111011 10011100  | 00000011
--                                           pad with 0000
--    6-bit:   000101 001111 101110 011100 | 000000 110000
--    Decimal: 5      15     46     28       0      48
--                                                pad with =      =
--    Output:  F      P      u      c        A      w      =      =

encode :: ByteString -> ByteString
encode =
  aux . chunksOf 3
  where
    aux [    ] = [                ]
    aux (x:[]) = a : b : c : d : []
      where
        (a,b,c,d) = lst $ map Just x
    aux (x:xs) =
      tbl (a       .>. 2            ) :
      tbl (a .<. 6 .>. 2 .|. b .>. 4) :
      tbl (b .<. 4 .>. 2 .|. c .>. 6) :
      tbl (c .<. 2 .>. 2            ) :
      aux xs
      where
        (a:b:c:__) = x
    lst (a    :[]) = lst $ a:Nothing:Nothing:[]
    lst (a:b  :[]) = lst $ a:b      :Nothing:[]
    lst (a:b:c:[]) =
      (                               tbl $ a'       .>. 2
      ,                               tbl $ a' .<. 6 .>. 2 .|. b' .>. 4
      , if b == Nothing then pad else tbl $ b' .<. 4 .>. 2 .|. c' .>. 6
      , if c == Nothing then pad else tbl $ c' .<. 2 .>. 2
      )
      where
        a' = fromMaybe 0 a
        b' = fromMaybe 0 b
        c' = fromMaybe 0 c
    lst __________ = error "Shouldn't be possible (encode -> lst)"

decode :: ByteString -> ByteString
decode =
  aux . chunksOf 4
  where
    aux [    ] = []
    aux (x:[]) =
      case lst x of
        (a, Nothing, _______) -> a         : []
        (a, Just  b, Nothing) -> a : b     : []
        (a, Just  b, Just  c) -> a : b : c : []
    aux (x:xs) =
      (a .<. 2 .|. b .>. 4) :
      (b .<. 4 .|. c .>. 2) :
      (c .<. 6 .|. d      ) :
      aux xs
      where
        (a:b:c:d:__) = map idx x
    lst (a:b:c:d:[]) =
      (                                      (ai .<. 2 .|. bi .>. 4)
      , if c == pad then Nothing else Just $ (bi .<. 4 .|. ci .>. 2)
      , if d == pad then Nothing else Just $ (ci .<. 6 .|. di      )
      )
      where
        ai =                         idx a
        bi =                         idx b
        ci = if c == pad then 0 else idx c
        di = if d == pad then 0 else idx d
    lst __________ = error "Shouldn't be possible (decode -> lst)"

--------------------------------------------------------------------------------

-- Network Working Group                                       S. Josefsson
-- Request for Comments: 4648                                           SJD
-- Obsoletes: 3548                                             October 2006
-- Category: Standards Track
--
-- The Base16, Base32, and Base64 Data Encodings
--
-- https://tools.ietf.org/html/rfc4648
--
-- 4. Base 64 Encoding:
--
-- https://tools.ietf.org/html/rfc4648#section-4
--
-- Table 1: The Base 64 Alphabet

tbl :: Word8 -> Word8
tbl 00 = 065 -- 'A'
tbl 01 = 066 -- 'B'
tbl 02 = 067 -- 'C'
tbl 03 = 068 -- 'D'
tbl 04 = 069 -- 'E'
tbl 05 = 070 -- 'F'
tbl 06 = 071 -- 'G'
tbl 07 = 072 -- 'H'
tbl 08 = 073 -- 'I'
tbl 09 = 074 -- 'J'
tbl 10 = 075 -- 'K'
tbl 11 = 076 -- 'L'
tbl 12 = 077 -- 'M'
tbl 13 = 078 -- 'N'
tbl 14 = 079 -- 'O'
tbl 15 = 080 -- 'P'
tbl 16 = 081 -- 'Q'
tbl 17 = 082 -- 'R'
tbl 18 = 083 -- 'S'
tbl 19 = 084 -- 'T'
tbl 20 = 085 -- 'U'
tbl 21 = 086 -- 'V'
tbl 22 = 087 -- 'W'
tbl 23 = 088 -- 'X'
tbl 24 = 089 -- 'Y'
tbl 25 = 090 -- 'Z'
tbl 26 = 097 -- 'a'
tbl 27 = 098 -- 'b'
tbl 28 = 099 -- 'c'
tbl 29 = 100 -- 'd'
tbl 30 = 101 -- 'e'
tbl 31 = 102 -- 'f'
tbl 32 = 103 -- 'g'
tbl 33 = 104 -- 'h'
tbl 34 = 105 -- 'i'
tbl 35 = 106 -- 'j'
tbl 36 = 107 -- 'k'
tbl 37 = 108 -- 'l'
tbl 38 = 109 -- 'm'
tbl 39 = 110 -- 'n'
tbl 40 = 111 -- 'o'
tbl 41 = 112 -- 'p'
tbl 42 = 113 -- 'q'
tbl 43 = 114 -- 'r'
tbl 44 = 115 -- 's'
tbl 45 = 116 -- 't'
tbl 46 = 117 -- 'u'
tbl 47 = 118 -- 'v'
tbl 48 = 119 -- 'w'
tbl 49 = 120 -- 'x'
tbl 50 = 121 -- 'y'
tbl 51 = 122 -- 'z'
tbl 52 = 048 -- '0'
tbl 53 = 049 -- '1'
tbl 54 = 050 -- '2'
tbl 55 = 051 -- '3'
tbl 56 = 052 -- '4'
tbl 57 = 053 -- '5'
tbl 58 = 054 -- '6'
tbl 59 = 055 -- '7'
tbl 60 = 056 -- '8'
tbl 61 = 057 -- '9'
tbl 62 = 043 -- '+'
tbl 63 = 047 -- '/'
tbl __ = error "Shouldn't be possible (tbl)"

idx :: Word8 -> Word8
idx 065 = 00 -- 'A'
idx 066 = 01 -- 'B'
idx 067 = 02 -- 'C'
idx 068 = 03 -- 'D'
idx 069 = 04 -- 'E'
idx 070 = 05 -- 'F'
idx 071 = 06 -- 'G'
idx 072 = 07 -- 'H'
idx 073 = 08 -- 'I'
idx 074 = 09 -- 'J'
idx 075 = 10 -- 'K'
idx 076 = 11 -- 'L'
idx 077 = 12 -- 'M'
idx 078 = 13 -- 'N'
idx 079 = 14 -- 'O'
idx 080 = 15 -- 'P'
idx 081 = 16 -- 'Q'
idx 082 = 17 -- 'R'
idx 083 = 18 -- 'S'
idx 084 = 19 -- 'T'
idx 085 = 20 -- 'U'
idx 086 = 21 -- 'V'
idx 087 = 22 -- 'W'
idx 088 = 23 -- 'X'
idx 089 = 24 -- 'Y'
idx 090 = 25 -- 'Z'
idx 097 = 26 -- 'a'
idx 098 = 27 -- 'b'
idx 099 = 28 -- 'c'
idx 100 = 29 -- 'd'
idx 101 = 30 -- 'e'
idx 102 = 31 -- 'f'
idx 103 = 32 -- 'g'
idx 104 = 33 -- 'h'
idx 105 = 34 -- 'i'
idx 106 = 35 -- 'j'
idx 107 = 36 -- 'k'
idx 108 = 37 -- 'l'
idx 109 = 38 -- 'm'
idx 110 = 39 -- 'n'
idx 111 = 40 -- 'o'
idx 112 = 41 -- 'p'
idx 113 = 42 -- 'q'
idx 114 = 43 -- 'r'
idx 115 = 44 -- 's'
idx 116 = 45 -- 't'
idx 117 = 46 -- 'u'
idx 118 = 47 -- 'v'
idx 119 = 48 -- 'w'
idx 120 = 49 -- 'x'
idx 121 = 50 -- 'y'
idx 122 = 51 -- 'z'
idx 048 = 52 -- '0'
idx 049 = 53 -- '1'
idx 050 = 54 -- '2'
idx 051 = 55 -- '3'
idx 052 = 56 -- '4'
idx 053 = 57 -- '5'
idx 054 = 58 -- '6'
idx 055 = 59 -- '7'
idx 056 = 60 -- '8'
idx 057 = 61 -- '9'
idx 043 = 62 -- '+'
idx 047 = 63 -- '/'
idx ___ = error "Shouldn't be possible (idx)"

pad :: Word8
pad =
  61 -- '='

--------------------------------------------------------------------------------

-- HELPERS

(.<.) :: Bits a => a -> Int -> a
(.<.) x y = x `shiftL` y
(.>.) :: Bits a => a -> Int -> a
(.>.) x y = x `shiftR` y

chunksOf :: Int -> ByteString -> [ ByteString ]
chunksOf _ [] = [               ]
chunksOf n bs = x : chunksOf n xs
  where
    (x,xs) = splitAt n bs
