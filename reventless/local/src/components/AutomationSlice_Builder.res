// In-memory AutomationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.AutomationSlice_Builder;
// each slice it makes joins the local automation sweep, and its declared schedule starts.

module Make = (Bus: LocalBus.T) => {
  module RuntimeEnvironment = LocalRuntimeEnvironment
  module EventCollectorChannel = LocalEventCollectorChannel.Make(Bus)
  module EventCollectorRuntimeBuilder = LocalEventCollectorRuntime_Builder.Make(
    Bus,
    EventCollectorChannel,
  )
  module QueryDbStorage = LocalQueryDbStorage.Make(Bus)
  module QueryDbResolvers = QueryDbResolvers_GraphQL.Make(Bus)

  // InMemory api/apiRole are both unit
  module Api = {
    let api = () => ()
    let apiRole = () => ()
  }

  module CoreMaker = ReventlessCore.AutomationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (
    Spec: Reventless.AutomationSlice.Spec,
    Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
  ): (ReventlessInfra.AutomationSlice.T with module Spec = Spec) => {
    module Inner = CoreMaker.Make(Spec, Automation)
    module Spec = Spec
    module Automation = Automation
    type component = Inner.component
    let queryDbName = Inner.queryDbName
    let sourceNames = Inner.sourceNames
    let make = (~allEventTopics, ~publishJsons, ~context, ~runtime=?, ~opts=?) => {
      let component = Inner.make(~allEventTopics, ~publishJsons, ~context, ~runtime?, ~opts?)
      let operations = () => component->ReventlessCore.Component.operations->TestRunner.resolve
      LocalAutomationSweep.register(~name=Spec.name, async () => {
        let ops = await operations()
        await ops.processPending()
      })
      Spec.schedule->Option.forEach(time =>
        LocalAutomationSchedules.set(
          ~slice=Spec.name,
          ~key=Reventless.Clock.defaultKey,
          time,
          ~tick=async (~key, ~at) => {
            let ops = await operations()
            await ops.tick(~key, ~at)
          },
        )
      )
      component
    }
  }
}
