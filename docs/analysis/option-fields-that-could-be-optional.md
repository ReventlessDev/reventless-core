# Record fields typed `option` that could be optional fields

**Status:** Inventory, 2026-10-25, produced by `pnpm run inventory:option-fields` over the sources on
`alpha`. No code changes. Counts are of
record fields written `name: option<...>` in record type declarations; a field already written
`name?: T` is not counted.

## In plain words

ReScript has two ways to say a record field may be missing. `name: option<T>` makes the field
mandatory to write and lets its value be `None`. `name?: T` makes the field itself optional: a
record may be built without it, and reading it still gives an `option<T>`. For a record that sury
serializes, the two compile to the same schema, so the JSON, the JSON Schema and the GraphQL type
are identical either way. The difference is only in the ReScript source: how many places have to
write `: None` to build a value, and how a reader destructures it.

That makes the question one of ergonomics, not of compatibility. The scan found 245 such fields in
133 record types. They sort into six groups, from "move them" to "leave them".

## What the two spellings change, and what they do not

- **The wire is the same.** `sury-ppx` compiles both to `Sury.$option(...)`, as the compiled
  `Plugin.res.mjs` shows for `chapter: option<string>` and `requiredRoles?: array<string>` side by
  side. Persisted events, stored structures and GraphQL types are untouched by a change of spelling.
- **Construction changes.** With `option`, every literal must name the field, which is why the
  plugin structure's literals in eight test files and two source files carry eleven lines of
  `: None,` each. With an optional field those lines go, and adding a field to the record is a
  one-line change rather than an edit to every literal. A field nobody has to write cannot be
  forgotten, which is the failure a required structure field once caused at plugin registration.
- **Reading changes a little.** `r.field` yields `option<T>` in both spellings. Destructuring a
  `Some` in a pattern becomes `{field: ?Some(x)}`. A function taking the field by name is unchanged.
- **The PPX passes already accept both.** The owner, retired and semantic passes unwrap the optional
  schema the same way for either spelling, and the user guide says so for `@owner` and `@retired`.
- **What it does not buy.** A `None` that is a *stated value* the code switches on (a challenge not
  yet issued, a window with no end) reads better as `option`: the `None` arm in a `switch` is the
  decision, and an optional field hides that a value was deliberately not set.

The rule that falls out: **where absence means "not given", prefer the optional field; where
`None` is a value the logic acts on, keep `option`.**

## The six groups

### Group A: the published plugin structure, move them

| File | Type | Fields | Which |
|---|---|---|---|
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `panelManifestEntry` | 1 | `requiredAccess` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `menuEntry` | 2 | `icon`, `group` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `pageManifestEntry` | 1 | `requiredAccess` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `fieldReference` | 1 | `plugin` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `commandDef` | 6 | `aggregateIdField`, `allowedStates`, `targetState`, `apiExposed`, `requiredAccess`, `ownerField` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `readSideDef` | 12 | `labelFieldSource`, `lifecycleField`, `ownerField`, `retiredField`, `retiredValues`, `namedWhenRetired`, `visibility`, `chapter`, `singleQueryField`, `idField`, `idFieldSource`, `requiredAccess` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `writeSideDef` | 2 | `consistencyRead`, `chapter` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `automationSliceDef` | 1 | `chapter` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `outboundTranslationSliceDef` | 4 | `targetName`, `externalSystem`, `chapter`, `consumedSources` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `inboundTranslationSliceDef` | 2 | `externalSystem`, `chapter` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `extensionDef` | 2 | `handledEvents`, `issuedCommands` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `extensionPointDef` | 3 | `commandTypes`, `publishedEvents`, `acceptedCommands` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `requiredStoreDeclaration` | 1 | `annotation` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `pluginStructure` | 7 | `extensionPoints`, `requiredStores`, `requiredStoreDeclarations`, `requiredCapabilities`, `traitDeclarations`, `admission`, `admissionDoors` |
| [Plugin.res](../../reventless/spec/src/components/Plugin.res) | `pluginDefinition` | 2 | `apiTarget`, `dcbEventLog` |

