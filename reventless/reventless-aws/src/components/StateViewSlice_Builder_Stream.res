// StateViewSlice_Builder_Stream (AWS)
// Like StateViewSlice_Builder but uses QueryDbStorage_DynamoDbStream so that
// the QueryDb table has a DynamoDB Stream enabled. This allows StateTopic_AppSync
// to wire a Lambda that pushes state changes to the AppSync Events API (Source B
// subscriptions). Register in streamRegistry automatically on make.
//

module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = StateViewSliceRuntime_Builder_Single

module Make = (Api: {
  let api: unit => Types.AppSync.api
  let apiRole: unit => Types.AppSync.role
}) => {
  module Inner = ReventlessCore.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage.SelectableStream,
    QueryDbResolvers.Selectable,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  let finish = Inner.finish

  module Make = (
    Spec: Reventless.StateViewSlice.Spec,
    Projection: Reventless.StateViewSlice.Projection with module Spec := Spec,
  ): (ReventlessCore.StateViewSlice.T with module Spec = Spec) => {
    module InnerMake = Inner.Make(Spec, Projection)
    module Spec = Spec
    module Projection = Projection
    type component = InnerMake.component

    let make = (~dcbEventLog, ~opts=?): component => {
      let sv = InnerMake.make(~dcbEventLog, ~opts?)
      let queryDbOutputs = (sv->ReventlessCore.Component.outputs).queryDb
      // On the Postgres backend there is no DynamoDB table (resources is
      // empty) — the slice spec name is the stable `qdb_<name>` discriminator.
      let queryDbTableName = if QueryDbBackend.isPostgresFor(Spec.name) {
        Pulumi.Output.make(Spec.name)
      } else {
        (queryDbOutputs.resources->Array.getUnsafe(0)).name
      }
      EventCollectorRuntimeBuilder.registerStateViewSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~projectionModulePath=Util_Bundle.getModuleSpecifier(Projection.moduleUrl),
        ~queryDbTableName,
        ~queryDbResources=queryDbOutputs.resources,
      )
      sv
    }
  }
}
