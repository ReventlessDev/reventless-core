type handlerRegistration = {
  urn: string,
  handlerModule: string,
  handlerExport: string,
  handlerType: [#commandTopic | #eventCollector | #commandGenerator],
}

type entryPointConfig = {
  name: string,
  handlers: array<handlerRegistration>,
  shimModule: string,
  runtimeModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateAggregateEntryPoint: entryPointConfig => string = "generateAggregateEntryPoint"

type bundledHandlerRegistration = {
  specModulePath: string,
  behaviorModulePath: string,
  eventLogTableEnvVar: string,
  queueUrlEnvVar: string,
  queueArnEnvVar: string,
}

type bundledEntryPointConfig = {
  name: string,
  handlers: array<bundledHandlerRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledAggregateEntryPoint: bundledEntryPointConfig => string =
  "generateBundledAggregateEntryPoint"

type bundledReadModelRegistration = {
  specModulePath: string,
  mappingsModulePath: string,
  queryDbTableEnvVar: string,
  sourceUrnEnvVar: string,
}

type bundledReadModelEntryPointConfig = {
  name: string,
  handlers: array<bundledReadModelRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledReadModelEntryPoint: bundledReadModelEntryPointConfig => string =
  "generateBundledReadModelEntryPoint"

type bundledStateViewSliceRegistration = {
  specModulePath: string,
  queryDbTableEnvVar: string,
  sourceUrnEnvVar: string,
}

type bundledStateViewSliceEntryPointConfig = {
  name: string,
  handlers: array<bundledStateViewSliceRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledStateViewSliceEntryPoint: bundledStateViewSliceEntryPointConfig => string =
  "generateBundledStateViewSliceEntryPoint"

type bundledAutomationSliceRegistration = {
  specModulePath: string,
  queryDbTableEnvVar: string,
  dcbQueueUrlEnvVar: string,
  sourceUrnEnvVar: string,
}

type bundledAutomationSliceEntryPointConfig = {
  name: string,
  handlers: array<bundledAutomationSliceRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledAutomationSliceEntryPoint: bundledAutomationSliceEntryPointConfig => string =
  "generateBundledAutomationSliceEntryPoint"

@module("./Util_EntryPoint.mjs")
external generateBundledOutboundTranslationSliceEntryPoint: bundledAutomationSliceEntryPointConfig => string =
  "generateBundledOutboundTranslationSliceEntryPoint"

type bundledExtensionPointRegistration = {
  specModulePath: string,
  mappingsModulePath: string,
  queueUrlEnvVar: string,
  queueArnEnvVar: string,
  publishToAggregatesEnvVars: dict<string>,
}

type bundledExtensionPointEntryPointConfig = {
  name: string,
  handler: bundledExtensionPointRegistration,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledExtensionPointEntryPoint: bundledExtensionPointEntryPointConfig => string =
  "generateBundledExtensionPointEntryPoint"

type bundledPluginExtensionPointRegistration = {
  queueUrlEnvVar: string,
  queueArnEnvVar: string,
  publishToAggregatesEnvVars: dict<string>,
  pluginReadModelTableEnvVar: string,
  schedulerRoleArnEnvVar: string,
  schedulerQueueArnEnvVar: string,
  schedulerQueueNameEnvVar: string,
}

type bundledPluginExtensionPointEntryPointConfig = {
  name: string,
  handler: bundledPluginExtensionPointRegistration,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledPluginExtensionPointEntryPoint: bundledPluginExtensionPointEntryPointConfig => string =
  "generateBundledPluginExtensionPointEntryPoint"

type bundledCommandGeneratorEntryPointConfig = {
  name: string,
  factoryModule: string,
  requestContextModule: string,
  specModulePath: string,
  behaviorModulePath: string,
  queueUrlEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledCommandGeneratorEntryPoint: bundledCommandGeneratorEntryPointConfig => string =
  "generateBundledCommandGeneratorEntryPoint"

type bundledEventMapperEntryPointConfig = {
  name: string,
  factoryModule: string,
  requestContextModule: string,
  targetSpecModulePath: string,
  mappingsModulePath: string,
  queueUrlEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledEventMapperEntryPoint: bundledEventMapperEntryPointConfig => string =
  "generateBundledEventMapperEntryPoint"

type bundledAdminEventCollectorConfig = {
  name: string,
  factoryModule: string,
  requestContextModule: string,
  queueUrlEnvVar: string,
  eventTopicArnEnvVar: string,
  pluginReadModelTableEnvVar: string,
  schedulerRoleArnEnvVar: string,
  schedulerQueueArnEnvVar: string,
  schedulerQueueNameEnvVar: string,
  appSyncApiIdEnvVar: string,
  clonerEnabledEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledAdminEventCollectorEntryPoint: bundledAdminEventCollectorConfig => string =
  "generateBundledAdminEventCollectorEntryPoint"

type bundledSideEffectRegistration = {
  sideEffectModulePaths: array<string>,
  sourceUrnEnvVar: string,
}

type bundledSideEffectEntryPointConfig = {
  name: string,
  handlers: array<bundledSideEffectRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledSideEffectEntryPoint: bundledSideEffectEntryPointConfig => string =
  "generateBundledSideEffectEntryPoint"

type bundledTaskBucketEntryPointConfig = {
  name: string,
  callbackModulePath: string,
  factoryModule: string,
  requestContextModule: string,
  publishToAggregatesEnvVars: dict<string>,
}

@module("./Util_EntryPoint.mjs")
external generateBundledTaskBucketEntryPoint: bundledTaskBucketEntryPointConfig => string =
  "generateBundledTaskBucketEntryPoint"

type bundledCounterEntryPointConfig = {
  name: string,
  targetSpecModulePath: string,
  mappingsModulePath: string,
  factoryModule: string,
  requestContextModule: string,
  countsTableEnvVar: string,
  publishQueueUrlEnvVar: string,
  referencesStreamArnEnvVar: string,
  countsStreamArnEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledCounterEntryPoint: bundledCounterEntryPointConfig => string =
  "generateBundledCounterEntryPoint"

type bundledDcbSliceSpec = {specModulePath: string}

type bundledDcbCommandTopicEntryPointConfig = {
  name: string,
  factoryModule: string,
  requestContextModule: string,
  dcbTableEnvVar: string,
  queueUrlEnvVar: string,
  pluginName: string,
  stateChangeSliceSpecs: array<bundledDcbSliceSpec>,
}

@module("./Util_EntryPoint.mjs")
external generateBundledDcbCommandTopicEntryPoint: bundledDcbCommandTopicEntryPointConfig =>
string = "generateBundledDcbCommandTopicEntryPoint"

type bundledHeartbeatEntryPointConfig = {
  name: string,
  factoryModule: string,
  epQueueUrlEnvVar: string,
  pluginIdEnvVar: string,
  timeoutEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateBundledHeartbeatEntryPoint: bundledHeartbeatEntryPointConfig => string =
  "generateBundledHeartbeatEntryPoint"
