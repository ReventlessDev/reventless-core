module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_Single

module Make = (
  Spec: Reventless.ReadModel.Spec,
  Mappings: Reventless.Projection.Mappings with module Target := Spec,
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
    QueryDbStorage.Selectable,
    QueryDbResolvers.Selectable,
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

    // On the Postgres backend there is no DynamoDB table (resources is empty) —
    // the read-model spec name is the stable `qdb_<name>` discriminator, both
    // here and in the entry point's Postgres branch.
    let pgBacked = QueryDbBackend.isPostgresFor(Spec.name)
    let queryDbTableName = if pgBacked {
      Pulumi.Output.make(Spec.name)
    } else {
      let queryDbOutputs = (readModel->Inner.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      tableResource.name
    }

    EventCollectorRuntimeBuilder.registerReadModel(
      ~readModelName=Spec.name,
      ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
      ~mappingsModulePath=Util_Bundle.getModuleSpecifier(Mappings.moduleUrl),
      ~queryDbTableName,
      ~pgBacked,
    )

    readModel
  }

  let sourceNames = Inner.sourceNames
  let consumedEventNames = Inner.consumedEventNames
  let outputs = Inner.outputs
  let operations = Inner.operations
  let finish = () => EventCollectorRuntimeBuilder.finish()
}
