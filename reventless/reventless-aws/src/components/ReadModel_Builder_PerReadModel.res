module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_PerEventCollector

module type Config = {
  let specModulePath: string
  let mappingsModulePath: string
}

module Make = (
  Spec: Reventless.ReadModel.Spec,
  Mappings: Reventless.Projection.Mappings with module Target := Spec,
  Config: Config,
): (
  ReventlessInfra.ReadModel.T
    with module Spec = Spec
    and type api = Types.AppSync.api
    and type role = Types.AppSync.role
) => {
  module Inner = ReventlessCore.ReadModel_Builder.Make(
    Spec,
    Mappings,
    RuntimeEnvironment,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
  )

  module Spec = Inner.Spec
  module EventCollectorRuntimeBuilder = EventCollectorRuntimeBuilder

  type api = Inner.api
  type role = Inner.role
  type component = Inner.component

  let make = (~api, ~apiRole, ~allEventTopics, ~opts=?): component => {
    let readModel = Inner.make(~api, ~apiRole, ~allEventTopics, ~opts?)

    let queryDbOutputs = (readModel->Inner.outputs).queryDb
    let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
    let queryDbTableName = tableResource.name

    EventCollectorRuntimeBuilder.registerReadModel(
      ~readModelName=Spec.name,
      ~specModulePath=Config.specModulePath,
      ~mappingsModulePath=Config.mappingsModulePath,
      ~queryDbTableName,
    )

    readModel
  }

  let sourceNames = Inner.sourceNames
  let outputs = Inner.outputs
  let operations = Inner.operations
  let finish = () => EventCollectorRuntimeBuilder.finish()
}