The records a plugin's structure is made of. Every one of these fields is documented "absent → None,
read as []" or is an annotation a spec may or may not carry. They are built in one place
(`Plugin_Structure`), decoded from stored JSON everywhere else, and written as literals in eight
test files and two sources. Moving them removes the `: None,` lines, makes adding a field safe for
old readers and old literals alike, and changes nothing on the wire. The highest value in the
inventory, and one change that touches ten files.

### Group B: command-line arguments, move them

| File | Type | Fields | Which |
|---|---|---|---|
| [BakeManifest.res](../../reventless/aws/scripts/BakeManifest.res) | `args` | 3 | `manifest`, `stack`, `since` |
| [BakeManifest.res](../../reventless/aws/scripts/BakeManifest.res) | `registration` | 2 | `found`, `writtenAt` |
| [BakeManifest.res](../../reventless/aws/scripts/BakeManifest.res) | `settled` | 1 | `summary` |
| [DeployApp.res](../../reventless/aws/scripts/DeployApp.res) | `args` | 2 | `command`, `manifest` |
| [DeployApp.res](../../reventless/aws/scripts/DeployApp.res) | `project` | 1 | `region` |
| [DeployManifest.res](../../reventless/aws/scripts/DeployManifest.res) | `project` | 1 | `region` |
| [DeployManifest.res](../../reventless/aws/scripts/DeployManifest.res) | `resolved` | 1 | `region` |
| [ProvisionAccounts.res](../../reventless/aws/scripts/ProvisionAccounts.res) | `args` | 3 | `providerId`, `stack`, `file` |
| [ProvisionAdmin.res](../../reventless/aws/scripts/ProvisionAdmin.res) | `args` | 3 | `providerId`, `stack`, `email` |
| [ProvisionIdentity.res](../../reventless/aws/scripts/ProvisionIdentity.res) | `args` | 1 | `providerId` |
| [ResolveEnvironment.res](../../reventless/aws/scripts/ResolveEnvironment.res) | `args` | 2 | `file`, `manifest` |
| [CliArgs.res](../../reventless/spec/src/CliArgs.res) | `observed` | 1 | `exitCode` |
| [PrepareAccounts.res](../../reventless/spec/src/types/PrepareAccounts.res) | `args` | 1 | `file` |

A flag the caller did not pass. Every `CliArgs` parse builds one of these, and nothing else does.
Pure ergonomics, no readers to adjust beyond the one parse function per tool.

### Group C: bindings to JavaScript APIs, move them

| File | Type | Fields | Which |
|---|---|---|---|
| [Kinesis.res](../../rescript/aws-sdk/src/Kinesis.res) | `output` | 1 | `encryptionType` |
| [SecretsManager.res](../../rescript/aws-sdk/src/SecretsManager.res) | `output` | 1 | `versionStage` |
| [SQS.res](../../rescript/aws-sdk/src/SQS.res) | `output` | 1 | `sequenceNumber` |
| [SQS.res](../../rescript/aws-sdk/src/SQS.res) | `t` | 1 | `message` |
| [SQS.res](../../rescript/aws-sdk/src/SQS.res) | `sendMessageBatchResultEntry` | 1 | `sequenceNumber` |
| [McpSdk.res](../../rescript/mcp-sdk/src/McpSdk.res) | `callToolParams` | 1 | `arguments` |
| [Lambda.res](../../rescript/pulumi-aws/src/Lambda/Lambda.res) | `clientContext` | 1 | `custom` |
| [S3_Bucket.res](../../rescript/pulumi-aws/src/S3/S3_Bucket.res) | `subscription` | 1 | `opts` |
| [GetSecretVersion.res](../../rescript/pulumi-aws/src/SecretsManager/GetSecretVersion.res) | `t` | 1 | `versionStage` |
| [SNS_Topic.res](../../rescript/pulumi-aws/src/SNS/SNS_Topic.res) | `message` | 1 | `subject` |

Payloads and results of JavaScript libraries, where the convention is an absent key. An optional
field is the honest binding: the key is there or it is not, and `None` written as a value would
still be sent as an absent key. The compiled output does not change. One field each, so each is a
two-line change beside its external.

### Group D: runtime and deploy configuration built in one place, move when touched

