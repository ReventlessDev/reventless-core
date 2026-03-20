module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledSideEffectInfo = {
  sideEffectModulePaths: array<string>,
}

let bundledSideEffectInfos: dict<bundledSideEffectInfo> = Dict.make()

let registerSideEffectHandler = (~sideEffectHandlerName, ~sideEffectModulePaths) =>
  bundledSideEffectInfos->Dict.set(sideEffectHandlerName, {sideEffectModulePaths: sideEffectModulePaths})

include ProjectionRuntime_Builder_Single.Make({
  type info = bundledSideEffectInfo
  type registration = Util_EntryPoint.sideEffectRegistration

  let name = "AllSideEffectHandlers"
  let builderName = "SideEffectHandlerRuntime_Builder_Single"
  let factoryModulePath =
    "@reventlessdev/reventless-aws/src/adapter/Runtime/SideEffectHandlerFactory.mjs"
  let infos = bundledSideEffectInfos

  let processHandler = (~envVars as _, ~info, ~indexStr as _, ~sourceUrnEnvVar) => {
    Util_EntryPoint.sideEffectModulePaths: info.sideEffectModulePaths,
    sourceUrnEnvVar,
  }

  let generateEntryPoint = (name, handlers, factoryModule, requestContextModule) =>
    Util_EntryPoint.generateSideEffectEntryPoint({
      name,
      handlers,
      factoryModule,
      requestContextModule,
    })
})
