{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.Protobuf.Wire.Decode.Parser (
Parser,
parse,
repeatedUnpacked,
repeatedUnpackedList,
repeatedPacked,
repeatedPackedList,
parseEmbedded,
embedded,
ProtobufParsable(..),
ProtobufPackable,
field
) where

import           Control.Applicative
import           Control.Monad (join)
import           Control.Monad.Except
import           Control.Monad.Reader
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import           Data.Functor.Identity(runIdentity)
import qualified Data.Map.Strict as M
import           Data.Maybe (fromMaybe)
import           Data.Protobuf.Wire.Decode.Internal
import           Data.Protobuf.Wire.Shared
import           Data.Semigroup (Semigroup, (<>))
import           Data.Serialize.Get(Get, runGet, getWord32le, getWord64le)
import           Data.Serialize.IEEE754(getFloat32le, getFloat64le)
import           Data.Text.Lazy (Text, pack)
import           Data.Text.Lazy.Encoding (decodeUtf8')
import           Data.Int (Int32, Int64)
import           Data.Word (Word32, Word64)
import           Pipes
import qualified Pipes.Prelude as P
import           Safe

data ParseError = WireTypeError Text
                  | BinaryError Text
                  | EmbeddedError Text [ParseError]
  deriving (Show, Eq, Ord)

newtype Parser a = Parser
  { unParser :: ReaderT
                  (M.Map FieldNumber [ParsedField]) (Except [ParseError]) a}
  deriving (Functor, Applicative, Monad, Alternative, MonadPlus,
            MonadReader (M.Map FieldNumber [ParsedField]),
            MonadError [ParseError])

-- | Runs a 'Parser'.
parse :: Parser a -> B.ByteString -> Either [ParseError] a
parse parser bs = case parseTuples bs of
                  Left err -> throwError [BinaryError $ pack err]
                  Right res -> runIdentity $ runExceptT $
                                runReaderT (unParser parser) res

-- |
-- To comply with the protobuf spec, if there are multiple fields with the same
-- field number, this will always return the last one. While this is worst case
-- O(n), in practice the worst case will only happen when a field in the .proto
-- file has been changed from singular to repeated, but the deserializer hasn't
-- been made aware of the change.
parsedField :: FieldNumber -> Parser (Maybe ParsedField)
parsedField fn = do
  currMap <- ask
  return $ M.lookup fn currMap >>= lastMay

-- |
-- Consumes all fields with the given field number. This is primarily for
-- unpacked repeated fields. This is also useful for parsing
-- embedded messages, where the spec says that if more than one instance of an
-- embedded message for a given field number is present in the outer message,
-- then they must all be merged.
parsedFields :: FieldNumber -> Parser [ParsedField]
parsedFields fn = do
  currMap <- ask
  let pfs = M.lookup fn currMap
  return $ concat pfs

throwWireTypeError :: Show a => String -> a -> Parser b
throwWireTypeError expected wrong =
  throwError [WireTypeError $ pack $
              "Wrong wiretype. Expected "
              ++ expected ++ " but got " ++ show wrong]

throwCerealError :: String -> String -> Parser b
throwCerealError expected cerealErr =
  throwError [BinaryError $ pack $
              "Failed to parse contents of " ++ expected ++ " field. "
              ++ "Error from cereal was: " ++ cerealErr]

parseVarInt :: Integral a => ParsedField -> Parser a
parseVarInt (VarintField i) = return $ fromIntegral i
parseVarInt wrong = throwWireTypeError "varint" wrong

runGetPacked :: Get [a] -> ParsedField -> Parser [a]
runGetPacked g (LengthDelimitedField bs) =
  case runGet g bs of
    Left e -> throwCerealError "packed repeated field" e
    Right xs -> return xs
runGetPacked g wrong =
  throwWireTypeError "packed repeated field" wrong

runGetFixed32 :: Get a -> ParsedField -> Parser a
runGetFixed32 g (Fixed32Field bs) =
  case runGet g bs of
    Left e -> throwCerealError "fixed32 field" e
    Right x -> return x
runGetFixed32 g wrong =
  throwWireTypeError "fixed 32 field" wrong

runGetFixed64 :: Get a -> ParsedField -> Parser a
runGetFixed64 g (Fixed64Field bs) =
  case runGet g bs of
    Left e -> throwCerealError "fixed 64 field" e
    Right x -> return x
runGetFixed64 g wrong =
  throwWireTypeError "fixed 64 field" wrong

parsePackedVarInt :: Integral a => ParsedField -> Parser [a]
parsePackedVarInt = fmap (fmap fromIntegral)
                    . runGetPacked (many getBase128Varint)

parsePackedFixed32 :: Integral a => ParsedField -> Parser [a]
parsePackedFixed32 = fmap (fmap fromIntegral) . runGetPacked (many getWord32le)

parsePackedFixed32Float :: ParsedField -> Parser [Float]
parsePackedFixed32Float = runGetPacked (many getFloat32le)

parsePackedFixed64 :: Integral a => ParsedField -> Parser [a]
parsePackedFixed64 = fmap (fmap fromIntegral) . runGetPacked (many getWord64le)

parsePackedFixed64Double :: ParsedField -> Parser [Double]
parsePackedFixed64Double = runGetPacked (many getFloat64le)

parseFixed32 :: Integral a => ParsedField -> Parser a
parseFixed32 = fmap fromIntegral . runGetFixed32 getWord32le

parseFixed32Float :: ParsedField -> Parser Float
parseFixed32Float = runGetFixed32 getFloat32le

parseFixed64 :: Integral a => ParsedField -> Parser a
parseFixed64 = fmap fromIntegral . runGetFixed64 getWord64le

parseFixed64Double :: ParsedField -> Parser Double
parseFixed64Double = runGetFixed64 getFloat64le

parseText :: ParsedField -> Parser Text
parseText (LengthDelimitedField bs) =
  case decodeUtf8' $ BL.fromStrict bs of
    Left err -> throwError [BinaryError $ pack $
                            "Failed to decode UTF-8: " ++ show err]
    Right txt -> return txt
parseText wrong = throwWireTypeError "string" wrong

parseBytes :: ParsedField -> Parser B.ByteString
parseBytes (LengthDelimitedField bs) = return bs
parseBytes wrong = throwWireTypeError "bytes" wrong

-- | Create a parser for embedded fields from a message parser. This can
-- be used to easily create an instance of 'ProtobufParsable' for a user-defined
-- type.
parseEmbedded :: Semigroup a => Parser a -> ParsedField -> Parser a
parseEmbedded parser (LengthDelimitedField bs) =
  case parse parser bs of
    Left err -> throwError
                  [EmbeddedError "Failed to parse embedded message." err]
    Right result -> return result
parseEmbedded _ wrong = throwWireTypeError "embedded" wrong

-- | The protobuf spec requires that embedded messages be mergeable, so that
-- protobuf encoding has the flexibility to transmit embedded messages in
-- pieces. This function reassembles the pieces, and must be used to parse all
-- embedded non-repeated messages. The rules for the Monoid instance (as
-- stated in the protobuf spec) are:
-- 1. `x <> y` overwrites the singular fields of x with those of y.
-- 2. `x <> y` recurses on the embedded messages in x and y.
-- 3. `x <> y` concatenates all list fields in x and y.
embedded :: (Semigroup a, ProtobufParsable a) => FieldNumber -> Parser a
embedded = P.foldM f (return protoDefault) return
           . enumerate . delistify . parsedFields
  where f x pf = do
          y <- fromField pf
          return $ x <> y

-- | Specify that one value is expected from this field. Used to ensure that we
-- return the last value with the given field number in the message, in
-- compliance with the protobuf standard.
one :: (ParsedField -> Parser a) -> FieldNumber -> Parser (Maybe a)
one rawParser fn = parsedField fn >>= mapM rawParser

-- | Type class for types that can be parsed from the fields of protobuf
-- messages. This includes singular types like 'Bool' or 'Double', as well as
-- user-defined embedded messages.
class ProtobufParsable a where
  -- | Parse a type from a field. To implement this for embedded messages, see
  -- the helper function 'parseEmbedded'.
  fromField :: ParsedField -> Parser a
  -- | Specifies the default value when a field is missing from the message.
  -- Note: this is used by protobufs to save space on messages by omitting them
  -- if they happen to be set to the default.
  protoDefault :: a

instance ProtobufParsable Bool where
  fromField = fmap toEnum . parseVarInt
  protoDefault = False

instance ProtobufParsable Int32 where
  fromField = parseVarInt
  protoDefault = 0

instance ProtobufParsable Word32 where
  fromField = parseVarInt
  protoDefault = 0

instance ProtobufParsable Int64 where
  fromField = parseVarInt
  protoDefault = 0

instance ProtobufParsable Word64 where
  fromField = parseVarInt
  protoDefault = 0

instance ProtobufParsable (Fixed Word32) where
  fromField = fmap (Fixed . fromIntegral) . parseFixed32
  protoDefault = Fixed 0

instance ProtobufParsable (Signed (Fixed Int32)) where
  fromField = fmap (Signed . Fixed . fromIntegral) . parseFixed32
  protoDefault = Signed $ Fixed 0

instance ProtobufParsable (Fixed Word64) where
  fromField = fmap (Fixed . fromIntegral) . parseFixed64
  protoDefault = Fixed 0

instance ProtobufParsable (Signed (Fixed Int64)) where
  fromField = fmap (Signed . Fixed . fromIntegral) . parseFixed64
  protoDefault = Signed $ Fixed 0

instance ProtobufParsable Float where
  fromField = parseFixed32Float
  protoDefault = 0

instance ProtobufParsable Double where
  fromField = parseFixed64Double
  protoDefault = 0

instance ProtobufParsable Text where
  fromField = parseText
  protoDefault = mempty

instance ProtobufParsable B.ByteString where
  fromField = parseBytes
  protoDefault = mempty

instance Enum e => ProtobufParsable (Enumerated e) where
  fromField = fmap (Enumerated . toEnum . fromIntegral) . parseVarInt
  protoDefault = Enumerated $ toEnum 0

field :: ProtobufParsable a => FieldNumber -> Parser a
field = fmap (fromMaybe protoDefault) . one fromField

-- | Type class for fields that can be repeated in the more efficient packed
-- format. This is limited to primitive numeric types.
class ProtobufPackable a where
  parsePacked :: ParsedField -> Parser [a]

instance ProtobufPackable Word32 where
  parsePacked = parsePackedVarInt

instance ProtobufPackable Word64 where
  parsePacked = parsePackedVarInt

instance ProtobufPackable Int32 where
  parsePacked = parsePackedVarInt

instance ProtobufPackable Int64 where
  parsePacked = parsePackedVarInt

instance ProtobufPackable (Fixed Word32) where
  parsePacked = fmap (fmap (Fixed . fromIntegral)) . parsePackedFixed32

instance ProtobufPackable (Signed (Fixed Int32)) where
  parsePacked = fmap (fmap (Signed . Fixed . fromIntegral)) . parsePackedFixed32

instance ProtobufPackable (Fixed Word64) where
  parsePacked = fmap (fmap (Fixed . fromIntegral)) . parsePackedFixed64

instance ProtobufPackable (Signed (Fixed Int64)) where
  parsePacked = fmap (fmap (Signed . Fixed . fromIntegral)) . parsePackedFixed64

instance ProtobufPackable Float where
  parsePacked = parsePackedFixed32Float

instance ProtobufPackable Double where
  parsePacked = parsePackedFixed64Double

-- | Parses an unpacked repeated field.
repeatedUnpacked :: ProtobufParsable a => FieldNumber -> ListT Parser a
repeatedUnpacked fn = do
  pf <- delistify $ parsedFields fn
  lift (fromField pf)

listify :: ListT Parser a -> Parser [a]
listify = P.toListM . enumerate

delistify :: Parser [a] -> ListT Parser a
delistify x = lift x >>= (Select . each)

repeatedUnpackedList :: ProtobufParsable a => FieldNumber -> Parser [a]
repeatedUnpackedList = P.toListM . enumerate . repeatedUnpacked

-- | Parses a packed repeated field. Correctly handles the case where a packed
-- field has been split across multiple key/value pairs in the encoded message.
-- Falls back to trying to parse the field as unpacked if packed parsing fails,
-- matching the official implementation's behavior.
repeatedPacked' :: (ProtobufParsable a, ProtobufPackable a)
                  => FieldNumber -> ListT Parser a
repeatedPacked' fn = (delistify $ parsedFields fn) >>= (delistify . parsePacked)

repeatedPacked :: (ProtobufParsable a, ProtobufPackable a)
                  => FieldNumber -> ListT Parser a
repeatedPacked fn = delistify $ listify (repeatedPacked' fn)
                                <|> listify (repeatedUnpacked fn)

repeatedPackedList :: (ProtobufParsable a, ProtobufPackable a)
                      => FieldNumber -> Parser [a]
repeatedPackedList = listify . repeatedPacked
