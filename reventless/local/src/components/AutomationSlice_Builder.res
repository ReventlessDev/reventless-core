// In-memory AutomationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.AutomationSlice_Builder;
// each slice it makes joins the local automation sweep, and its schedules start.

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
    LocalAutomationSchedules,
    LocalCapabilities,
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
    let schedulesDbName = Inner.schedulesDbName
    let sourceNames = Inner.sourceNames
    let make = (~allEventTopics, ~publishJsons, ~context, ~runtime=?, ~opts=?) => {
      let component = Inner.make(~allEventTopics, ~publishJsons, ~context, ~runtime?, ~opts?)
      let operations = () => component->ReventlessCore.Component.operations->TestRunner.resolve
      LocalAutomationSweep.register(~name=Spec.name, async () => {
        let ops = await operations()
        await ops.processPending()
      })
      LocalAutomationSchedules.register(~slice=Spec.name, async (~key, ~at) => {
        let ops = await operations()
        await ops.tick(~key, ~at)
      })
      // As a deploy does on AWS: the declared time into the rows, the timers to the rows.
      let _ =
        operations()
        ->Promise.then(ops => ops.reconcileSchedules())
        ->Promise.catch(exn => {
          ReventlessCore.EffectLogger.logError(
            ~comp=`AutomationSlice(${Spec.name})`,
            `the schedules could not be reconciled: ${exn
              ->JsExn.fromException
              ->Option.flatMap(JsExn.message)
              ->Option.getOr("unknown")}`,
          )->Effect.runSync
          Promise.resolve()
        })
      component
    }
  }
}
