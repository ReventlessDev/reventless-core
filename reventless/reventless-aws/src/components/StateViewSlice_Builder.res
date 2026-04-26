// StateViewSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.StateViewSlice_Builder.

module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = StateViewSliceRuntime_Builder_Single

module Make = (Api: {
  let api: unit => Types.AppSync.api
  let apiRole: unit => Types.AppSync.role
}) => {
  module Inner = ReventlessCore.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
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
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      EventCollectorRuntimeBuilder.registerStateViewSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~queryDbTableName=tableResource.name,
        ~queryDbResources=queryDbOutputs.resources,
      )
      sv
    }
  }
}
