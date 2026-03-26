module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = StateViewSliceRuntime_Builder_Single

module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => {
  module Inner = ReventlessCore.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (
    Spec: Reventless.StateViewSlice.Spec,
  ): (
    ReventlessCore.StateViewSlice.T
      with module Spec = Spec
  ) => {
    module InnerMake = Inner.Make(Spec)

    module Spec = InnerMake.Spec
    type component = InnerMake.component

    let make = (~dcbEventLog, ~opts=?): component => {
      let sv = InnerMake.make(~dcbEventLog, ~opts?)

      let queryDbOutputs = (sv->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      EventCollectorRuntimeBuilder.registerStateViewSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~queryDbTableName,
      )

      sv
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
