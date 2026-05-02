// AutomationSlice builder — creates the TODO list QueryDb, EventCollector,
// and wires the event handler (Phase 1 + Phase 2) plus exposes processPending.
//
// Plan 04: subscribes to events from any combination of Aggregate EventTopics
// and DCB EventLog topics declared by the slice's `Mappings.mappings`. The
// caller passes `~allEventTopics` (the plugin-wide topic dict) — the slice
// filters down to topics matching its mappings' source names.
//
// Follows the StateViewSlice_Builder pattern for adapter injection.

module Make = (
  RuntimeEnvironment: Runtime.Environment,
  QueryDbStorage: QueryDb_Adapter.Storage,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = QueryDbStorage.api
    and type role = QueryDbStorage.role,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
  Api: {
    let api: unit => QueryDbStorage.api
    let apiRole: unit => QueryDbStorage.role
  },
) => {
  let finish = EventCollectorRuntimeBuilder.finish
  module Make = (
    Spec: Reventless.AutomationSlice.Spec,
    Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
  ): (AutomationSlice.T with module Spec = Spec) => {
    module Spec = Spec
    module Automation = Automation
    type component = AutomationSlice.component

    module Callback = AutomationSlice_Callback.Make(Spec, Automation)

    let queryDbName = Spec.name ++ "Todo"

    // Names of all sources this slice subscribes to (deduplicated). Multiple
    // mappings can share a source name (e.g., two mappings reading the same
    // Aggregate's events for different reasons).
    let sourceNames =
      Automation.mappings
      ->Array.map((module(M: Automation.Mapping)) => M.sourceName)
      ->Belt.Set.String.fromArray
      ->Belt.Set.String.toArray

    // QueryDb for TODO list — stores todoRow keyed by string ID
    module TodoQueryDbSpec = {
      module Id = Reventless.Id.String
      let name = queryDbName
      let moduleUrl: string = %raw(`import.meta.url`)
      type state = AutomationSlice_Callback.todoRow
      let stateSchema = AutomationSlice_Callback.todoRowSchema
      let config = Reventless.ReadModel.config()
      let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = None
    }

    module SpecificQueryDb = QueryDb_Builder.Make(TodoQueryDbSpec, QueryDbStorage, QueryDbResolvers)
    module SpecificEventCollector = EventCollector_Builder.Make(
      RuntimeEnvironment,
      EventCollectorChannel,
    )

    let syncToQueryDb = async (queryDbOps: SpecificQueryDb.operations) => {
      let items = Callback.todoItems->Dict.toArray
      let _ = await items->Array.reduce(Promise.resolve(), async (prev, (id, row)) => {
        let _ = await prev
        let _ = await queryDbOps.save(
          id->Reventless.Id.String.makeFromString,
          row,
          QueryDb.Overwrite,
          None,
        )
      })
    }

    let construct = (
      ~allEventTopics: EventTopic.allOutputs,
      ~publishJsons,
      ~context: Reventless.AutomationSlice.context,
      self,
      _name,
    ) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

      let queryDb = SpecificQueryDb.make(~api=Api.api(), ~apiRole=Api.apiRole(), ~opts)

      // Fail-fast: every Mapping.sourceName must resolve to a topic in
      // `allEventTopics`. Catches Aggregate-name typos and DCB-source-name
      // typos (e.g. "FooDcb" instead of "FooDcbEventLog"). Without this check
      // `EventTopic.filter` silently drops the unknown source, the
      // EventCollector subscribes to nothing, and the slice runs on no events
      // — which surfaces as "TODO list never populates" much later.
      sourceNames->Array.forEach(sourceName =>
        if !(allEventTopics->Dict.has(sourceName)) {
          let availableNames =
            allEventTopics->Dict.keysToArray->Array.toSorted(String.compare)->Array.join(", ")
          JsError.throwWithMessage(
            `AutomationSlice "${Spec.name}" has a Mapping with sourceName "${sourceName}", ` ++
            `but no EventTopic with that key exists in allEventTopics. ` ++
            `Available source names: [${availableNames}]. ` ++
            `Check Mapping.Make's first arg matches an Aggregate Spec.name or a DCB ` ++
            `source name (typically "<pluginName>DcbEventLog").`,
          )
        }
      )

      // Filter to only the topics this slice consumes from.
      let sourceSet = sourceNames->Belt.Set.String.fromArray
      let eventTopics = allEventTopics->EventTopic.filter(sourceSet)

      // Build the EventCollector inside an Output.all2 so both `queryDbOps`
      // and `publishJsonsFn` are captured in the same closure. The
      // jsonEventsHandler then has direct access to `publishJsonsFn` —
      // avoids racing a side-effect-only `publishJsons.apply` against the
      // first event arrival (which silently dropped Phase 2 in the previous
      // shape).
      let eventCollector =
        (queryDb->Component.operations, publishJsons)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((queryDbOps, publishJsonsFn)) => {
          let ec = SpecificEventCollector.make(~name=Spec.name, ~eventTopics, ~opts)

          let jsonEventsHandler: EventCollector.jsonEventsHandler = stream =>
            stream
            ->Stream.runCollect
            ->Effect.flatMap(jsons =>
              Effect.promise(
                async () => {
                  // Phase 1: per-source decode + collect/resolve, threaded with context
                  Callback.phase1(jsons, context)
                  // Phase 2: process pending items (process + encode + publish)
                  await Callback.phase2(publishJsonsFn)
                  // Sync TODO state to QueryDb for observability
                  await syncToQueryDb(queryDbOps)
                },
              )
            )

          let handler = SpecificEventCollector.makeHandler(~eventCollector=ec, ~jsonEventsHandler)
          let resources = (queryDb->Component.outputs).resources
          ec->EventCollectorRuntimeBuilder.forEventCollector(
            ~handler,
            ~eventTopics,
            ~resources,
          )
          ec
        })

      self->Component.setOperations(
        (eventCollector->Pulumi.Output.flatMap(ec => ec->Component.operations), publishJsons)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((ecOps, publishJsonsFn)) => {
          let ops: AutomationSlice.operations = {
            enqueueEvent: ecOps.enqueueEvent,
            processPending: async () => await Callback.phase2(publishJsonsFn),
          }
          ops
        }),
      )

      // Outputs.resources are aggregated from all subscribed event topics.
      let aggregatedResources =
        eventTopics
        ->Dict.valuesToArray
        ->Array.flatMap((t: EventTopic.outputs) => t.resources)
      let outputs: AutomationSlice.outputs = {
        resources: aggregatedResources,
        queryDb: queryDb->Component.outputs,
      }
      self->Component.setOutputs(outputs)
    }

    let make = (~allEventTopics, ~publishJsons, ~context, ~opts=?): AutomationSlice.component =>
      Component.make(
        ~componentType=AutomationSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~allEventTopics, ~publishJsons, ~context, ...),
        ~opts,
      )
  }
}