| File | Type | Fields | Which |
|---|---|---|---|
| [AppSync_EventsApi.res](../../reventless/aws/src/adapter/Api/AppSync_EventsApi.res) | `t` | 1 | `defaultNamespace` |
| [Platform_ComponentDefinitions_Lambda_Ops.res](../../reventless/aws/src/adapter/Api/Platform_ComponentDefinitions_Lambda_Ops.res) | `registration` | 2 | `found`, `writtenAt` |
| [DcbEventLogStorage_DynamoDb_Runtime.res](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res) | `scanFilter` | 3 | `filterExpression`, `expressionAttributeNames`, `expressionAttributeValues` |
| [DcbEventLogStorage_DynamoDb_Runtime.res](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res) | `mergeSlot` | 1 | `head` |
| [PgQueryResolver_Lambda.res](../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res) | `binding` | 5 | `subIdField`, `ownerField`, `retiredField`, `retiredValues`, `imageSource` |
| [AggregateRuntime_Builder_Micro_Async.res](../../reventless/aws/src/adapter/Runtime/AggregateRuntime_Builder_Micro_Async.res) | `aggregateInfo` | 1 | `mappingsModulePath` |
| [AggregateRuntime_Builder_Micro.res](../../reventless/aws/src/adapter/Runtime/AggregateRuntime_Builder_Micro.res) | `aggregateInfo` | 1 | `mappingsModulePath` |
| [AutomationSliceEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/AutomationSliceEntryPoint_Ops.res) | `handlerEntry` | 3 | `commandQueueIsFifo`, `context`, `schedulesTableName` |
| [AutomationSliceEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/AutomationSliceEntryPoint_Ops.res) | `builtSlice` | 1 | `reconcile` |
| [AutomationSliceRuntime_Builder_Single.res](../../reventless/aws/src/adapter/Runtime/AutomationSliceRuntime_Builder_Single.res) | `sliceInfo` | 3 | `context`, `commandTargetName`, `schedule` |
| [DcbCommandTopicEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res) | `derivedScope` | 1 | `partitionTag` |
| [DcbCommandTopicEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res) | `inboundCallback` | 1 | `webhook` |
| [EventCollectorEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res) | `handlerConfig` | 1 | `connectExtension` |
| [EventCollectorEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res) | `pluginProjection` | 1 | `dcbEventLog` |
| [PgQueryResolverEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/PgQueryResolverEntryPoint_Ops.res) | `resolverConfig` | 1 | `pgConnection` |
| [PgQueryResolverEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/PgQueryResolverEntryPoint_Ops.res) | `specInfo` | 2 | `config`, `subIdConfig` |
| [ReadModelEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/ReadModelEntryPoint_Ops.res) | `handlerEntry` | 4 | `comp`, `plugin`, `pgConnection`, `stateTopicName` |
| [ReadModelEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/ReadModelEntryPoint_Ops.res) | `specInfo` | 3 | `config`, `subIdConfig`, `stateSchema` |
| [RuntimeExtensionEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/RuntimeExtensionEntryPoint_Ops.res) | `config` | 2 | `plugin`, `platform` |
| [SideEffectEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/SideEffectEntryPoint_Ops.res) | `handlerEntry` | 2 | `comp`, `plugin` |
| [StateViewSliceEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/StateViewSliceEntryPoint_Ops.res) | `handlerEntry` | 2 | `stateTopicName`, `pgConnection` |
| [StateViewSliceEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/StateViewSliceEntryPoint_Ops.res) | `sliceModules` | 3 | `config`, `subIdConfig`, `stateSchema` |
| [TaskBucketEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/TaskBucketEntryPoint_Ops.res) | `handlerConfig` | 1 | `scheduler` |
| [AppSync_Adapter.res](../../reventless/aws/src/components/Api/AppSync_Adapter.res) | `sourceApiAssociationSummary` | 2 | `sourceApiAssociationStatus`, `sourceApiAssociationStatusDetail` |
| [AppSync_Adapter.res](../../reventless/aws/src/components/Api/AppSync_Adapter.res) | `getSourceApiAssociationResult` | 1 | `sourceApiAssociation` |
| [Platform_Stack.res](../../reventless/aws/src/Platform_Stack.res) | `cognitoUserPool` | 1 | `loginIdentifier` |
| [Platform.res](../../reventless/aws/src/Platform.res) | `objectStoreEndpoint` | 1 | `baseUrl` |
| [PluginExtensionPointRuntime_Builder.res](../../reventless/aws/src/plugin/runtime/PluginExtensionPointRuntime_Builder.res) | `adminExtras` | 2 | `pluginReadModelTableName`, `schedulerRoleArn` |
| [PluginRuntime_Builder.res](../../reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res) | `adminConfig` | 6 | `eventTopicArn`, `pluginReadModelTableName`, `schedulerRoleArn`, `schedulerQueueArn`, `schedulerQueueName`, `appSyncApiId` |
| [PluginRuntime_Builder.res](../../reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res) | `dcbConfig` | 1 | `dcbTableName` |
| [PluginRuntime_Builder.res](../../reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res) | `heartbeatConfig` | 1 | `epQueueUrl` |
| [Monitoring.res](../../reventless/core/src/adapter/Monitoring/Monitoring.res) | `announcement` | 3 | `plugin`, `platform`, `logLocator` |
| [ResourceAttribution.res](../../reventless/core/src/ResourceAttribution.res) | `context` | 1 | `platform` |
| [FTPHandler.res](../../reventless/core/src/util/FTPHandler.res) | `connectionParams` | 2 | `port`, `readyTimeout` |
| [ScheduleTime.res](../../reventless/core/src/util/ScheduleTime.res) | `awsSchedule` | 2 | `timezone`, `startDate` |
| [RuntimeHints.res](../../reventless/infra/src/types/RuntimeHints.res) | `t` | 2 | `memorySize`, `timeout` |
| [Config.res](../../reventless/spec/src/generator/Config.res) | `runtimeHints` | 2 | `memorySize`, `timeout` |

