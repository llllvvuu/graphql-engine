{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE ViewPatterns #-}

module Hasura.RQL.DDL.Permission
  ( CreatePerm,
    runCreatePerm,
    PermDef (..),
    InsPerm (..),
    InsPermDef,
    buildInsPermInfo,
    SelPerm (..),
    SelPermDef,
    buildSelPermInfo,
    UpdPerm (..),
    UpdPermDef,
    buildUpdPermInfo,
    DelPerm (..),
    DelPermDef,
    buildDelPermInfo,
    DropPerm,
    runDropPerm,
    dropPermissionInMetadata,
    SetPermComment (..),
    runSetPermComment,
    PermInfo,
    buildPermInfo,
    addPermissionToMetadata,
  )
where

import Control.Lens (Lens', (.~), (^?))
import Data.Aeson
import Data.HashMap.Strict qualified as HM
import Data.HashMap.Strict.InsOrd qualified as OMap
import Data.HashSet qualified as HS
import Data.Text.Extended
import Hasura.Base.Error
import Hasura.EncJSON
import Hasura.Prelude
import Hasura.RQL.DDL.Permission.Internal
import Hasura.RQL.IR.BoolExp
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.ComputedField
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.Metadata.Backend
import Hasura.RQL.Types.Metadata.Object
import Hasura.RQL.Types.Permission
import Hasura.RQL.Types.Relationships.Local
import Hasura.RQL.Types.SchemaCache
import Hasura.RQL.Types.SchemaCache.Build
import Hasura.RQL.Types.Table
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.SQL.Types
import Hasura.Server.Types (StreamingSubscriptionsCtx (..))
import Hasura.Session

{- Note [Backend only permissions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
As of writing this note, Hasura permission system is meant to be used by the
frontend. After introducing "Actions", the webhook handlers now can make GraphQL
mutations to the server with some backend logic. These mutations shouldn't be
exposed to frontend for any user since they'll bypass the business logic.

Backend only permissions is available for all(insert/update/delete) mutation operations.

For example:-
=============

We've a table named "user" and it has a "email" column. We need to validate the
email address. So we define an action "create_user" and it expects the same inputs
as "insert_user" mutation (generated by Hasura). Note that both "create_user" and
"insert_user" can insert values into the "user" table but only "create_user" has the
logic to validate the email address.

In the current Hasura permission system, a role has permission for both 'actions' and
'insert operations' on the table. That means, both the "create_user" and "insert_user"
operations will be visible to the frontend client. This is bad, since users can use
"insert_user" operation to circumvent the validation logic of "create_user".

We can overcome this problem by using "Backend only permissions". In this if the
insert/update/delete permission is marked as "backend_only: true", then the insert
operation will not be visible to the frontend client unless specifically specified

Backend only permissions adds an additional privilege to Hasura generated operations.

Those are accessable only if the request is made with all of the following:
  * `x-hasura-admin-secret` (if authorization is configured),
  * `x-hasura-use-backend-only-permissions` (value must be set to "true"),
  * `x-hasura-role` to identify the role
  * other required session variables.

backend_only   `x-hasura-admin-secret`   `x-hasura-use-backend-only-permissions`  Result
------------    ---------------------     -------------------------------------   ------
FALSE           ANY                       ANY                                    Mutation is always visible (Default Case: When no authorization is setup)
TRUE            FALSE                     ANY                                    Mutation is always hidden
FALSE           TRUE                      ANY                                    Mutation is always visible
TRUE            TRUE (OR NOT-SET)         FALSE                                  Mutation is hidden
TRUE            TRUE (OR NOT-SET)         TRUE                                   Mutation is shown

case 1: default case - no authorization is set and no backend_only permission are set
then irresepective of the value of `x-hasura-use-backend-only-permissions` the
mutation will always be visible

case 2: the authorization is set and the backend_only permissions are set but the
`x-hasura-admin-secret` is not sent along with request then irresepective of the value
in `x-hasura-use-backend-only-permissions` the mutation will always be hidden

case 3: the authorization is set, but no backend_only permission are set, the
`x-hasura-admin-secret` is sent along with request then irresepective of the value
in `x-hasura-use-backend-only-permissions` the mutation will always be visible

case 4 and 5:
the authz is set and the backend_only permissions are also set and the
`x-hasura-admin` secret is also sent along with the request then:
  * if `x-hasura-use-backend-only-permissions` header is sent as FALSE along with the
    request then the mutation will be hidden (4th case)
  * if `x-hasura-use-backend-only-permissions` header is sent as TRUE along with the
    request then the mutation will be visible (5th case)

How it Works:-
===============

Hasura has two scenarios:
  * Frontend Scenario
  * Backend Scenario

When no backend-only permissions are set then Hasura runs only in frontend scenario,
i.e all the mutation operations are visible.

When backend-only permissions are set, there comes a notion of:
  * which mutations are visible by default i.e without any request headers (frontend scenario)
  * which mutations are visible when `x-hasura-use-backend-only-permissions` is set (backend scenario)

Hasura maintains two different graphql schema ('frontend schema' and 'backend schema')
for all mutation fields of a table:
  * 'frontend schema': info about the mutation operation allowed to be shown on the frontend client when no backend-only permissions is set
  * 'backend schema' : info about the mutation operation allowed to be shown on the frontend client when backend-only permissions is set

The generation of these schemas happen in the `buildSource` functions of
`buildRoleContext` and `buildRelayRoleContext` functions. The internal representation
of these schema's look like:
  {RoleName: (Frontend Schema/Default Schema, Backend Schema)}

For example:
------------
We've a table "user" tracked by hasura and a role "public"

* If the update permission for the table "user" is marked as backend_only then the
  GQL context for that table will look like:

    {"public": (["insert_user","delete_user"], ["update_user"])}

  In the above '["insert_user","delete_user"]' are the only mutation operation visible
  by default on the frontend client. And the 'update_user' opertaion is only visible
  when the `x-hasura-use-backend-only-permissions` request header is present.

* If there is no backend_only permissions defined on the role then the GQL context
  looks like:

    {"public": (["insert_user","delete_user", "update_user"], [])}

  In the above there is no specific schema for the backend scenario i.e all the
  mutation operations are visible by default.
-}
procSetObj ::
  forall b m.
  (QErrM m, BackendMetadata b) =>
  SourceName ->
  TableName b ->
  FieldInfoMap (FieldInfo b) ->
  Maybe (ColumnValues b Value) ->
  m (PreSetColsPartial b, [Text], [SchemaDependency])
procSetObj source tn fieldInfoMap mObj = do
  (setColTups, deps) <- withPathK "set" $
    fmap unzip $
      forM (HM.toList setObj) $ \(pgCol, val) -> do
        ty <-
          askColumnType fieldInfoMap pgCol $
            "column " <> pgCol <<> " not found in table " <>> tn
        sqlExp <- parseCollectableType (CollectableTypeScalar ty) val
        let dep = mkColDep @b (getDepReason sqlExp) source tn pgCol
        return ((pgCol, sqlExp), dep)
  return (HM.fromList setColTups, depHeaders, deps)
  where
    setObj = fromMaybe mempty mObj
    depHeaders = getDepHeadersFromVal $ Object $ mapKeys toTxt setObj

    getDepReason = bool DRSessionVariable DROnType . isStaticValue

type family PermInfo perm where
  PermInfo SelPerm = SelPermInfo
  PermInfo InsPerm = InsPermInfo
  PermInfo UpdPerm = UpdPermInfo
  PermInfo DelPerm = DelPermInfo

addPermissionToMetadata ::
  PermDef b a ->
  TableMetadata b ->
  TableMetadata b
addPermissionToMetadata permDef = case _pdPermission permDef of
  InsPerm' _ -> tmInsertPermissions %~ OMap.insert (_pdRole permDef) permDef
  SelPerm' _ -> tmSelectPermissions %~ OMap.insert (_pdRole permDef) permDef
  UpdPerm' _ -> tmUpdatePermissions %~ OMap.insert (_pdRole permDef) permDef
  DelPerm' _ -> tmDeletePermissions %~ OMap.insert (_pdRole permDef) permDef

buildPermInfo ::
  (BackendMetadata b, QErrM m, TableCoreInfoRM b m) =>
  SourceName ->
  TableName b ->
  FieldInfoMap (FieldInfo b) ->
  RoleName ->
  StreamingSubscriptionsCtx ->
  PermDefPermission b perm ->
  m (WithDeps (PermInfo perm b))
buildPermInfo x1 x2 x3 roleName streamingSubscriptionsCtx = \case
  SelPerm' p -> buildSelPermInfo x1 x2 x3 roleName streamingSubscriptionsCtx p
  InsPerm' p -> buildInsPermInfo x1 x2 x3 p
  UpdPerm' p -> buildUpdPermInfo x1 x2 x3 p
  DelPerm' p -> buildDelPermInfo x1 x2 x3 p

doesPermissionExistInMetadata ::
  forall b.
  TableMetadata b ->
  RoleName ->
  PermType ->
  Bool
doesPermissionExistInMetadata tableMetadata roleName = \case
  PTInsert -> hasPermissionTo tmInsertPermissions
  PTSelect -> hasPermissionTo tmSelectPermissions
  PTUpdate -> hasPermissionTo tmUpdatePermissions
  PTDelete -> hasPermissionTo tmDeletePermissions
  where
    hasPermissionTo :: forall a. Lens' (TableMetadata b) (Permissions a) -> Bool
    hasPermissionTo perms = isJust $ tableMetadata ^? perms . ix roleName

runCreatePerm ::
  forall m b a.
  (UserInfoM m, CacheRWM m, MonadError QErr m, MetadataM m, BackendMetadata b) =>
  CreatePerm a b ->
  m EncJSON
runCreatePerm (CreatePerm (WithTable source tableName permissionDefn)) = do
  tableMetadata <- askTableMetadata @b source tableName
  let permissionType = reflectPermDefPermission (_pdPermission permissionDefn)
      ptText = permTypeToCode permissionType
      role = _pdRole permissionDefn
      metadataObject =
        MOSourceObjId source $
          AB.mkAnyBackend $
            SMOTableObj @b tableName $
              MTOPerm role permissionType

  -- NOTE: we check if a permission exists for a `(table, role)` entity in the metadata
  -- and not in the `RolePermInfoMap b` because there may exist a permission for the `role`
  -- which is an inherited one, so we check it in the metadata directly

  -- The metadata will not contain the permissions for the admin role,
  -- because the graphql-engine automatically creates the role and it's
  -- assumed that the admin role is an implicit role of the graphql-engine.
  when (doesPermissionExistInMetadata tableMetadata role permissionType || role == adminRoleName) $
    throw400 AlreadyExists $
      ptText <> " permission already defined on table " <> tableName <<> " with role " <>> role
  buildSchemaCacheFor metadataObject $
    MetadataModifier $
      tableMetadataSetter @b source tableName %~ addPermissionToMetadata permissionDefn
  pure successMsg

runDropPerm ::
  forall b m.
  (UserInfoM m, CacheRWM m, MonadError QErr m, MetadataM m, BackendMetadata b) =>
  PermType ->
  DropPerm b ->
  m EncJSON
runDropPerm permType (DropPerm source table role) = do
  tableMetadata <- askTableMetadata @b source table
  unless (doesPermissionExistInMetadata tableMetadata role permType) $ do
    let errMsg =
          mconcat
            [ permTypeToCode permType <> " permission on " <>> table,
              " for role " <>> role,
              " does not exist"
            ]
    throw400 PermissionDenied errMsg
  withNewInconsistentObjsCheck $
    buildSchemaCache $
      MetadataModifier $
        tableMetadataSetter @b source table %~ dropPermissionInMetadata role permType
  return successMsg

buildInsPermInfo ::
  forall b m.
  (QErrM m, TableCoreInfoRM b m, BackendMetadata b) =>
  SourceName ->
  TableName b ->
  FieldInfoMap (FieldInfo b) ->
  InsPerm b ->
  m (WithDeps (InsPermInfo b))
buildInsPermInfo source tn fieldInfoMap (InsPerm checkCond set mCols backendOnly) =
  withPathK "permission" $ do
    (be, beDeps) <- withPathK "check" $ procBoolExp source tn fieldInfoMap checkCond
    (setColsSQL, setHdrs, setColDeps) <- procSetObj source tn fieldInfoMap set
    void $
      withPathK "columns" $ do
        indexedForM insCols $ \col -> do
          -- Check that all columns specified do in fact exist and are columns
          _ <- askColumnType fieldInfoMap col relInInsErr
          -- Check that the column is insertable
          ci <- askColInfo fieldInfoMap col ""
          unless (_cmIsInsertable $ ciMutability ci) $
            throw500
              ( "Column " <> col
                  <<> " is not insertable and so cannot have insert permissions defined"
              )

    let fltrHeaders = getDependentHeaders checkCond
        reqHdrs = fltrHeaders `HS.union` (HS.fromList setHdrs)
        insColDeps = map (mkColDep @b DRUntyped source tn) insCols
        deps = mkParentDep @b source tn : beDeps ++ setColDeps ++ insColDeps
        insColsWithoutPresets = insCols \\ HM.keys setColsSQL

    return (InsPermInfo (HS.fromList insColsWithoutPresets) be setColsSQL backendOnly reqHdrs, deps)
  where
    allInsCols = map ciColumn $ filter (_cmIsInsertable . ciMutability) $ getCols fieldInfoMap
    insCols = interpColSpec allInsCols (fromMaybe PCStar mCols)
    relInInsErr = "Only table columns can have insert permissions defined, not relationships or other field types"

-- | validate the values present in the `query_root_fields` and the `subscription_root_fields`
--   present in the select permission
validateAllowedRootFields ::
  forall b m.
  (QErrM m, TableCoreInfoRM b m, BackendMetadata b) =>
  SourceName ->
  TableName b ->
  RoleName ->
  StreamingSubscriptionsCtx ->
  SelPerm b ->
  m (AllowedRootFields QueryRootFieldType, AllowedRootFields SubscriptionRootFieldType)
validateAllowedRootFields sourceName tableName roleName streamSubsCtx SelPerm {..} = do
  tableCoreInfo <- lookupTableCoreInfo @b tableName >>= (`onNothing` (throw500 $ "unexpected: table not found " <>> tableName))

  -- validate the query_root_fields and subscription_root_fields values
  let needToValidatePrimaryKeyRootField =
        QRFTSelectByPk `rootFieldNeedsValidation` spAllowedQueryRootFields
          || SRFTSelectByPk `rootFieldNeedsValidation` spAllowedSubscriptionRootFields
      needToValidateAggregationRootField =
        QRFTSelectAggregate `rootFieldNeedsValidation` spAllowedQueryRootFields
          || SRFTSelectAggregate `rootFieldNeedsValidation` spAllowedSubscriptionRootFields
      needToValidateStreamingRootField =
        SRFTSelectStream `rootFieldNeedsValidation` spAllowedSubscriptionRootFields

  when needToValidatePrimaryKeyRootField $ validatePrimaryKeyRootField tableCoreInfo
  when needToValidateAggregationRootField $ validateAggregationRootField
  when needToValidateStreamingRootField $ validateStreamingRootField

  pure (spAllowedQueryRootFields, spAllowedSubscriptionRootFields)
  where
    rootFieldNeedsValidation rootField = \case
      ARFAllowAllRootFields -> False
      ARFAllowConfiguredRootFields allowedRootFields -> rootField `HS.member` allowedRootFields

    pkValidationError =
      throw400 ValidationFailed $
        "The \"select_by_pk\" field cannot be included in the query_root_fields or subscription_root_fields"
          <> " because the role "
          <> roleName
          <<> " does not have access to the primary key of the table "
          <> tableName
          <<> " in the source " <>> sourceName
    validatePrimaryKeyRootField TableCoreInfo {..} =
      case _tciPrimaryKey of
        Nothing -> pkValidationError
        Just (PrimaryKey _ pkCols) ->
          case spColumns of
            PCStar -> pure ()
            PCCols (HS.fromList -> selPermCols) ->
              -- Check if all the primary key columns of the table are
              -- accessible to the current role
              unless (all ((`HS.member` selPermCols) . ciColumn) pkCols) pkValidationError

    validateAggregationRootField =
      unless spAllowAggregations $
        throw400 ValidationFailed $
          "The \"select_aggregate\" root field can only be enabled in the query_root_fields or "
            <> " the subscription_root_fields when \"allow_aggregations\" is set to true"

    validateStreamingRootField =
      unless (streamSubsCtx == StreamingSubscriptionsEnabled) $
        throw400 ValidationFailed $
          "The \"select_stream\" root field can only be included in the query_root_fields or "
            <> " the subscription_root_fields when streaming subscriptions is enabled"

buildSelPermInfo ::
  forall b m.
  (QErrM m, TableCoreInfoRM b m, BackendMetadata b) =>
  SourceName ->
  TableName b ->
  FieldInfoMap (FieldInfo b) ->
  RoleName ->
  StreamingSubscriptionsCtx ->
  SelPerm b ->
  m (WithDeps (SelPermInfo b))
buildSelPermInfo source tableName fieldInfoMap roleName streamSubsCtx sp = withPathK "permission" $ do
  let pgCols = interpColSpec (map ciColumn $ (getCols fieldInfoMap)) $ spColumns sp

  (spiFilter, boolExpDeps) <-
    withPathK "filter" $
      procBoolExp source tableName fieldInfoMap $ spFilter sp

  -- check if the columns exist
  void $
    withPathK "columns" $
      indexedForM pgCols $ \pgCol ->
        askColumnType fieldInfoMap pgCol autoInferredErr

  -- validate computed fields
  validComputedFields <-
    withPathK "computed_fields" $
      indexedForM computedFields $ \fieldName -> do
        computedFieldInfo <- askComputedFieldInfo fieldInfoMap fieldName
        case computedFieldReturnType @b (_cfiReturnType computedFieldInfo) of
          ReturnsScalar _ -> pure fieldName
          ReturnsTable returnTable ->
            throw400 NotSupported $
              "select permissions on computed field " <> fieldName
                <<> " are auto-derived from the permissions on its returning table "
                <> returnTable
                <<> " and cannot be specified manually"
          ReturnsOthers ->
            throw400 NotSupported $
              "cannot define select permissions on computed field " <> fieldName
                <<> " which does not return existing table or scalar type"

  let deps =
        mkParentDep @b source tableName :
        boolExpDeps ++ map (mkColDep @b DRUntyped source tableName) pgCols
          ++ map (mkComputedFieldDep @b DRUntyped source tableName) validComputedFields
      spiRequiredHeaders = getDependentHeaders $ spFilter sp
      spiLimit = spLimit sp

  withPathK "limit" $ for_ spiLimit \value ->
    when (value < 0) $
      throw400 NotSupported "unexpected negative value"

  let spiCols = HM.fromList $ map (,Nothing) pgCols
      spiComputedFields = HS.toMap (HS.fromList validComputedFields) $> Nothing

  (spiAllowedQueryRootFields, spiAllowedSubscriptionRootFields) <-
    validateAllowedRootFields source tableName roleName streamSubsCtx sp

  return (SelPermInfo {..}, deps)
  where
    spiAllowAgg = spAllowAggregations sp
    computedFields = spComputedFields sp
    autoInferredErr = "permissions for relationships are automatically inferred"

buildUpdPermInfo ::
  forall b m.
  (QErrM m, TableCoreInfoRM b m, BackendMetadata b) =>
  SourceName ->
  TableName b ->
  FieldInfoMap (FieldInfo b) ->
  UpdPerm b ->
  m (WithDeps (UpdPermInfo b))
buildUpdPermInfo source tn fieldInfoMap (UpdPerm colSpec set fltr check backendOnly) = do
  (be, beDeps) <-
    withPathK "filter" $
      procBoolExp source tn fieldInfoMap fltr

  checkExpr <- traverse (withPathK "check" . procBoolExp source tn fieldInfoMap) check

  (setColsSQL, setHeaders, setColDeps) <- procSetObj source tn fieldInfoMap set

  -- check if the columns exist
  void $
    withPathK "columns" $
      indexedForM updCols $ \updCol -> do
        -- Check that all columns specified do in fact exist and are columns
        _ <- askColumnType fieldInfoMap updCol relInUpdErr
        -- Check that the column is updatable
        ci <- askColInfo fieldInfoMap updCol ""
        unless (_cmIsUpdatable $ ciMutability ci) $
          throw500
            ( "Column " <> updCol
                <<> " is not updatable and so cannot have update permissions defined"
            )

  let updColDeps = map (mkColDep @b DRUntyped source tn) allUpdCols
      deps = mkParentDep @b source tn : beDeps ++ maybe [] snd checkExpr ++ updColDeps ++ setColDeps
      depHeaders = getDependentHeaders fltr
      reqHeaders = depHeaders `HS.union` (HS.fromList setHeaders)
      updColsWithoutPreSets = updCols \\ HM.keys setColsSQL

  return (UpdPermInfo (HS.fromList updColsWithoutPreSets) tn be (fst <$> checkExpr) setColsSQL backendOnly reqHeaders, deps)
  where
    allUpdCols = map ciColumn $ filter (_cmIsUpdatable . ciMutability) $ getCols fieldInfoMap
    updCols = interpColSpec allUpdCols colSpec
    relInUpdErr = "Only table columns can have update permissions defined, not relationships or other field types"

buildDelPermInfo ::
  forall b m.
  (QErrM m, TableCoreInfoRM b m, BackendMetadata b) =>
  SourceName ->
  TableName b ->
  FieldInfoMap (FieldInfo b) ->
  DelPerm b ->
  m (WithDeps (DelPermInfo b))
buildDelPermInfo source tn fieldInfoMap (DelPerm fltr backendOnly) = do
  (be, beDeps) <-
    withPathK "filter" $
      procBoolExp source tn fieldInfoMap fltr
  let deps = mkParentDep @b source tn : beDeps
      depHeaders = getDependentHeaders fltr
  return (DelPermInfo tn be backendOnly depHeaders, deps)

data SetPermComment b = SetPermComment
  { apSource :: !SourceName,
    apTable :: !(TableName b),
    apRole :: !RoleName,
    apPermission :: !PermType,
    apComment :: !(Maybe Text)
  }

instance (Backend b) => FromJSON (SetPermComment b) where
  parseJSON = withObject "SetPermComment" $ \o ->
    SetPermComment
      <$> o .:? "source" .!= defaultSource
      <*> o .: "table"
      <*> o .: "role"
      <*> o .: "permission"
      <*> o .:? "comment"

runSetPermComment ::
  forall b m.
  (QErrM m, CacheRWM m, MetadataM m, BackendMetadata b) =>
  SetPermComment b ->
  m EncJSON
runSetPermComment (SetPermComment source table roleName permType comment) = do
  tableInfo <- askTableInfo @b source table

  -- assert permission exists and return appropriate permission modifier
  permModifier <- case permType of
    PTInsert -> do
      assertPermDefined roleName PTInsert tableInfo
      pure $ tmInsertPermissions . ix roleName . pdComment .~ comment
    PTSelect -> do
      assertPermDefined roleName PTSelect tableInfo
      pure $ tmSelectPermissions . ix roleName . pdComment .~ comment
    PTUpdate -> do
      assertPermDefined roleName PTUpdate tableInfo
      pure $ tmUpdatePermissions . ix roleName . pdComment .~ comment
    PTDelete -> do
      assertPermDefined roleName PTDelete tableInfo
      pure $ tmDeletePermissions . ix roleName . pdComment .~ comment

  let metadataObject =
        MOSourceObjId source $
          AB.mkAnyBackend $
            SMOTableObj @b table $
              MTOPerm roleName permType
  buildSchemaCacheFor metadataObject $
    MetadataModifier $
      tableMetadataSetter @b source table %~ permModifier
  pure successMsg
