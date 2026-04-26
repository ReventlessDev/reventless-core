// StateViewSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.StateViewSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Projection) for the
// new two-arg framework form. External signature stays on MergedSpec
// until Phase 5 migrates examples to native split form.

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
    Spec: Reventless.StateViewSlice.MergedSpec,
  ): (ReventlessCore.StateViewSlice.T with module Spec = Spec) => {
    module LeanSpec = {
      let name = Spec.name
      let moduleUrl = Spec.moduleUrl
      type state = Spec.state
      let stateSchema = Spec.stateSchema
      type consumedEvent = Spec.consumedEvent
      let consumedEventSchema = Spec.consumedEventSchema
      let config = Spec.config
      let subIdConfig = Spec.subIdConfig
    }
    module ProjectionImpl = {
      let project = Spec.project
      let moduleUrl = Spec.moduleUrl
    }
    module InnerMake = Inner.Make(LeanSpec, ProjectionImpl)
    module Spec = Spec
    module Projection = ProjectionImpl
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
