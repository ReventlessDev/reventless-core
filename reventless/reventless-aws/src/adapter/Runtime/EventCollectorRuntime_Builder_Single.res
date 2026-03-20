module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledReadModelInfo = {
  specModulePath: string,
  mappingsModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
}

let bundledReadModelInfos: dict<bundledReadModelInfo> = Dict.make()

let registerReadModel = (
  ~readModelName,
  ~specModulePath,
  ~mappingsModulePath,
  ~queryDbTableName,
) =>
  bundledReadModelInfos->Dict.set(
    readModelName,
    {specModulePath, mappingsModulePath, queryDbTableName},
  )

include ProjectionRuntime_Builder_Single.Make({
  type info = bundledReadModelInfo
  type registration = Util_EntryPoint.readModelRegistration

  let name = "AllReadModels"
  let builderName = "EventCollectorRuntime_Builder_Single"
  let factoryModulePath =
    "@reventlessdev/reventless-aws/src/adapter/Runtime/ReadModelHandlerFactory.mjs"
  let infos = bundledReadModelInfos

  let processHandler = (~envVars, ~info, ~indexStr, ~sourceUrnEnvVar) => {
    let tableEnvVar = `HANDLER_${indexStr}_TABLE`
    envVars->Dict.set(tableEnvVar, info.queryDbTableName->Pulumi.Output.asInput)
    {
      Util_EntryPoint.specModulePath: info.specModulePath,
      mappingsModulePath: info.mappingsModulePath,
      queryDbTableEnvVar: tableEnvVar,
      sourceUrnEnvVar,
    }
  }

  let generateEntryPoint = (name, handlers, factoryModule, requestContextModule) =>
    Util_EntryPoint.generateReadModelEntryPoint({
      name,
      handlers,
      factoryModule,
      requestContextModule,
    })
})