Records the AWS adapters hand from the deploy program to a function's entry point, and a few
framework-level configuration records. Each is built by one builder and read by one entry point.
Moving them is safe and saves the builders their `None` lines, but each saves little on its own;
do it when the file is next edited rather than as a sweep.

### Group E: internal results and tool records, case by case

| File | Type | Fields | Which |
|---|---|---|---|
| [NotificationDeliveries.res](../../examples/online-shop-hybrid/ordering/src/Notification/StateViewStream/NotificationDeliveries.res) | `state` | 1 | `settledAt` |
| [Orders.res](../../examples/online-shop-hybrid/ordering/src/Order/StateViewStream/Orders.res) | `state` | 2 | `deliveryWindow`, `firstProductName` |
| [RegistrationWindows.res](../../examples/online-shop-hybrid/registration/src/Registration/StateViewStream/RegistrationWindows.res) | `state` | 1 | `until` |
| [Auth_ActiveRole.res](../../reventless/core/src/adapter/Auth/Auth_ActiveRole.res) | `conformanceCase` | 2 | `requested`, `expected` |
| [Platform_Admin.res](../../reventless/core/src/admin/Platform_Admin.res) | `outputs` | 1 | `dcbEventLogOutputs` |
| [Platform_BakedManifest.res](../../reventless/core/src/admin/Platform_BakedManifest.res) | `selection` | 3 | `views`, `commands`, `derived` |
| [GraphQL_SchemaInspector.res](../../reventless/core/src/components/Api/GraphQL_SchemaInspector.res) | `queryFieldInspection` | 2 | `typeDef`, `listQuery` |
| [AutomationSlice_Route.res](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Route.res) | `routed` | 1 | `resolved` |
| [CommandTopic_Builder.res](../../reventless/core/src/components/CommandTopic/CommandTopic_Builder.res) | `operations` | 1 | `publishJsonsAndWait` |
| [CommandTopic.res](../../reventless/core/src/components/CommandTopic/CommandTopic.res) | `operations` | 1 | `publishJsonsAndWait` |
| [Dcb_Builder.res](../../reventless/core/src/components/Dcb/Dcb_Builder.res) | `dcbResult` | 3 | `dcbEventLogOutputs`, `dcbRuntimeSetup`, `dcbPublishJsons` |
| [Plugin_Helpers.res](../../reventless/core/src/plugin/component/Plugin_Helpers.res) | `builderOutputs` | 2 | `dcbEventLog`, `uiFragments` |
| [Plugin_Helpers.res](../../reventless/core/src/plugin/component/Plugin_Helpers.res) | `eventCollectorContext` | 1 | `connectExtension` |
| [PluginDecision.res](../../reventless/core/src/plugin/lifecycle/PluginDecision.res) | `state` | 1 | `current` |
| [PluginsReadModelSpec.res](../../reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res) | `state` | 4 | `apiSchemaFragment`, `structure`, `dcbEventLog`, `kind` |
| [PluginsReadModelSpec.res](../../reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res) | `queryResult` | 4 | `apiSchemaFragment`, `structure`, `dcbEventLog`, `kind` |
| [Projection.res](../../reventless/core/src/Projection.res) | `overlays` | 1 | `displayName` |
| [GraphQL_ServerInstance.res](../../reventless/graphql-server/src/GraphQL_ServerInstance.res) | `diagnostics` | 1 | `fullSdl` |
| [Api.res](../../reventless/infra/src/components/Api.res) | `querySchemaEntry` | 1 | `authorization` |
| [InboundTranslationResolvers_GraphQL.res](../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res) | `pendingCall` | 1 | `caller` |
| [SortKey_Filter.res](../../reventless/local/src/adapter/QueryDb/SortKey_Filter.res) | `result` | 1 | `nextToken` |
| [LocalPlatformRegistry.res](../../reventless/local/src/LocalPlatformRegistry.res) | `store` | 1 | `path` |
| [EventLogChangeFeed.res](../../reventless/postgres/src/EventLogChangeFeed.res) | `classicEvent` | 1 | `msgId` |
| [EventLogChangeFeed.res](../../reventless/postgres/src/EventLogChangeFeed.res) | `batch` | 1 | `cursor` |
| [PgChangeFeed.res](../../reventless/postgres/src/PgChangeFeed.res) | `batch` | 1 | `cursor` |
| [ReventlessSeedAws_Quiesce.res](../../reventless/seed-aws/src/ReventlessSeedAws_Quiesce.res) | `held` | 1 | `priorReserved` |
| [Seed_Connect.res](../../reventless/seed/src/Seed_Connect.res) | `connection` | 2 | `callerId`, `roleSwitch` |
| [Seed_Users.res](../../reventless/seed/src/Seed_Users.res) | `user` | 2 | `userId`, `demoOwner` |
| [DcbScopeInference.res](../../reventless/spec/src/components/DcbScopeInference.res) | `sliceShape` | 1 | `partitionHint` |
| [StateAnnotations.res](../../reventless/spec/src/components/StateAnnotations.res) | `retiredSpec` | 1 | `values` |
| [StateAnnotations.res](../../reventless/spec/src/components/StateAnnotations.res) | `stateAnnotationSpec` | 5 | `lifecycle`, `groupBy`, `visibility`, `live`, `retired` |
| [Discovery.res](../../reventless/spec/src/generator/Discovery.res) | `discoveredFile` | 1 | `epGroup` |
| [Pairing.res](../../reventless/spec/src/generator/Pairing.res) | `extensionPointDef` | 1 | `group` |
| [PlatformCodegen.res](../../reventless/spec/src/generator/PlatformCodegen.res) | `provenance` | 2 | `field`, `annotation` |
| [CheckLifecycleModel.res](../../reventless/spec/src/lifecycle/CheckLifecycleModel.res) | `declaredCommand` | 4 | `aggregateIdField`, `allowedStates`, `targetState`, `allowedStatesSource` |
| [Geocoding.res](../../reventless/spec/src/semantic/Geocoding.res) | `candidate` | 1 | `relevance` |
| [Semantic.res](../../reventless/spec/src/semantic/Semantic.res) | `storeTarget` | 1 | `plugin` |
| [Semantic.res](../../reventless/spec/src/semantic/Semantic.res) | `memberTarget` | 3 | `view`, `plugin`, `content` |
| [Template.res](../../reventless/spec/src/semantic/Template.res) | `scope` | 1 | `value` |
| [AccountsManifest.res](../../reventless/spec/src/types/AccountsManifest.res) | `fill` | 2 | `password`, `userId` |
| [DeploymentProvenance.res](../../reventless/spec/src/types/DeploymentProvenance.res) | `t` | 5 | `commit`, `environment`, `purpose`, `tag`, `pullRequest` |
| [OwnerScope.res](../../reventless/spec/src/types/OwnerScope.res) | `retiredScope` | 1 | `values` |

