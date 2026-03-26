module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = AutomationSliceRuntime_Builder_Single

module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => {
  module Inner = ReventlessCore.AutomationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (
    Spec: Reventless.AutomationSlice.Spec,
  ): (
    ReventlessCore.AutomationSlice.T
      with module Spec = Spec
  ) => {
    module InnerMake = Inner.Make(Spec)

    module Spec = InnerMake.Spec
    type component = InnerMake.component
    let queryDbName = InnerMake.queryDbName

    let make = (~dcbEventLog, ~publishJsons, ~opts=?): component => {
      let as_ = InnerMake.make(~dcbEventLog, ~publishJsons, ~opts?)

      let queryDbOutputs = (as_->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      EventCollectorRuntimeBuilder.registerAutomationSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~callbackType="automation",
        ~queryDbTableName,
      )

      as_
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
