module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = StateViewSliceRuntime_Builder_Single

module type Config = {
  let specModulePath: string
}

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
    Config: Config,
  ): (
    ReventlessCore.StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec
  ) => {
    module InnerMake = Inner.Make(Spec)

    type dcbEvent = InnerMake.dcbEvent
    module Spec = InnerMake.Spec
    type dcbEventLogComponent = InnerMake.dcbEventLogComponent
    type component = InnerMake.component

    let make = (~dcbEventLog, ~opts=?): component => {
      let sv = InnerMake.make(~dcbEventLog, ~opts?)

      let queryDbOutputs = (sv->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      EventCollectorRuntimeBuilder.registerStateViewSlice(
        ~name=Spec.name,
        ~specModulePath=Config.specModulePath,
        ~queryDbTableName,
      )

      sv
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
