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
          dcbEventLog: None,
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

    // Wire CommandGenerator → AppSync / in-memory GraphQL resolvers via
    // `mutationResolverHook` and populate `aggregateMutationFieldsRegistry`.
    // The matching SDL entries are owned by
    // `PluginBaseFragment.pluginAggregateMutationEntries` (picked up via
    // `AdminApi.mutationEntries`) so the AWS path that pushes
    // `AdminApi.baseFragment` directly stays aligned with the in-memory path.
    aggregates->Plugin_Helpers.registerAdminAggregateMutations(~hooks=Config.hooks)

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

    // Admin schema — composed from actual config. `AdminApi.mutationEntries`
    // already includes the auto-derived `Platform_Plugin_Activate`/`Deactivate`
    // entries (via `PluginBaseFragment.pluginAggregateMutationEntries`) so the
    // SDL stays in sync with the resolver wiring fired above.
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

    // Pre-populate the query field names + state schema registries for admin
    // read models. Plugin_Builder does this for plugin-owned read models inside
    // its own loop, but admin RMs are passed in from outside and skip that path.
    // Without these entries, QueryDbResolvers_{AppSync,GraphQL}.make falls back
    // to lowercased Spec.name field names (e.g. `plugin`/`plugins`), which don't
    // match the `Platform_Plugin`/`Platform_Plugins` SDL fields declared by
    // PluginBaseFragment.queryEntries — leaving the SDL fields without a
    // resolver and producing "Cannot return null for non-nullable type" errors.
    AdminApi.queryEntries->Array.forEach(entry => {
      let prefix = "Platform_"
      let entityName = if entry.returnTypeName->String.startsWith(prefix) {
        entry.returnTypeName->String.slice(
          ~start=prefix->String.length,
          ~end=entry.returnTypeName->String.length,
        )
      } else {
        entry.returnTypeName
      }
      let (labelField, _searchableFields) = Plugin_Structure.labelFieldsFromStateSchema(
        ~entityName,
        entry.stateSchema,
      )
      let qn: Api_Naming.queryNames = {
        singleFieldName: entry.singleFieldName,
        listFieldName: entry.listFieldName,
        returnTypeName: entry.returnTypeName,
        pluralTypeName: entry.listFieldName,
        includeIdParam: entry.includeIdParam->Option.getOr(true),
        connectionSpec: entry.connectionSpec->Option.getOr(true),
        labelField,
        connectionFilterTypeName: entry.returnTypeName ++ "Filter",
      }
      Plugin_Helpers.queryFieldNamesRegistry->Dict.set(entityName, qn)
      Plugin_Helpers.stateSchemaRegistry->Dict.set(entityName, entry.stateSchema)
    })

    let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)

    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    // Merge DCB StateViewSlice / InboundTranslation QueryDbs into allQueryDbs so the
    // resolver-makers wired below also cover admin DCB slice fields (mirrors the
    // plugin-side merge at Plugin_Builder.res).
    dcbResult.stateViewSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k, v.queryDb))
    dcbResult.inboundTranslationSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k, v.queryDb))
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    // Invoke each QueryDb's deferred resolversMaker so AppSync resolvers are
    // actually attached to the admin-prefixed Connection fields (Platform_Plugins,
    // Platform_PlatformEventGraphs, …). Without this, ReadModel_Builder_Single
    // produces the resolverMaker closure but it is never called, and AppSync
    // returns "Cannot return null for non-nullable type" for the Connection field.
    //
    // Gate the actual CreateResolver SDK calls on the admin schema push (when
    // the platform supplies preAdminResolversSchemaHook). AppSync holds an
    // API-level lock during StartSchemaCreation and rejects concurrent
    // CreateResolver / UpdateResolver with ConcurrentModificationException —
    // mirrors Plugin_Builder's schemaPushed pattern at Plugin_Builder.res:
    // 452-466. The barrier collects the names of all admin read-model DDB
    // resources so the schema push waits for the underlying DataSources to be
    // ready before firing. Platforms with no hook (e.g. in-memory) return an
    // already-resolved Output and createResolvers fires immediately, as before.
    let adminBarrier =
      readModelsOutputs
      ->Dict.valuesToArray
      ->Array.flatMap(rm => rm.queryDb.resources->Array.map(r => r.name))
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(_ => ())
    let adminSchemaPushed = switch Config.hooks.preAdminResolversSchemaHook {
    | Some(push) => push(~adminBarrier)
    | None => Pulumi.Output.make()
    }
    let _resolvers = adminSchemaPushed->Pulumi.Output.apply(() =>
      allQueryDbs->createResolvers
    )

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
