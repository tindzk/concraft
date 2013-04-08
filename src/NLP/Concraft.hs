{-# LANGUAGE RecordWildCards #-}

module NLP.Concraft
(
-- * Model 
  Concraft (..)
, saveModel
, loadModel

-- * Tagging
, tag

-- * Training
, train
) where

import           System.IO (hClose)
import           Control.Applicative ((<$>), (<*>))
import           Control.Monad (when)
import           Data.Binary (Binary, put, get)
import qualified Data.Binary as Binary
import           Data.Aeson
import           Data.Maybe (fromJust)
import qualified System.IO.Temp as Temp
import qualified Data.ByteString.Lazy as BL
import qualified Codec.Compression.GZip as GZip

import           NLP.Concraft.Morphosyntax
import           NLP.Concraft.Analysis
import           NLP.Concraft.Format.Temp
import qualified Data.Tagset.Positional as P
import qualified NLP.Concraft.Guess as G
import qualified NLP.Concraft.Disamb as D


---------------------
-- Model
---------------------


modelVersion :: String
modelVersion = "0.5"


-- | Concraft data.
data Concraft = Concraft
    { tagset        :: P.Tagset
    , guessNum      :: Int
    , guesser       :: G.Guesser P.Tag
    , disamb        :: D.Disamb }


instance Binary Concraft where
    put Concraft{..} = do
        put modelVersion
        put tagset
        put guessNum
        put guesser
        put disamb
    get = do
        comp <- get     
        when (comp /= modelVersion) $ error $
            "Incompatible model version: " ++ comp ++
            ", expected: " ++ modelVersion
        Concraft <$> get <*> get <*> get <*> get


-- | Save model in a file.  Data is compressed using the gzip format.
saveModel :: FilePath -> Concraft -> IO ()
saveModel path = BL.writeFile path . GZip.compress . Binary.encode


-- | Load model from a file.
loadModel :: FilePath -> IO Concraft
loadModel path = do
    x <- Binary.decode . GZip.decompress <$> BL.readFile path
    x `seq` return x


---------------------
-- Tagging
---------------------


-- | Tag sentence using the model.  In your code you should probably
-- use your analysis function, translate results into a container of
-- `Sent`ences, evaluate `tagSent` on each sentence and embed the
-- tagging results into morphosyntactic structure of your own.
tag :: Word w => Concraft -> Sent w P.Tag -> [P.Tag]
tag Concraft{..} = D.disamb disamb . G.guessSent guessNum guesser


---------------------
-- Training
---------------------

-- INFO: We take an input dataset as a list, since it is read only once.

-- | Train guessing and disambiguation models.
train
    :: (Word w, FromJSON w, ToJSON w)
    => P.Tagset         -- ^ Tagset
    -> Analyse w P.Tag  -- ^ Analysis function
    -> Int              -- ^ Numer of guessed tags for each word 
    -> G.TrainConf      -- ^ Guessing model training configuration
    -> D.TrainConf      -- ^ Disambiguation model training configuration
    -> [SentO w P.Tag]  -- ^ Training data
    -> Maybe [SentO w P.Tag]  -- ^ Maybe evaluation data
    -> IO Concraft
train tagset ana guessNum guessConf disambConf train0 eval0 = do
    putStrLn "\n===== Reanalysis ====="
    trainR <- reAnaPar tagset ana train0
    evalR  <- case eval0 of
            Just ev -> Just <$> reAnaPar tagset ana ev
            Nothing -> return Nothing
    withTemp tagset "train" trainR $ \trainR'IO -> do
    withTemp' tagset "eval" evalR  $ \evalR'IO  -> do

    putStrLn "\n===== Train guessing model ====="
    guesser <- do
        tr <- trainR'IO
        ev <- evalR'IO
        G.train guessConf tr ev
    trainG <-       map (G.guessSent guessNum guesser)  <$> trainR'IO
    evalG  <- fmap (map (G.guessSent guessNum guesser)) <$> evalR'IO

    putStrLn "\n===== Train disambiguation model ====="
    disamb <- D.train disambConf trainG evalG
    return $ Concraft tagset guessNum guesser disamb


---------------------
-- Temporary storage
---------------------


-- | Store dataset on a disk and run a handler on a list which is read
-- lazily from the disk.  A temporary file will be automatically
-- deleted after the handler is done.
withTemp
    :: (FromJSON w, ToJSON w)
    => P.Tagset
    -> String                       -- ^ Template for `Temp.withTempFile`
    -> [Sent w P.Tag]               -- ^ Input dataset
    -> (IO [Sent w P.Tag] -> IO a)  -- ^ Handler
    -> IO a
withTemp tagset tmpl xs handler =
    withTemp' tagset tmpl (Just xs) (handler . fmap fromJust)


-- | Similar to `withTemp` but on a `Maybe` dataset.
--
-- Store dataset on a disk and run a handler on a list which is read
-- lazily from the disk.  A temporary file will be automatically
-- deleted after the handler is done.
withTemp'
    :: (FromJSON w, ToJSON w)
    => P.Tagset
    -> String
    -> Maybe [Sent w P.Tag]
    -> (IO (Maybe [Sent w P.Tag]) -> IO a)
    -> IO a
withTemp' tagset tmpl (Just xs) handler =
  Temp.withTempFile "." tmpl $ \tmpPath tmpHandle -> do
    hClose tmpHandle
    let txtSent = mapSent $ P.showTag tagset
        tagSent = mapSent $ P.parseTag tagset
    writePar tmpPath $ map txtSent xs
    handler (Just . map tagSent <$> readPar tmpPath)
withTemp' _ _ Nothing handler = handler (return Nothing)
