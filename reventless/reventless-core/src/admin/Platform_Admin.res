module type Config = {
  let silent: bool
  let splitApi: bool
  let cloner: bool
  let hooks: Plugin_Helpers.platformHooks
}

type outputs = {
  adminFragment: ReventlessInfra.Api.schemaFragment,
  dcbMutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  dcbQueryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  dcbEventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
  extensionPointsOutputs: Pulumi.Output.t<array<ExtensionPoint.outputs>>,
  aggregatesOutputs: dict<Aggregate.outputs>,
  readModelsOutputs: dict<ReadModel.outputs>,
  dcbEventLogOutputs: option<DcbEventLog.outputs>,
  stateChangeSlicesOutputs: dict<StateChangeSlice.outputs>,
  stateViewSlicesOutputs: dict<StateViewSlice.outputs>,
  automationSlicesOutputs: dict<AutomationSlice.outputs>,
  outboundTranslationSlicesOutputs: dict<OutboundTranslationSlice.outputs>,
  inboundTranslationSlicesOutputs: dict<InboundTranslationSlice.outputs>,
}

module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner,
  AdminRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
  DcbCommandTopicChannelAsync: CommandTopic_Adapter.Channel,
  Config: Config,
) => {
  include Builder_Helpers

  module MakeEventCollectorHelper = (
    RE: Runtime.Environment,
    ECC: EventCollector_Adapter.Channel with type runtimeParts = RE.parts,
    RB: PluginRuntime_Builder.T with module EventCollectorChannel = ECC,
  ) => {
    module AdminEventCollector = EventCollector_Builder.Make(RE, ECC)
    let make = (~name, ~eventTopics, ~opts) => {
      let eventCollector = AdminEventCollector.make(~name, ~eventTopics, ~opts)
      let eventCollectorOutputs = eventCollector->Component.outputs
      (eventCollector, eventCollectorOutputs)
    }

    let connect = (
      ~eventCollector: EventCollector.component,
      ~eventTopics: EventTopic.allOutputs,
      ~extensionPointsOutputs: array<ExtensionPoint.outputs>,
      ~extensionPointsOutgoingJsonEventsHandlers,
    ) => {
      let resources =
        extensionPointsOutputs
        ->Array.map(extensionPoint => extensionPoint.eventTopic)
        ->Pulumi.Output.all
        ->Pulumi.Output.apply(eventTopics =>
          eventTopics
          ->Array.map(eventTopic => eventTopic.resources)
          ->Array.flat
        )

      resources->Pulumi.Output.apply(resources => {
        let fakePluginDefinition: Reventless.Plugin.pluginDefinition = {
          id: "Admin@INTERNAL",
          name: "Admin",
          version: "INTERNAL",
          extensionPoints: [],
          extensions: [],
          eventCollector: "NOT-SET",
          extensionProtocols: [],
          apiSchemaFragment: None,
          apiTarget: None,
          uiFragments: None,
          structure: None,
        }

        module Callback = Admin_Callback.Make({
          let pluginDefinition = fakePluginDefinition
          let outgoingExtensionPointJsonEventsHandlers = extensionPointsOutgoingJsonEventsHandlers
        })
        let handler = AdminEventCollector.makeHandler(
          ~eventCollector,
          ~jsonEventsHandler=Callback.handleJsonEvents,
        )
        eventCollector->RB.forPluginEventCollector(~handler, ~eventTopics, ~resources)
      })
    }
  }

  type api = ClonerRunner.api

  let construct = (
    ~version as _,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = 'role)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
    ~api: ClonerRunner.api,
    ~apiRole: 'role,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>,
  ) => {
    let name = "Admin"
    let opts: Pulumi.ComponentResource.options = {}

    // Construct DCB components and derive DCB-specific API schema entries
    module DcbBuilder = Dcb_Builder.Make(
      DcbEventLogStorage,
      DcbEventTopicPublisher,
      DcbCommandTopicChannel,
      DcbCommandTopicChannelAsync,
      AdminRuntimeBuilder,
      Config,
    )
    // Aggregates constructed early so multi-source AutomationSlices created
    // inside DcbBuilder can subscribe to Aggregate event topics.
    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(~api, opts)
    let aggregateEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let dcbResult = DcbBuilder.construct(
      ~name,
      ~childName=name,
      ~aggregateEventTopics,
      ~stateChangeSlices,
      ~stateViewSlices,
      ~automationSlices,
      ~outboundTranslationSlices,
      ~inboundTranslationSlices,
      ~opts,
    )

    // Admin schema — composed from actual config
    let adminMutationEntries = AdminApi.mutationEntries(~cloner=Config.cloner)
    let allMutationEntries = Array.concat(adminMutationEntries, dcbResult.mutationEntries)
    let allQueryEntries = Array.concat(AdminApi.queryEntries, dcbResult.queryEntries)
    let adminFragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=allMutationEntries,
      ~queryEntries=allQueryEntries,
    )

    // Register DCB schema entries via hooks (same path as plugins)
    if dcbResult.mutationEntries->Array.length > 0 || dcbResult.queryEntries->Array.length > 0 {
      switch Config.hooks.schemaTypeRegistrationHook {
      | Some(registerTypes) =>
        let parts = GraphQL_Stitcher.decode(adminFragment)
        registerTypes(parts.types)
      | None => ()
      }

      switch Config.hooks.mcpSchemaRegistrationHook {
      | Some(registerMcp) =>
        registerMcp({
          pluginName: "Admin",
          mutationEntries: allMutationEntries,
          queryEntries: allQueryEntries,
          eventLogEntries: dcbResult.eventLogEntries,
          subscriptionFields: GraphQL_Stitcher.decode(adminFragment).subscriptions,
        })
      | None => ()
      }
    }

    // Reuse aggregateEventTopics computed above as the base for ReadModels' allEventTopics.
    let allEventTopics = aggregateEventTopics
    switch dcbResult.dcbEventLogOutputs {
    | Some(dcbOutputs) => allEventTopics->Dict.set(name ++ "DcbEventLog", dcbOutputs.eventTopic)
    | None => ()
    }

    let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)

    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let extensionPointsOutputs =
      (
        aggregateResources->Pulumi.Output.allDict,
        publishToAggregates->Pulumi.Output.allDict,
        queryEngine,
        scheduler,
      )
      ->Pulumi.Output.all4
      ->Pulumi.Output.apply(((aggregateResources, publishToAggregates, queryEngine, scheduler)) => {
        let _aggregatesOutputs = addEventMappers(allEventTopics, queryEngine)

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

        let aggregatesOutputs = addEventMappers(allEventTopics, queryEngine)
        let eventTopics = aggregatesOutputs->Aggregate.filterEventTopics(aggregateNames)

        module EventCollectorHelper = MakeEventCollectorHelper(
          RuntimeEnvironment,
          EventCollectorChannel,
          AdminRuntimeBuilder,
        )
        let (eventCollector, _eventCollectorOutputs) = EventCollectorHelper.make(
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

        extensionPointsOutputs
      })

    // Cloner (opt-in)
    if Config.cloner {
      module Cloner = Cloner.Make(ClonerRunner)
      let _cloner = Cloner.make(~api, ~opts)
    }

    {
      adminFragment,
      dcbMutationEntries: dcbResult.mutationEntries,
      dcbQueryEntries: dcbResult.queryEntries,
      dcbEventLogEntries: dcbResult.eventLogEntries,
      extensionPointsOutputs,
      aggregatesOutputs: aggregatesWithoutEventMappers,
      readModelsOutputs,
      dcbEventLogOutputs: dcbResult.dcbEventLogOutputs,
      stateChangeSlicesOutputs: dcbResult.stateChangeSlicesOutputs,
      stateViewSlicesOutputs: dcbResult.stateViewSlicesOutputs,
      automationSlicesOutputs: dcbResult.automationSlicesOutputs,
      outboundTranslationSlicesOutputs: dcbResult.outboundTranslationSlicesOutputs,
      inboundTranslationSlicesOutputs: dcbResult.inboundTranslationSlicesOutputs,
    }
  }
}