Results, cursors, annotations and seed records inside the framework and its tools. Most would read
fine either way. A few have a `None` the code acts on, such as `partitionHint`, `retired` or the
`nextToken` of a page, and those should stay. No reason to touch them except in passing.

### Group F: decision state, guards and test harnesses, keep them

| File | Type | Fields | Which |
|---|---|---|---|
| [SyncCatalogProduct_Decision.res](../../examples/online-shop-hybrid/ordering/src/CatalogProduct/StateChange/SyncCatalogProduct_Decision.res) | `state` | 2 | `price`, `productImage` |
| [ContactVerification_Guards.res](../../examples/online-shop-hybrid/ordering/src/ContactVerification_Guards.res) | `verification` | 1 | `verifiedAddress` |
| [EmailVerificationChallenges_Decision.res](../../examples/online-shop-hybrid/ordering/src/Customer/StateChange/EmailVerificationChallenges_Decision.res) | `state` | 1 | `current` |
| [ContactVerification_Guards.res](../../examples/online-shop-hybrid/registration/src/ContactVerification_Guards.res) | `verification` | 1 | `verifiedAddress` |
| [Registrations_Decision.res](../../examples/online-shop-hybrid/registration/src/Registration/StateChange/Registrations_Decision.res) | `pending` | 2 | `challenge`, `proofHash` |
| [Registrations_Decision.res](../../examples/online-shop-hybrid/registration/src/Registration/StateChange/Registrations_Decision.res) | `state` | 1 | `lastNoticeAt` |
| [DemoData.res](../../examples/online-shop-hybrid/seed-data/src/DemoData.res) | `category` | 1 | `categoryImage` |
| [DemoData.res](../../examples/online-shop-hybrid/seed-data/src/DemoData.res) | `product` | 1 | `productImage` |
| [DemoData.res](../../examples/online-shop-hybrid/seed-data/src/DemoData.res) | `order` | 1 | `deliveryWindow` |
| [DemoData.res](../../examples/online-shop-hybrid/seed-data/src/DemoData.res) | `placedOrder` | 1 | `deliveryWindow` |
| [ShopSnapshot.res](../../examples/online-shop-hybrid/seed-data/src/ShopSnapshot.res) | `order` | 1 | `deliveryWindow` |
| [Flow_GWT.res](../../reventless/gwt/src/Flow_GWT.res) | `logEntry` | 1 | `aggregateId` |
| [Flow_GWT.res](../../reventless/gwt/src/Flow_GWT.res) | `flowState` | 3 | `lastError`, `lastAggregateId`, `lastRefusal` |
| [Hint.res](../../reventless/gwt/src/Hint.res) | `t` | 1 | `branch` |
| [AddressGeocoding_Guards.res](../../traits/address-geocoding/src/AddressGeocoding_Guards.res) | `resolution` | 2 | `location`, `resolvedFrom` |
| [Attachments_Rules.res](../../traits/attachments/src/Attachments_Rules.res) | `t` | 1 | `primary` |

Here `None` is a fact the code decides on: a registration whose challenge has not gone out, a
product with no price yet, a resolution that found no location, the last error of a flow test. The
`switch` on `None` is the logic, and an optional field would hide that the value was chosen. The
seed-data records are literal fixtures where an explicit `None` says "this product has no image" on
purpose. Leave these as they are.

## Recommendation

Move groups A to E, one commit each, and leave group F alone. None of it needs a migration, a
golden refresh or a documentation change, because nothing reaches the wire.
[The plan](../plans/option-fields-become-optional.md) orders the five steps, decides group E record
by record, and names the script that does the mechanical part.

## How the inventory was made

`pnpm run inventory:option-fields` runs [the script](../../scripts/inventory-option-fields.mjs)
behind this document. It reads every tracked `.res` file outside `tests/`, `lib/` and the
documentation site, blanks comments so documented examples are not read as declarations, skips
module types, finds every record type body and lists its fields written `name: option<...>`. The
grouping is a heuristic by file role, spelled out in the script; this document's tables are its
output. Re-run it after a refactor to check a group off, and whenever a record is added, so the
inventory never has to be made by hand again.
