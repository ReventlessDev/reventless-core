module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledStateViewSliceInfo = {
  specModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
}

let bundledInfos: dict<bundledStateViewSliceInfo> = Dict.make()

let registerStateViewSlice = (
  ~name,
  ~specModulePath,
  ~queryDbTableName,
) =>
  bundledInfos->Dict.set(name, {specModulePath, queryDbTableName})

include ProjectionRuntime_Builder_Single.Make({
  type info = bundledStateViewSliceInfo
  type registration = Util_EntryPoint.stateViewSliceRegistration

  let name = "AllStateViewSlices"
  let builderName = "StateViewSliceRuntime_Builder_Single"
  let factoryModulePath =
    "@reventlessdev/reventless-aws/src/adapter/Runtime/StateViewSliceHandlerFactory.mjs"
  let infos = bundledInfos

  let processHandler = (~envVars, ~info, ~indexStr, ~sourceUrnEnvVar) => {
    let tableEnvVar = `HANDLER_${indexStr}_TABLE`
    envVars->Dict.set(tableEnvVar, info.queryDbTableName->Pulumi.Output.asInput)
    {
      Util_EntryPoint.specModulePath: info.specModulePath,
      queryDbTableEnvVar: tableEnvVar,
      sourceUrnEnvVar,
    }
  }

  let generateEntryPoint = (name, handlers, factoryModule, requestContextModule) =>
    Util_EntryPoint.generateStateViewSliceEntryPoint({
      name,
      handlers,
      factoryModule,
      requestContextModule,
    })
})
