{-# LANGUAGE RecordWildCards #-}

module NLP.Concraft
(
-- * Model 
  Concraft (..)

-- * Analysis
, Analyse
, anaRestore
, restore

-- * Tagging
, tag

-- * Training
, train
, trainNoAna
) where

import           System.IO (hClose)
import           Control.Applicative ((<$>), (<*>))
import           Data.Binary (Binary, put, get, encodeFile, decodeFile)
import           Data.Maybe (fromJust)
import qualified Data.Text.Lazy as L
import qualified System.IO.Temp as Temp

import           NLP.Concraft.Morphosyntax
import qualified Data.Tagset.Positional as P
import qualified NLP.Concraft.Morphosyntax.Align as A
import qualified NLP.Concraft.Guess as G
import qualified NLP.Concraft.Disamb as D

---------------------
-- Concraft
---------------------

-- | Concraft data.
data Concraft = Concraft
    { tagset        :: P.Tagset
    , guessNum      :: Int
    , guesser       :: G.Guesser P.Tag
    , disamb        :: D.Disamb }

instance Binary Concraft where
    put Concraft{..} = do
        put tagset
        put guessNum
        put guesser
        put disamb
    get = Concraft <$> get <*> get <*> get <*> get

---------------------
-- Analysis
---------------------

-- | An analyser performs segmentation (sentence- and token-level)
-- and morphological analysis.
-- TODO: Perhaps we should make sure, that every sentence is non-empty?
type Analyse w t = L.Text -> [Sent w t]

-- | Given analysis input and its result, restore textual representations
-- corresponding to individual sentences.
restore :: HasOrth w => L.Text -> [Sent w t] -> [L.Text]
restore = undefined

-- | Analyse and `restore` input text.
anaRestore :: HasOrth w => Analyse w t -> L.Text -> [SentO w t]
anaRestore ana inp =
    let rs = ana inp
        ts = restore inp rs
    in  map (uncurry SentO) (zip rs ts)

---------------------
-- Tagging
---------------------

-- | Tag sentence using the model.  In your code you should probably
-- use your analysis function, translate results into a container of
-- `Sent`ences, evaluate `tagSent` on each sentence and embed the
-- tagging results into morphosyntactic structure of your own.
tag :: (HasOOV w, HasOrth w) => Concraft -> Sent w P.Tag -> [P.Tag]
tag Concraft{..} = D.disamb disamb . G.guessSent guessNum guesser

-- -- | Perform morphlogical tagging on the input text.
-- tag :: Analyse -> Concraft -> L.Text -> [[Sent P.Tag]]
-- tag analyse concraft = map (tagPar concraft) . analyse

-- -- Tag paragraph.  The function doesn't perform reanalysis.
-- tagPar :: Concraft -> [Sent P.Tag] -> [Sent P.Tag]
-- tagPar = map . tagSent

---------------------
-- Training
---------------------

-- | Train guessing and disambiguation models.
trainNoAna
    :: (HasOOV w, HasOrth w, Binary w)
    => P.Tagset         -- ^ Tagset
    -> Int              -- ^ Numer of guessed tags for each word 
    -> G.TrainConf      -- ^ Guessing model training configuration
    -> D.TrainConf      -- ^ Disambiguation model training configuration
    -> [Sent w P.Tag] -- ^ Training data
    -> Maybe [Sent w P.Tag] -- ^ Maybe evaluation data
    -> IO Concraft
trainNoAna tagset guessNum guessConf disambConf trainR evalR = do
    withTemp "train" trainR $ \trainR'IO -> do
    withTemp' "eval" evalR  $ \evalR'IO  -> do

    putStrLn "\n===== Train guessing model ====\n"
    guesser <- do
        tr <- trainR'IO
        ev <- evalR'IO
        G.train guessConf tr ev
    trainG <-       map (G.guessSent guessNum guesser)  <$> trainR'IO
    evalG  <- fmap (map (G.guessSent guessNum guesser)) <$> evalR'IO

    putStrLn "\n===== Train disambiguation model ====\n"
    disamb <- D.train disambConf trainG evalG
    return $ Concraft tagset guessNum guesser disamb

-- | Train guessing and disambiguation models.
-- TODO: Its probably a good idea to take an input dataset as a list, since
-- it is read only once.  On the other hand, we loose a chance to handle
-- errors generated during dataset parsing.  So, perhaps pipes would be
-- better?  Besides, even when a user uses plain lists as a representation
-- of datasets, they can be easily transormed into pipes.
-- TODO: Use some legible format to store temporary files, for users sake.
train
    :: (HasOOV w, HasOrth w, Binary w)
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
    let trainR = reanalyse tagset ana train0
        evalR  = case eval0 of
            Just ev -> Just $ reanalyse tagset ana ev
            Nothing -> Nothing
    withTemp "train" trainR $ \trainR'IO -> do
    withTemp' "eval" evalR  $ \evalR'IO  -> do

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

-- | Store dataset on a disk and run a handler on a lazy list which is read
-- directly from the disk.  A temporary file will be automatically
-- deleted after the handler is done.
-- TODO: Try using pipes instead of lazy IO (input being a pipe as well?).
withTemp
    :: Binary w
    => String                       -- ^ Template for `Temp.withTempFile`
    -> [Sent w P.Tag]               -- ^ Input dataset
    -> (IO [Sent w P.Tag] -> IO a)  -- ^ Handler
    -> IO a
-- The following version didn't work:
withTemp tmpl xs handler = withTemp' tmpl (Just xs) (handler . fmap fromJust)

-- | The same as `withTemp` but on a `Maybe` dataset.
withTemp'
    :: Binary w
    => String
    -> Maybe [Sent w P.Tag]
    -> (IO (Maybe [Sent w P.Tag]) -> IO a)
    -> IO a
withTemp' tmpl (Just xs) handler =
  Temp.withTempFile "." tmpl $ \tmpPath tmpHandle -> do
    hClose tmpHandle
    encodeFile tmpPath xs
    handler (Just <$> decodeFile tmpPath)
withTemp' _ Nothing handler = handler (return Nothing)

-- | Reanalyse paragraph.
reanalyse :: HasOrth w => P.Tagset -> Analyse w P.Tag
          -> [SentO w P.Tag] -> [Sent w P.Tag]
reanalyse tagset ana xs = chunk
    -- We have to take sentence lengths from the reference corpus because
    -- token-level segmentation is also taken from the reference corpus
    -- (in case of inconsistencies between the two corpora).
    (map length gold)
    (A.sync tagset (concat gold) (concat reana))
  where
    gold  = map segs xs
    reana = ana . L.concat $ map orig xs

-- | Divide the list into a list of chunks given the list of
-- lengths of individual chunks.
chunk :: [Int] -> [a] -> [[a]]
chunk (n:ns) xs = 
    let (first, rest) = splitAt n xs 
    in  first : chunk ns rest
chunk [] [] = []
chunk [] _  = error "chunk: absurd"
