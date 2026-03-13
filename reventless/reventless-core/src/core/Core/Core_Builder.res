open Core_Helpers

module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner,
  CoreRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
) => {
  type api = ClonerRunner.api

  let construct = (
    ~version,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = 'role)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
    ~api: ClonerRunner.api,
    ~apiRole: 'role,
    ~apiComponent: option<ReventlessInfra.Api.component>,
    ~dcbSpec: option<module(Plugin.DcbSpec)>,
    self,
    _,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = Core.componentType->ComponentType.toName

    // Construct DCB components and derive DCB-specific API schema entries
    module DcbBuilder = Dcb_Builder.Make(
      DcbEventLogStorage,
      DcbEventTopicPublisher,
      DcbCommandTopicChannel,
      CoreRuntimeBuilder,
    )
    let dcbResult = DcbBuilder.construct(~name, ~childName=name, ~dcbSpec, ~opts)

    // Register DCB schema entries via hooks (same path as plugins)
    if dcbResult.mutationEntries->Array.length > 0 || dcbResult.queryEntries->Array.length > 0 {
      let fragment = CoreApi.generateFragment(
        ~dcbMutationEntries=dcbResult.mutationEntries,
        ~dcbQueryEntries=dcbResult.queryEntries,
        ~dcbEventLogEntries=dcbResult.eventLogEntries,
      )
      switch Plugin_Helpers.schemaTypeRegistrationHook.contents {
      | Some(registerTypes) =>
        let parts = GraphQL_Stitcher.decode(fragment)
        registerTypes(parts.types)
      | None => ()
      }

      switch Plugin_Helpers.mcpSchemaRegistrationHook.contents {
      | Some(registerMcp) =>
        registerMcp({
          pluginName: "Core",
          mutationEntries: Array.concat(CoreApi.mutationEntries, dcbResult.mutationEntries),
          queryEntries: Array.concat(CoreApi.queryEntries, dcbResult.queryEntries),
          eventLogEntries: dcbResult.eventLogEntries,
        })
      | None => ()
      }
    }

    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(~api, opts)
    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    // Merge DCB EventTopic into allEventTopics so ReadModels can subscribe to DCB events
    switch dcbResult.dcbEventLogOutputs {
    | Some(dcbOutputs) => allEventTopics->Dict.set(name ++ "DcbEventLog", dcbOutputs.eventTopic)
    | None => ()
    }

    let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)

    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let (aggregatesOutputs, extensionPointsOutputs, eventCollectorOutputs) =
      (
        aggregateResources->Pulumi.Output.allDict,
        publishToAggregates->Pulumi.Output.allDict,
        queryEngine,
        scheduler,
      )
      ->Pulumi.Output.all4
      ->Pulumi.Output.apply(((aggregateResources, publishToAggregates, queryEngine, scheduler)) => {
        let aggregatesOutputs = addEventMappers(allEventTopics, queryEngine)

        let (extensionPointsOutputs, extensionPointsOutgoingJsonEventsHandlers) =
          extensionPoints->createExtensionPoints(
            ~aggregateResources,
            ~publishToAggregates,
            ~scheduler,
            ~queryEngine,
            ~resourceNaming,
            ~opts,
          )

        let aggregateNames =
          extensionPointsOutputs
          ->Array.map(extensionPointOutputs =>
            extensionPointOutputs.aggregateNames->Belt.Set.String.fromArray
          )
          ->Array.reduce(Belt.Set.String.empty, (acc, names) => acc->Belt.Set.String.union(names))

        let eventTopics = aggregatesOutputs->Aggregate.filterEventTopics(aggregateNames)

        module EventCollectorHelper = MakeEventCollectorHelper(
          RuntimeEnvironment,
          EventCollectorChannel,
          CoreRuntimeBuilder,
        )
        let (eventCollector, eventCollectorOutputs) = EventCollectorHelper.make(
          ~name,
          ~eventTopics,
          ~opts,
        )

        let _ =
          extensionPointsOutgoingJsonEventsHandlers
          ->Pulumi.Output.all
          ->Pulumi.Output.flatMap(extensionPointsOutgoingJsonEventsHandlers =>
            EventCollectorHelper.connect(
              ~eventCollector,
              ~eventTopics,
              ~extensionPointsOutputs,
              ~extensionPointsOutgoingJsonEventsHandlers,
            )
          )

        // Connect DCB command topic to its runtime (if DCB is configured)
        dcbResult.dcbRuntimeSetup->Option.forEach(dcbRuntimeSetup => dcbRuntimeSetup())

        (aggregatesOutputs, extensionPointsOutputs, eventCollectorOutputs)
      })
      ->Pulumi.Output.unzip3

    module Cloner = Cloner.Make(ClonerRunner)
    let cloner = Cloner.make(~api, ~opts)

    let baseOutputs: Core.outputs = {
      Core.version,
      eventCollector: eventCollectorOutputs,
      extensionPoints: extensionPointsOutputs->Pulumi.Output.apply(extensionPointsOutputs =>
        extensionPointsOutputs->Array.map(ep => (ep.name, ep))->Dict.fromArray
      ),
      aggregates: aggregatesOutputs,
      readModels: readModelsOutputs,
      cloner: cloner->Component.outputs,
    }
    // Add optional fields conditionally
    let withApi = switch apiComponent {
    | Some(apiComp) => {...baseOutputs, api: apiComp}
    | None => baseOutputs
    }
    let withDcb = switch dcbResult.dcbEventLogOutputs {
    | Some(dcbEventLogOutputs) => {
        ...withApi,
        dcbEventLog: dcbEventLogOutputs,
        stateChangeSlices: dcbResult.stateChangeSlicesOutputs,
        stateViewSlices: dcbResult.stateViewSlicesOutputs,
        automationSlices: dcbResult.automationSlicesOutputs,
        outboundTranslationSlices: dcbResult.outboundTranslationSlicesOutputs,
        inboundTranslationSlices: dcbResult.inboundTranslationSlicesOutputs,
      }
    | None => withApi
    }
    // Store Core outputs so Plugin_Builder can wire the Core connection path
    // locally (in-memory) instead of via Interstack.coreStackReference.
    Plugin_Helpers.localCoreOutputs := Some(withDcb)
    self->Component.setOutputs(withDcb)
  }

  let make = (
    ~version,
    ~extensionPoints,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = 'role)>,
    ~scheduler,
    ~api: ClonerRunner.api,
    ~apiRole: 'role,
    ~resourceNaming,
    ~apiComponent: option<ReventlessInfra.Api.component>=?,
    ~dcbSpec: option<module(Plugin.DcbSpec)>=?,
  ): Core.component =>
    Component.make(
      ~componentType=Core.componentType->ComponentType.toString,
      ~name="Core",
      ~construct=construct(
        ~version,
        ~extensionPoints,
        ~aggregates,
        ~readModels,
        ~scheduler,
        ~api,
        ~apiRole,
        ~resourceNaming,
        ~apiComponent,
        ~dcbSpec,
        ...
      ),
      ~opts=None,
    )
}
