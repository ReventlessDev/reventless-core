type aggregateHandlerRegistration = {
  specModulePath: string,
  behaviorModulePath: string,
  eventLogTableEnvVar: string,
  queueUrlEnvVar: string,
  queueArnEnvVar: string,
}

type aggregateEntryPointConfig = {
  name: string,
  handlers: array<aggregateHandlerRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateAggregateEntryPoint: aggregateEntryPointConfig => string =
  "generateAggregateEntryPoint"

type readModelRegistration = {
  specModulePath: string,
  mappingsModulePath: string,
  queryDbTableEnvVar: string,
  sourceUrnEnvVar: string,
}

type readModelEntryPointConfig = {
  name: string,
  handlers: array<readModelRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateReadModelEntryPoint: readModelEntryPointConfig => string =
  "generateReadModelEntryPoint"

type stateViewSliceRegistration = {
  specModulePath: string,
  queryDbTableEnvVar: string,
  sourceUrnEnvVar: string,
}

type stateViewSliceEntryPointConfig = {
  name: string,
  handlers: array<stateViewSliceRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateStateViewSliceEntryPoint: stateViewSliceEntryPointConfig => string =
  "generateStateViewSliceEntryPoint"

type automationSliceRegistration = {
  specModulePath: string,
  queryDbTableEnvVar: string,
  dcbQueueUrlEnvVar: string,
  sourceUrnEnvVar: string,
}

type automationSliceEntryPointConfig = {
  name: string,
  handlers: array<automationSliceRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateAutomationSliceEntryPoint: automationSliceEntryPointConfig => string =
  "generateAutomationSliceEntryPoint"

@module("./Util_EntryPoint.mjs")
external generateOutboundTranslationSliceEntryPoint: automationSliceEntryPointConfig => string =
  "generateOutboundTranslationSliceEntryPoint"

type extensionPointRegistration = {
  specModulePath: string,
  mappingsModulePath: string,
  queueUrlEnvVar: string,
  queueArnEnvVar: string,
  publishToAggregatesEnvVars: dict<string>,
}

type extensionPointEntryPointConfig = {
  name: string,
  handler: extensionPointRegistration,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateExtensionPointEntryPoint: extensionPointEntryPointConfig => string =
  "generateExtensionPointEntryPoint"

type pluginExtensionPointRegistration = {
  queueUrlEnvVar: string,
  queueArnEnvVar: string,
  publishToAggregatesEnvVars: dict<string>,
  pluginReadModelTableEnvVar: string,
  schedulerRoleArnEnvVar: string,
  schedulerQueueArnEnvVar: string,
  schedulerQueueNameEnvVar: string,
}

type pluginExtensionPointEntryPointConfig = {
  name: string,
  handler: pluginExtensionPointRegistration,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generatePluginExtensionPointEntryPoint: pluginExtensionPointEntryPointConfig => string =
  "generatePluginExtensionPointEntryPoint"

type commandGeneratorEntryPointConfig = {
  name: string,
  factoryModule: string,
  requestContextModule: string,
  specModulePath: string,
  behaviorModulePath: string,
  queueUrlEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateCommandGeneratorEntryPoint: commandGeneratorEntryPointConfig => string =
  "generateCommandGeneratorEntryPoint"

type eventMapperEntryPointConfig = {
  name: string,
  factoryModule: string,
  requestContextModule: string,
  targetSpecModulePath: string,
  mappingsModulePath: string,
  queueUrlEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateEventMapperEntryPoint: eventMapperEntryPointConfig => string =
  "generateEventMapperEntryPoint"

type adminEventCollectorConfig = {
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
external generateAdminEventCollectorEntryPoint: adminEventCollectorConfig => string =
  "generateAdminEventCollectorEntryPoint"

type sideEffectRegistration = {
  sideEffectModulePaths: array<string>,
  sourceUrnEnvVar: string,
}

type sideEffectEntryPointConfig = {
  name: string,
  handlers: array<sideEffectRegistration>,
  factoryModule: string,
  requestContextModule: string,
}

@module("./Util_EntryPoint.mjs")
external generateSideEffectEntryPoint: sideEffectEntryPointConfig => string =
  "generateSideEffectEntryPoint"

type taskBucketEntryPointConfig = {
  name: string,
  callbackModulePath: string,
  factoryModule: string,
  requestContextModule: string,
  publishToAggregatesEnvVars: dict<string>,
}

@module("./Util_EntryPoint.mjs")
external generateTaskBucketEntryPoint: taskBucketEntryPointConfig => string =
  "generateTaskBucketEntryPoint"

type counterEntryPointConfig = {
  name: string,
  specModulePath: string,
  mappingsModulePath: string,
  factoryModule: string,
  requestContextModule: string,
  countsTableEnvVar: string,
  publishQueueUrlEnvVar: string,
  referencesStreamArnEnvVar: string,
  countsStreamArnEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateCounterEntryPoint: counterEntryPointConfig => string =
  "generateCounterEntryPoint"

type dcbSliceSpec = {specModulePath: string}

type dcbCommandTopicEntryPointConfig = {
  name: string,
  factoryModule: string,
  requestContextModule: string,
  dcbTableEnvVar: string,
  queueUrlEnvVar: string,
  pluginName: string,
  stateChangeSliceSpecs: array<dcbSliceSpec>,
}

@module("./Util_EntryPoint.mjs")
external generateDcbCommandTopicEntryPoint: dcbCommandTopicEntryPointConfig =>
string = "generateDcbCommandTopicEntryPoint"

type heartbeatEntryPointConfig = {
  name: string,
  factoryModule: string,
  epQueueUrlEnvVar: string,
  pluginIdEnvVar: string,
  timeoutEnvVar: string,
}

@module("./Util_EntryPoint.mjs")
external generateHeartbeatEntryPoint: heartbeatEntryPointConfig => string =
  "generateHeartbeatEntryPoint"
