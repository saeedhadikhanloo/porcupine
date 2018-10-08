{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE TupleSections #-}

module System.TaskPipeline.ResourceTree where

import Control.Lens
import Data.Typeable
import           Data.Locations.SerializationMethod
import Data.Locations
import           Data.Monoid                        (First (..))
import qualified Data.Text as T
import qualified Data.HashMap.Strict as HM
import Data.List (intersperse)
import Data.Representable
import Data.Aeson
import Data.Maybe


-- * API for manipulating resource tree _nodes_

-- | The internal part of a 'VirtualFileNode', closing over the type params of
-- the 'VirtualFile'
data SomeVirtualFile md where
  SomeVirtualFile :: (Typeable a, Typeable b, Monoid b) => VirtualFile_ md a b -> SomeVirtualFile md

instance (Semigroup md, Typeable md) => Semigroup (SomeVirtualFile md) where
  SomeVirtualFile vf <> SomeVirtualFile vf' = case cast vf' of
    Just vf'' -> SomeVirtualFile $ vf <> vf''
    Nothing -> error "Two differently typed VirtualFiles are at the same location"

-- | Information about the access just done, for logging purposes
data DataAccessDone = DidReadLoc String | DidWriteLoc String

-- | The internal part of a 'DataAccessNode, closing over the type params of the
-- access function
data SomeDataAccess m where
  SomeDataAccess :: (Typeable a, Typeable b) => (a -> m (b, [DataAccessDone])) -> SomeDataAccess m

-- These aliases are for compatibility with ATask. Will be removed in the future
-- when ATask is modified.
type InVirtualState = WithDefaultUsage
data InPhysicalState a
type InDataAccessState = LocLayers

-- | Each node of the 'ResourceTree' can be in 3 possible states
data ResourceTreeNode m state where
  VirtualFileNodeE
    :: Maybe (SomeVirtualFile VFMetadata)
    -> ResourceTreeNode m InVirtualState  -- ^ State used when building the task pipeline
  PhysicalFileNodeE
    :: Maybe (SomeVirtualFile (LocLayers (Maybe FileExt), VFMetadata))
    -> ResourceTreeNode m InPhysicalState -- ^ State used for inspecting resource mappings
  DataAccessNodeE
    :: First (SomeDataAccess m)  -- Data access function isn't a semigroup,
                                 -- hence the use of First here instead of
                                 -- Maybe.
    -> ResourceTreeNode m InDataAccessState -- ^ State used when running the task pipeline

-- | The nodes of the LocationTree when using VirtualFiles
type VirtualFileNode m = ResourceTreeNode m InVirtualState
pattern VirtualFileNode x = VirtualFileNodeE (Just (SomeVirtualFile x))

type PhysicalFileNode m = ResourceTreeNode m InPhysicalState
pattern PhysicalFileNode x = PhysicalFileNodeE (Just (SomeVirtualFile x))

-- | The nodes of the LocationTree after the VirtualFiles have been resolved to
-- physical paths, and data possibly extracted from these paths
type DataAccessNode m = ResourceTreeNode m InDataAccessState
pattern DataAccessNode x = DataAccessNodeE (First (Just (SomeDataAccess x)))

instance Semigroup (VirtualFileNode m) where
  VirtualFileNodeE vf <> VirtualFileNodeE vf' = VirtualFileNodeE $ vf <> vf'
instance Monoid (VirtualFileNode m) where
  mempty = VirtualFileNodeE mempty
-- TODO: It is dubious that composing DataAccessNodes is really needed in the
-- end. Find a way to remove that.
instance Semigroup (DataAccessNode m) where  
  DataAccessNodeE f <> DataAccessNodeE f' = DataAccessNodeE $ f <> f'
instance Monoid (DataAccessNode m) where
  mempty = DataAccessNodeE mempty

instance Show (VirtualFileNode m) where
  show (VirtualFileNode vf) = show $ getVirtualFileDescription vf
  show _ = ""
  -- TODO: Cleaner Show
  -- TODO: Display read/written types here, since they're already Typeable
instance Show (PhysicalFileNode m) where
  show (PhysicalFileNode vf) =
    T.unpack (mconcat
              (intersperse " << "
               (map locToText $
                 toListOf (vfileStateData . _1 . locLayers) vf)))
    ++ " - " ++ show (getVirtualFileDescription vf)
    where
      locToText (loc, mbext) = toTextRepr $ addExtToLocIfMissing' loc (fromMaybe "" mbext)
  show _ = "null"


-- * API for manipulating resource trees globally

-- | The tree manipulated by tasks during their construction
type VirtualResourceTree m = LocationTree (VirtualFileNode m)

-- | The tree manipulated when checking if each location is bound to something
-- legit
type PhysicalResourceTree m = LocationTree (PhysicalFileNode m)

-- | The tree manipulated by tasks when they actually run
type DataResourceTree m = LocationTree (DataAccessNode m)

instance HasDefaultMappingRule (VirtualFileNode m) where
  isMappedByDefault (VirtualFileNode vf) = isMappedByDefault vf
  isMappedByDefault _ = True
                        -- Intermediary levels (folders, where there is no
                        -- VirtualFile) are kept

-- | Filters the tree to get only the nodes that don't have data and can be
-- mapped to external files
rscTreeToMappings
  :: VirtualResourceTree m
  -> Maybe (LocationMappings (VirtualFileNode m))
rscTreeToMappings tree = mappingsFromLocTree <$> over filteredLocsInTree rmOpts tree
  where
    rmOpts n@(VirtualFileNode vfile)
      | Just VFForCLIOptions <- intent = Nothing
      where intent = vfileDescIntent $ getVirtualFileDescription vfile
    rmOpts n = Just n

-- | Filters the tree to get only the nodes than can be embedded in the config file
rscTreeToEmbeddedDataTree
  :: VirtualResourceTree m
  -> Maybe (VirtualResourceTree m)
rscTreeToEmbeddedDataTree = over filteredLocsInTree keepOpts
  where
    keepOpts n@(VirtualFileNode vfile)
      | Just VFForCLIOptions <- intent = Just n
      | otherwise = Nothing
      where intent = vfileDescIntent $ getVirtualFileDescription vfile
    keepOpts n = Just n

embeddedDataSection :: T.Text
embeddedDataSection = "data"

mappingsSection :: T.Text
mappingsSection = "locations"

embeddedDataTreeToJSONFields
  :: T.Text -> VirtualResourceTree m -> [(T.Text, Value)]
embeddedDataTreeToJSONFields thisPath (LocationTree mbOpts sub) =
  [(thisPath, Object $ opts' <> sub')]
  where
    opts' = case mbOpts of
      (VirtualFileNode vf) -> case vfileDefaultAesonValue vf of
        Just o -> HM.singleton "_data" o
        _ -> mempty
      _ -> mempty
    sub' = HM.fromList $
      concat $ map (\(k,v) -> embeddedDataTreeToJSONFields (_ltpiName k) v) $ HM.toList sub

-- | A 'VirtualResourceTree' associated with the mapping that should be applied
-- to it.
data ResourceTreeAndMappings m =
  ResourceTreeAndMappings (VirtualResourceTree m)
                          (Either Loc (LocationMappings FileExt))

instance ToJSON (ResourceTreeAndMappings m) where
  toJSON (ResourceTreeAndMappings tree mappings) = Object $
    (case rscTreeToMappings tree of
       Just m ->
         HM.singleton mappingsSection $ toJSON' $ case mappings of
           Right m'     -> m'
           Left rootLoc -> mappingRootOnly rootLoc (Just "") <> fmap nodeExt m
    ) <> (
    case rscTreeToEmbeddedDataTree tree of
      Just t  -> HM.fromList $ embeddedDataTreeToJSONFields embeddedDataSection t
      Nothing -> HM.empty
    )
    where
      toJSON' :: LocationMappings FileExt -> Value
      toJSON' = toJSON
      nodeExt :: MbLocWithExt (VirtualFileNode m) -> MbLocWithExt FileExt
      nodeExt (MbLocWithExt loc (Just (VirtualFileNode
                                       (serialDefaultExt . vfileSerials -> First ext)))) =
        MbLocWithExt loc ext
      nodeExt (MbLocWithExt loc _) = MbLocWithExt loc Nothing

-- | Transform a virtual file node in file node with physical locations
applyOneRscMapping :: Maybe (LocLayers (Maybe FileExt)) -> VirtualFileNode m -> PhysicalFileNode m
applyOneRscMapping (Just layers) (VirtualFileNode vf) = PhysicalFileNode $ vf & vfileStateData %~ (layers,)
applyOneRscMapping _ _ = PhysicalFileNodeE Nothing

applyMappingsToResourceTree :: ResourceTreeAndMappings m -> PhysicalResourceTree m
applyMappingsToResourceTree (ResourceTreeAndMappings tree mappings) =
  applyMappings applyOneRscMapping m' tree
  where
    m' = case mappings of
           Right m -> m
           Left rootLoc -> mappingRootOnly rootLoc Nothing

-- data TaskConstructionError =
--   TaskConstructionError String
--   deriving (Show)
-- instance Exception TaskConstructionError

-- -- | Transform a file node with physical locations in node with a data access
-- -- function to run
-- resolveNodeDataAccess :: (MonadThrow m') => PhysicalFileNode m -> m' (DataAccessNode m)
-- resolveNodeDataAccess (PhysicalFileNode vf) = DataAccessNode run
--   where
--     layers = vf ^. vfileStateData . _1
--     run input = 
-- resolveNodeDataAccess _ = DataAccessNodeE $ First Nothing

-- rscTreeConfigurationReader
--   :: VirtualResourceTree m
--   -> CLIOverriding ResourceTreeAndMappings (LocationTree (VirtualFileNode m, RecOfOptions SourcedDocField))
-- rscTreeConfigurationReader defTree = CLIOverriding{..}
--   where
--     extractOpts (VirtualFileNode
--     treeOfOpts =
--     overridesParser =
