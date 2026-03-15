module type Config = {
  let silent: bool
  let splitApi: bool
  let cloner: bool
}

type outputs = {
  adminFragment: ReventlessInfra.Api.schemaFragment,
  dcbMutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  dcbQueryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  dcbEventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
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
    ~dcbSpec: option<module(Plugin.DcbSpec)>,
  ) => {
    let name = "Admin"
    let opts: Pulumi.ComponentResource.options = {}

    // Construct DCB components and derive DCB-specific API schema entries
    module DcbBuilder = Dcb_Builder.Make(
      DcbEventLogStorage,
      DcbEventTopicPublisher,
      DcbCommandTopicChannel,
      AdminRuntimeBuilder,
    )
    let dcbResult = DcbBuilder.construct(~name, ~childName=name, ~dcbSpec, ~opts)

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
      switch Plugin_Helpers.schemaTypeRegistrationHook.contents {
      | Some(registerTypes) =>
        let parts = GraphQL_Stitcher.decode(adminFragment)
        registerTypes(parts.types)
      | None => ()
      }

      switch Plugin_Helpers.mcpSchemaRegistrationHook.contents {
      | Some(registerMcp) =>
        registerMcp({
          pluginName: "Admin",
          mutationEntries: allMutationEntries,
          queryEntries: allQueryEntries,
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

    // Store admin extension points so Plugin_Builder can wire the admin connection
    // path locally (in-memory) instead of via Interstack.coreStackReference.
    Plugin_Helpers.localAdminExtensionPoints := Some(
      extensionPointsOutputs->Pulumi.Output.apply(extensionPointsOutputs =>
        extensionPointsOutputs->Array.map(ep => (ep.name, ep))->Dict.fromArray
      ),
    )

    {
      adminFragment,
      dcbMutationEntries: dcbResult.mutationEntries,
      dcbQueryEntries: dcbResult.queryEntries,
      dcbEventLogEntries: dcbResult.eventLogEntries,
    }
  }
}
