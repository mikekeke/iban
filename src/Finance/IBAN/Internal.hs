{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}
module Finance.IBAN.Internal
  ( IBAN(..)
  , IBANError(..)
  , parseIBAN
  , prettyIBAN
  , SElement
  , country
  , checkStructure
--  , parseStructure
--  , countryStructures
  , mod97_10
  ) where

import           Control.Arrow (left)
import           Data.Char (digitToInt, isDigit, isAsciiLower, isAsciiUpper, toUpper)
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.ISO3166_CountryCodes (CountryCode)
import           Data.List (foldl')
import           Data.Maybe (isNothing)
import           Data.String (IsString, fromString)
import           Data.Text (Text, unpack)
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import qualified Finance.IBAN.Data as Data
import           Text.Read (Lexeme(Ident), Read(readPrec), parens, prec, readMaybe, readPrec, lexP)
import Control.Monad ((>=>))
import Debug.Trace (traceShowId)
import Data.Function ((&))
import Data.Attoparsec.Text as P
import Finance.IBAN.Data (toElemP)
import Finance.IBAN.Data (countryP)

newtype IBAN = IBAN {rawIBAN :: Text}
  deriving (Eq, Typeable)

instance IsString IBAN where
    fromString iban = either (error . show) id $ parseIBAN $ T.pack iban

instance Show IBAN where
    showsPrec p iban = showParen (p>10) $
        showString "fromString " . shows (prettyIBAN iban)

instance Read IBAN where
    readPrec = parens $ prec 10 $ do
        Ident "fromString" <- lexP
        fromString <$> readPrec

-- | Get the country of the IBAN
country :: IBAN -> CountryCode
country = either err id . countryEither . rawIBAN
  where err = const $ error "IBAN.country: internal inconsistency"

-- | Parse the Country from a text IBAN
countryEither :: Text -> Either Text CountryCode
countryEither s = readNote' s $ T.take 2 s

data IBANError =
    IBANError1 Text
  | IBANInvalidCharacters   -- ^ The IBAN string contains invalid characters.
  | IBANInvalidStructure    -- ^ The IBAN string has the wrong structure.
  | IBANWrongChecksum       -- ^ The checksum does not match.
  | IBANInvalidCountry Text -- ^ The country identifier is either not a
                            --   valid ISO3166-1 identifier or that country
                            --   does not issue IBANs.
  deriving (Show, Read, Eq, Typeable)

data SElement = SElement (Char -> Bool) Int Bool

instance Show SElement where
  show (SElement _ i b) = "SElement: " ++ show i ++ " " ++ show b

type BBANStructure = [SElement]

-- | show a IBAN in 4-blocks
prettyIBAN :: IBAN -> Text
prettyIBAN (IBAN str) = T.intercalate " " $ T.chunksOf 4 str

data ValidatedBBAN = ValidatedBBAN {unBban :: [Text]} deriving Show
data ValidatedIBAN = ValidatedIBAN {code :: CountryCode, checkDigs :: Int, bban :: ValidatedBBAN} deriving Show
toString :: ValidatedIBAN -> Text
toString ValidatedIBAN{..} = (T.pack . mconcat $ [ show code , show checkDigs]) <> bbanText where
  bbanText :: Text
  bbanText = mconcat . unBban $ bban


-- | try to parse an IBAN
parseIBAN :: Text -> Either IBANError IBAN
parseIBAN str = do
  validIBAN <- validateIBAN str
  return $ IBAN (toString validIBAN)

validateIBAN :: Text -> Either IBANError ValidatedIBAN
validateIBAN str = do
  s <- removeSpaces str & validateChars >>= validateChecksum
  ccode <- left (IBANInvalidCountry . T.pack) $ parseOnly countryP s
  struct <- left (IBANError1 . T.pack) $ Data.findByCountry ccode
  left (const IBANInvalidStructure) $ parseOnly (ibanP struct) s --todo better error message

ibanP :: Data.IBANStricture -> Parser ValidatedIBAN
ibanP Data.IBANStricture{..} = do
  ccode <- countryP
  chDigs <- chDigsP checkDigitsStructure
  bban <- parseBBAN bbanStructure
  endOfInput
  return $ ValidatedIBAN ccode chDigs (ValidatedBBAN bban)

chDigsP :: Data.StructElem ->  Parser Int
chDigsP se = do
  v <- toElemP se
  maybe (fail "Error parsing check digits") pure (readMaybe $ unpack v)

parseBBAN :: [Data.StructElem] -> Parser [Text]
parseBBAN = traverse toElemP

-- todo tests for validation
validateChars :: Text -> Either IBANError Text
validateChars cs = if T.any (not . Data.isCompliant) cs
                   then Left IBANInvalidCharacters
                   else Right cs

validateChecksum :: Text -> Either IBANError Text
validateChecksum cs = if 1 /= mod97_10 cs
                      then Left IBANWrongChecksum
                      else Right cs

removeSpaces :: Text -> Text
removeSpaces = T.filter (/= ' ')

checkStructure :: BBANStructure -> Text -> Bool
checkStructure structure s = isNothing $ foldl' step (Just s) structure
  where
    step :: Maybe Text -> SElement -> Maybe Text
    step Nothing _ = Nothing
    step (Just t) (SElement cond cnt strict) =
      case T.dropWhile cond t' of
        "" -> Just r
        r' -> if strict then Nothing
                        else Just $ r' <> r
      where
        (t', r) = T.splitAt cnt t

parseStructure :: Text -> (CountryCode, BBANStructure)
parseStructure completeStructure = (cc, structure)
  where
    (cc', s) = T.splitAt 2 completeStructure
    cc = either err id $ readNote' ("invalid country code" <> show cc') cc'

    structure = case T.foldl' step (0, False, []) s of
                  (0, False, xs) -> reverse xs
                  _              -> err "invalid"

    step :: (Int, Bool, [SElement]) -> Char -> (Int, Bool, [SElement])
    step (_,   True,   _ ) '!' = err "unexpected '!'"
    step (cnt, False,  xs) '!' = (cnt, True, xs)
    step (cnt, strict, xs)  c
      | isDigit c               = (cnt*10 + digitToInt c, False, xs)
      | c `elem` ("nace"::String) = addElement xs condition cnt strict
      | otherwise               = err $ "unexpected " ++ show c
      where
        condition = case c of
                      'n' -> isDigit
                      'a' -> isAsciiUpper
                      'c' -> \c' -> isAsciiUpper c' || isDigit c'
                      'e' -> (== ' ')
                      _   -> err $ "unexpected " ++ show c

    addElement xs repr cnt strict = (0, False, SElement repr cnt strict : xs)
    err details = error $ "IBAN.parseStructure: " <> details <> " in " <> show s

countryStructures :: Map CountryCode BBANStructure
countryStructures = M.fromList $ map parseStructure Data.structures

-- | Calculate the reordered decimal number mod 97 using Horner's rule.
-- according to ISO 7064: mod97-10
mod97_10 :: Text -> Int
mod97_10 = fold . reorder
  where reorder = uncurry (flip T.append) . T.splitAt 4
        fold = T.foldl' ((flip rem 97 .) . add) 0
        add n c
          -- is that right? all examples in the internet ignore lowercase
          | isAsciiLower c = add n $ toUpper c
          | isAsciiUpper c = 100*n + 10 + fromEnum c - fromEnum 'A'
          | isDigit c      = 10*n + digitToInt c
          | otherwise      = error $ "Finance.IBAN.Internal.mod97: wrong char " ++ [c]

note :: e -> Maybe a -> Either e a
note e = maybe (Left e) Right

readNote' :: Read a => b -> Text -> Either b a
readNote' note = maybe (Left note) Right . readMaybe . T.unpack
