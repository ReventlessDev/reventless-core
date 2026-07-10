open Plugin_Helpers

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

// (No type aliases needed — adminExtensionPoints is accessed as a ref field
//  on Spec.hooks, so no optional-parameter parsing issues arise.)

module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
  let environment: string
  /** Deployment-level identity (Pulumi project name in AWS, "local" in
      the local platform). Threaded into `AutomationSlice.context` so
      mappings can populate partition tags from deployment metadata. */
  let platformName: string
  let hooks: Plugin_Helpers.platformHooks
}

module Make = (
  Spec: Spec,
  ApiSpec: {
    type api
    type role
  },
  FragmentProvider: ReventlessInfra.Api_Adapter.Provider,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  PluginExtensionPointRemoteChannel: CommandTopic_Adapter.RemoteChannel,
  HeartbeatRunner: Heartbeat_Adapter.Runner with type runtimeParts = RuntimeEnvironment.parts,
  PluginRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
  DcbCommandTopicChannelAsync: CommandTopic_Adapter.Channel,
): (Plugin.T with type api = ApiSpec.api and type role = ApiSpec.role) => {
  type api = ApiSpec.api
  type role = ApiSpec.role

  let construct = (
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>,
    ~extensions: array<module(ReventlessInfra.Extension.Blueprint)>,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>,
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >,
    ~tasks: array<module(ReventlessInfra.Task.T)>,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>,
    ~systemCallableComponents: array<string>,
    ~uiFragments: option<Reventless.Plugin.uiFragmentManifest>,
    ~pluginStructure: option<Reventless.Plugin.pluginStructure>,
    self,
    name,
  ) => {
    // Tag all logs emitted during this plugin's construction with `[name]`.
    // Restored at the end of construct; nested constructs (none today) would stack.
    let _prevPluginName = Logger.currentPluginName.contents
    Logger.currentPluginName := Some(name)

    // Register every component → plugin so runtime logs (fired after construct
    // returns) can resolve a comp like `StateChangeSlice(AddProduct)` to its
    // owning plugin via `Logger.componentPluginRegistry`. Also register the
    // plugin's own name so dotted EP / Plugin / CommandTopic log comps resolve.
    let registerComp = compName =>
      Logger.registerComponentPlugin(~componentName=compName, ~pluginName=name)
    registerComp(name)
    aggregates->Array.forEach((module(M: ReventlessInfra.Aggregate.T with type api = api)) =>
      registerComp(M.Spec.name)
    )
    readModels->Array.forEach((
      module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
    ) => registerComp(R.Spec.name))
    stateChangeSlices->Array.forEach((module(Sc: ReventlessInfra.StateChangeSlice.T)) =>
      registerComp(Sc.Spec.name)
    )
    stateViewSlices->Array.forEach((module(Sv: ReventlessInfra.StateViewSlice.T)) =>
      registerComp(Sv.Spec.name)
    )
    automationSlices->Array.forEach((module(As: ReventlessInfra.AutomationSlice.T)) =>
      registerComp(As.Spec.name)
    )
    outboundTranslationSlices->Array.forEach((
      module(Ots: ReventlessInfra.OutboundTranslationSlice.T),
    ) => registerComp(Ots.Spec.name))
    inboundTranslationSlices->Array.forEach((
      module(Its: ReventlessInfra.InboundTranslationSlice.T),
    ) => registerComp(Its.Spec.name))
    tasks->Array.forEach((module(T: ReventlessInfra.Task.T)) => registerComp(T.Spec.name))
    // Extensions deliberately not registered: their Spec.name is the filename stem
    // (e.g. "Products") and would collide with same-named SVS/ReadModels in other
    // plugins. Extension log comps already use the fully-qualified EP form
    // `Extension(Catalog.Products.Ordering)`; the lastDot transformation resolves
    // them to the consumer plugin via its self-registration.

    // Read platform context from hooks refs (populated by makePlatform/deployPlugin).
    let scheduler = switch Spec.hooks.scheduler.contents {
    | Some(s) => s
    | None =>
      JsError.throwWithMessage(
        "Plugin_Builder: scheduler not set — call makePlatform/deployPlugin first",
      )
    }
    let schedulerRoleUrn = Spec.hooks.schedulerRoleUrn.contents
    let api: api = switch Spec.hooks.api.contents {
    | Some({val}) => Obj.magic(val)
    | None =>
      JsError.throwWithMessage(
        "Plugin_Builder: api not set — call makePlatform/deployPlugin first",
      )
    }
    let apiRole: role = switch Spec.hooks.apiRole.contents {
    | Some({val}) => Obj.magic(val)
    | None =>
      JsError.throwWithMessage(
        "Plugin_Builder: apiRole not set — call makePlatform/deployPlugin first",
      )
    }

    let id = Plugin.makeId(name, version)
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let childName = name->ComponentType.name(Plugin.componentType)

    // Aggregates are constructed early so their EventTopics can feed multi-source
    // AutomationSlices created inside DcbBuilder. The same `aggregateEventTopics`
    // dict (after merging in the DCB EventLog topic) is reused later as
    // `allEventTopics` for ReadModels.
    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(~api, opts)
    let aggregateEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    // Construct DCB components and derive DCB-specific API schema entries
    module DcbBuilder = Dcb_Builder.Make(
      DcbEventLogStorage,
      DcbEventTopicPublisher,
      DcbCommandTopicChannel,
      DcbCommandTopicChannelAsync,
      PluginRuntimeBuilder,
      Spec,
    )
    let dcbResult = DcbBuilder.construct(
      ~name,
      ~childName,
      ~environment=Spec.environment,
      ~platformName=Spec.platformName,
      ~aggregateEventTopics,
      ~stateChangeSlices,
      ~stateViewSlices,
      ~automationSlices,
      ~outboundTranslationSlices,
      ~inboundTranslationSlices,
      ~systemCallableComponents,
      ~pluginStructure?,
      ~opts,
    )

    // Derive GraphQL schema fragment for this plugin
    let mutationEntriesFromAggregates =
      aggregates->Array.flatMap((module(M: ReventlessInfra.Aggregate.T with type api = api)) => {
        let commandSchema = M.Spec.commandSchema->S.castToUnknown
        if ApiNoApiHelpers.isNoApi(commandSchema) {
          []
        } else {
          let constructorNames = Reventless.DcbTag.extractAllVariantNames(M.Spec.commandSchema)
          let filteredConstructorNames = ApiNoApiHelpers.filterNoApiVariants(constructorNames, commandSchema)
          let fieldNames =
            filteredConstructorNames->Array.map(cname =>
              Api_Naming.aggregateMutationField(~plugin=name, ~aggregate=M.Spec.name, ~command=cname)
            )
          // Register plugin-prefixed field names for CommandGenerator_Builder.
          Plugin_Helpers.aggregateMutationFieldsRegistry->Dict.set(M.Spec.name, fieldNames)
          if fieldNames->Array.length === 0 {
            []
          } else {
            // Register aggregate mutation SDL + resolver stubs synchronously via hook
            // (before Output.apply chains fire).
            Spec.hooks.mutationResolverHook->Option.forEach(registerResolver =>
              registerResolver(
                ~kind=Aggregate,
                ~fields=fieldNames,
                ~commandSchema,
                ~commandAuthorization=M.Spec.commandAuthorization->Obj.magic,
              )
            )
            let aggDef =
              pluginStructure->Option.flatMap(s =>
                s.aggregates->Array.find(d => d.name == M.Spec.name)
              )
            // Stage E2 (host-ui-login-core): derive per-field permissions by
            // evaluating the PPX-generated `commandAuthorization` against a
            // synthetic command value per constructor. Mirrors the resolver-time
            // shape from `CommandGeneratorResolvers_GraphQL.syntheticCommand` —
            // payload-bearing variants compile to `{TAG, ...}`, payload-less to
            // bare strings.
            let fieldPermissions = Dict.make()
            filteredConstructorNames->Array.forEachWithIndex((cname, idx) => {
              let fieldName = fieldNames->Array.getUnsafe(idx)
              let hasPayload =
                Reventless.DcbTag.isVariantPayloadBearing(M.Spec.commandSchema->Obj.magic, cname)
              let syntheticCmd: unknown =
                hasPayload ? {"TAG": cname}->Obj.magic : cname->Obj.magic
              let rule = M.Spec.commandAuthorization(syntheticCmd->Obj.magic)
              fieldPermissions->Dict.set(fieldName, rule)
            })
            [{
              ReventlessInfra.Api.fieldNames,
              commandSchema,
              fieldPermissions,
              linkedViews: ?aggDef->Option.map(d => d.linkedViews),
              consistencyRead: ?aggDef->Option.flatMap(d => d.consistencyRead),
            }]
          }
        }
      })

    let mutationEntries = Array.concat(mutationEntriesFromAggregates, dcbResult.mutationEntries)

    let queryEntriesFromReadModels =
      readModels->Array.map((
        module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
      ) => {
        let qn = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
        let subIdField = R.Spec.subIdConfig->Option.map(c => c.subIdField)
        {
          ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
          listFieldName: qn.listFieldName,
          returnTypeName: qn.returnTypeName,
          stateSchema: R.Spec.stateSchema->S.castToUnknown,
          authorization: None,
          permission: R.Spec.authorization,
          connectionSpec: true,
          subIdField: ?subIdField,
        }
      })

    let queryEntries = Array.concat(queryEntriesFromReadModels, dcbResult.queryEntries)

    let eventLogEntriesFromAggregates =
      aggregates->Array.map((module(M: ReventlessInfra.Aggregate.T with type api = api)) => {
        ReventlessInfra.Api.busKey: M.Spec.name ++ "Aggr" ++ "EventLog",
        displayName: M.Spec.name,
        eventSchema: M.Spec.eventSchema->S.castToUnknown,
      })

    let eventLogEntries = Array.concat(eventLogEntriesFromAggregates, dcbResult.eventLogEntries)

    // Populate query field names registry so resolvers align with fragment SDL.
    // Keyed by the Spec.name that each component uses for its QueryDb.
    // (StateViewSlice registry is populated earlier, inside the DCB builder,
    // before StateViewSlice.make calls — see above.)
    readModels->Array.forEach((
      module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
    ) => {
      let qn = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
      let (labelField, _searchableFields) = Plugin_Structure.labelFieldsFromStateSchema(
        ~entityName=R.Spec.name,
        R.Spec.stateSchema->S.castToUnknown,
      )
      let qn = {
        ...qn,
        labelField,
        connectionFilterTypeName: qn.returnTypeName ++ "Filter",
      }
      let qn = switch R.Spec.subIdConfig {
      | Some(_) =>
        {
          ...qn,
          itemsFieldName: qn.singleFieldName ++ "Items",
          itemsFilterTypeName: qn.returnTypeName ++ "ItemsFilter",
        }
      | None => qn
      }
      Plugin_Helpers.queryFieldNamesRegistry->Dict.set(R.Spec.name, qn)
      Plugin_Helpers.stateSchemaRegistry->Dict.set(
        R.Spec.name,
        R.Spec.stateSchema->S.castToUnknown,
      )
    })

    let apiSchemaFragment = {
      let baseFragment = FragmentProvider.generateFragment(~mutationEntries, ~queryEntries)
      let subResult = Plugin_SubscriptionSchema.generate(
        ~mutationEntries,
        ~eventLogEntries,
      )
      let parts = GraphQL_Stitcher.decode(baseFragment)
      GraphQL_Stitcher.encode({
        ...parts,
        types: Array.concat(parts.types, subResult.extraTypes),
        subscriptions: subResult.subscriptionFields,
      })
    }

    // Register type definitions via platform hook (e.g. GraphQL in-memory)
    Spec.hooks.schemaTypeRegistrationHook->Option.forEach(registerTypes => {
      let parts = GraphQL_Stitcher.decode(apiSchemaFragment)
      registerTypes(parts.types)
    })

    // Register MCP tools and resources via platform hook (e.g. MCP in-memory)
    Spec.hooks.mcpSchemaRegistrationHook->Option.forEach(registerMcp =>
      registerMcp({
        pluginName: name,
        mutationEntries,
        queryEntries,
        eventLogEntries,
        subscriptionFields: GraphQL_Stitcher.decode(apiSchemaFragment).subscriptions,
      })
    )

    // Register DCB StateChangeSlice publish functions in publishToAggregates so that
    // extensions whose Delegate is a DCB slice can dispatch commands to them.
    // All slices in a plugin share the same DCB command topic (same publishJsons).
    switch dcbResult.dcbPublishJsons {
    | Some(slicePublishJsons) =>
      stateChangeSlices->Array.forEach((module(Sc: StateChangeSlice.T)) =>
        publishToAggregates->Dict.set(Sc.Spec.name, slicePublishJsons)
      )
    | None => ()
    }
    // Reuse the aggregateEventTopics dict computed before DcbBuilder.construct;
    // merge in the DCB EventLog topic for ReadModels (already merged inside
    // DcbBuilder for AutomationSlice subscription).
    let allEventTopics = aggregateEventTopics
    switch dcbResult.dcbEventLogOutputs {
    | Some(dcbOutputs) => allEventTopics->Dict.set(name ++ "DcbEventLog", dcbOutputs.eventTopic)
    | None => ()
    }

    let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)
    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    // Merge DCB StateViewSlice, InboundTranslation, AutomationSlice, and
    // OutboundTranslation QueryDbs into allQueryDbs so createResolvers builds
    // AppSync resolvers for them too.
    //
    // Key must match `name` passed to QueryDbResolvers_AppSync.make (the
    // QueryDb's own queryDbName, used by storageResource lookups for ByIds
    // and idResolver paths). Slice output dicts are keyed by Spec.name; the
    // queryDb name appends a suffix per slice kind:
    //   StateViewSlice           — no suffix
    //   AutomationSlice          — "Todo"
    //   OutboundTranslationSlice — "Todo"
    //   InboundTranslationSlice  — "Audit"
    dcbResult.stateViewSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k, v.queryDb))
    dcbResult.inboundTranslationSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k ++ "Audit", v.queryDb))
    dcbResult.automationSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k ++ "Todo", v.queryDb))
    dcbResult.outboundTranslationSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k ++ "Todo", v.queryDb))
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    {
      // Fire onPluginBuiltHook synchronously with a plain-data summary.
      // ExtensionPoint/Extension names are not accessible from their T module type,
      // so only aggregates, read models, and DCB slice names are included.

      let extractTypes = schema => Reventless.DcbTag.extractAllVariantNames(schema)

      // Chapter (intra-plugin grouping band) per component name, mirrored from the
      // static pluginStructure so the hook surface reaches parity with it. The
      // structure is the single source — it was populated by the generator's
      // componentChapters map at makePluginDefinition time.
      let chapterByName: Dict.t<string> = Dict.make()
      switch pluginStructure {
      | Some(ps) =>
        let put = (n, c) =>
          switch c {
          | Some(ch) => chapterByName->Dict.set(n, ch)
          | None => ()
          }
        ps.aggregates->Array.forEach(d => put(d.name, d.chapter))
        ps.readModels->Array.forEach(d => put(d.name, d.chapter))
        ps.stateChangeSlices->Array.forEach(d => put(d.name, d.chapter))
        ps.stateViewSlices->Array.forEach(d => put(d.name, d.chapter))
        ps.automationSlices->Array.forEach(d => put(d.name, d.chapter))
        ps.outboundTranslationSlices->Array.forEach(d => put(d.name, d.chapter))
        ps.inboundTranslationSlices->Array.forEach(d => put(d.name, d.chapter))
      | None => ()
      }
      let chapterFor = (n: string): option<string> => chapterByName->Dict.get(n)

      // Build per-component schema data and register it for the deployed hook.
      let aggregateComponents = aggregates->Array.map((
        module(M: ReventlessInfra.Aggregate.T with type api = api),
      ) => {
        let schema: Plugin_Helpers.pluginDeployedSchema = {
          commandTypes: extractTypes(M.Spec.commandSchema),
          eventTypes: extractTypes(M.Spec.eventSchema),
          errorTypes: extractTypes(M.Spec.errorSchema),
          commandSchemas: [
            SchemaWalker.walk(M.Spec.name ++ ".command", M.Spec.commandSchema),
          ],
          eventSchemas: [
            SchemaWalker.walk(M.Spec.name ++ ".event", M.Spec.eventSchema),
          ],
          chapter: ?chapterFor(M.Spec.name),
        }
        Plugin_Helpers.componentSchemaRegistry->Dict.set(M.Spec.name, schema)
        ({name: M.Spec.name, kind: "Aggregate", schema}: Plugin_Helpers.pluginBuiltComponent)
      })

      let readModelComponents = readModels->Array.map((
        module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
      ) => {
        let qn = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
        let schema: Plugin_Helpers.pluginDeployedSchema = {
          queryFields: [qn.singleFieldName, qn.listFieldName],
          chapter: ?chapterFor(R.Spec.name),
        }
        Plugin_Helpers.componentSchemaRegistry->Dict.set(R.Spec.name, schema)
        ({name: R.Spec.name, kind: "ReadModel", schema}: Plugin_Helpers.pluginBuiltComponent)
      })

      // Routing slices (automation / inbound + outbound translation) expose their
      // command/event wiring and routing target on the hook surface, at parity
      // with aggregates and read models — mirroring the metadata Plugin_Structure
      // records on the static plugin def. Type strings stay unqualified to match
      // the aggregate/read-model entries already on this same hook surface
      // (Plugin_Structure additionally prefixes them with the plugin name).
      let extractEventTypes = schema => Reventless.DcbTag.extractVariantNames(schema)
      let routingSchemas: Dict.t<Plugin_Helpers.pluginDeployedSchema> = Dict.make()
      automationSlices->Array.forEach((module(As: ReventlessInfra.AutomationSlice.T)) => {
        // Union of source-event variants across every per-source mapping.
        let consumedEventTypes =
          As.Automation.mappings
          ->Array.flatMap((module(M: As.Automation.Mapping)) =>
            extractEventTypes(M.sourceEventSchema->S.castToUnknown)
          )
          ->Belt.Set.String.fromArray
          ->Belt.Set.String.toArray
        routingSchemas->Dict.set(
          As.Spec.name,
          {
            consumedEventTypes,
            producedCommandTypes: extractTypes(As.Spec.commandSchema),
            targetName: As.Spec.targetName,
            chapter: ?chapterFor(As.Spec.name),
          },
        )
      })
      outboundTranslationSlices->Array.forEach((
        module(Ots: ReventlessInfra.OutboundTranslationSlice.T),
      ) =>
        routingSchemas->Dict.set(
          Ots.Spec.name,
          {
            consumedEventTypes: extractEventTypes(Ots.Spec.consumedEventSchema),
            commandTypes: extractTypes(Ots.Spec.inboundCommandSchema),
            // Outbound slices may have no target (option); pass it through.
            targetName: ?Ots.Spec.targetName,
            chapter: ?chapterFor(Ots.Spec.name),
          },
        )
      )
      inboundTranslationSlices->Array.forEach((
        module(Its: ReventlessInfra.InboundTranslationSlice.T),
      ) =>
        routingSchemas->Dict.set(
          Its.Spec.name,
          {
            commandTypes: extractTypes(Its.Spec.commandSchema),
            targetName: Its.Spec.targetName,
            chapter: ?chapterFor(Its.Spec.name),
          },
        )
      )

      // StateChange / StateView slices carry no routing target, but they do carry
      // command / event / consumed-event types. Surface those on the hook at parity
      // with aggregates, read models, and routing slices — mirroring the metadata
      // Plugin_Structure records on the static plugin def. Type strings stay
      // unqualified to match the aggregate/read-model entries already on this same
      // hook surface (Plugin_Structure additionally prefixes them with the plugin
      // name).
      let stateSchemas: Dict.t<Plugin_Helpers.pluginDeployedSchema> = Dict.make()
      stateChangeSlices->Array.forEach((module(Scs: ReventlessInfra.StateChangeSlice.T)) =>
        stateSchemas->Dict.set(
          Scs.Spec.name,
          {
            commandTypes: extractTypes(Scs.Spec.commandSchema),
            eventTypes: extractEventTypes(Scs.Spec.eventSchema->S.castToUnknown),
            consumedEventTypes: extractEventTypes(Scs.Spec.consumedEventSchema->S.castToUnknown),
            chapter: ?chapterFor(Scs.Spec.name),
          },
        )
      )
      stateViewSlices->Array.forEach((module(Svs: ReventlessInfra.StateViewSlice.T)) =>
        stateSchemas->Dict.set(
          Svs.Spec.name,
          {
            consumedEventTypes: extractEventTypes(Svs.Spec.consumedEventSchema->S.castToUnknown),
            chapter: ?chapterFor(Svs.Spec.name),
          },
        )
      )

      // Component set still derives from the DCB outputs dict (unchanged
      // membership); enrich + register the schema where a matching spec module
      // was found above, so the deployed hook surfaces it too (the built-hook
      // components carry it inline).
      let enrichedComponents = (
        d: dict<_>,
        kind: string,
        schemas: Dict.t<Plugin_Helpers.pluginDeployedSchema>,
      ) =>
        d
        ->Dict.keysToArray
        ->Array.map(name => {
          let schema = schemas->Dict.get(name)->Option.getOr({})
          Plugin_Helpers.componentSchemaRegistry->Dict.set(name, schema)
          ({Plugin_Helpers.name, kind, schema}: Plugin_Helpers.pluginBuiltComponent)
        })

      let components = Array.flat([
        aggregateComponents,
        readModelComponents,
        enrichedComponents(dcbResult.stateChangeSlicesOutputs, "StateChangeSlice", stateSchemas),
        enrichedComponents(dcbResult.stateViewSlicesOutputs, "StateViewSlice", stateSchemas),
        enrichedComponents(dcbResult.automationSlicesOutputs, "AutomationSlice", routingSchemas),
        enrichedComponents(
          dcbResult.outboundTranslationSlicesOutputs,
          "OutboundTranslationSlice",
          routingSchemas,
        ),
        enrichedComponents(
          dcbResult.inboundTranslationSlicesOutputs,
          "InboundTranslationSlice",
          routingSchemas,
        ),
      ])

      switch Plugin_Helpers.onPluginBuiltHook.contents {
      | Some(hook) =>
        let meta = Plugin_Helpers.pluginMetadataRegistry.contents
        hook({
          name,
          version,
          kind: ?meta->Option.flatMap(m => m.kind),
          displayName: ?meta->Option.flatMap(m => m.displayName),
          vendor: ?meta->Option.flatMap(m => m.vendor),
          architectureType: ?meta->Option.flatMap(m => m.architectureType),
          components,
        })
      | None => ()
      }
    }

    let builderOutputs = {
      // Resolve admin extension point data — from Interstack (AWS cross-stack reference).
      let interstackAdminExtensionPoints =
        Interstack.coreStackReference->Option.mapOr(Pulumi.Output.make(None), coreStack =>
          coreStack->Pulumi.StackReference.getOutput("extensionPoints")
        )

      // Derive local admin extension point resolved data (passed from makePlatform).
      let localAdminResolvedEP =
        Spec.hooks.adminExtensionPoints.contents->Pulumi.Output.flatMap(eps =>
          switch eps->Dict.get(PluginExtensionPointSpec.name) {
          | Some(ep) => ep->ExtensionPoint.toResolvedOutputs->Pulumi.Output.apply(r => Some(r))
          | None => Pulumi.Output.make(None)
          }
        )

      // Push schema fragment to the API before resolvers are created (AWS only).
      // The returned Output chains into the dependency tuple so Pulumi waits
      // for the schema update to complete before creating resolver resources.
      let schemaPushed = switch Spec.hooks.preResolversSchemaHook {
      | Some(pushSchema) => pushSchema(~name, ~version, apiSchemaFragment)
      | None => Pulumi.Output.make()
      }

      (
        (interstackAdminExtensionPoints, localAdminResolvedEP, schemaPushed)->Pulumi.Output.all3,
        aggregateResources->Pulumi.Output.allDict,
        publishToAggregates->Pulumi.Output.allDict,
        publishToReadModels->Pulumi.Output.allDict,
        scheduler,
        queryEngine,
      )
      ->Pulumi.Output.all6
      ->Pulumi.Output.apply(((
        (interstackAdminExtensionPoints, localAdminResolvedEP, _),
        aggregateResources,
        publishToAggregates,
        publishToReadModels,
        scheduler,
        queryEngine,
      )) => {
        let aggregatesOutputs = addEventMappers(allEventTopics, queryEngine)

        let (extensionPointsOutputs, extensionPointsHandlers, extensionPointRegistryInfos) =
          extensionPoints->createExtensionPoints(
            ~aggregateResources,
            ~publishToAggregates,
            ~scheduler,
            ~queryEngine,
            ~resourceNaming=Spec.resourceNaming,
            ~opts,
          )

        // Resolve admin connection — from Interstack (AWS), local admin (in-memory), or None
        let coreSetup = switch interstackAdminExtensionPoints {
        | Some(interstackAdminExtensionPoints) => {
            let pluginExtensionPointUnwrapped: ReventlessInterop.ExtensionPoint.resolvedOutputs = (
              interstackAdminExtensionPoints
              ->Pulumi.StackReference.get(PluginExtensionPointSpec.name)
              ->Obj.magic: JSON.t
            )->S.parseOrThrow(ReventlessInterop.ExtensionPoint.resolvedOutputsSchema)
            let pluginExtensionPointCommandTopicRemoteChannel = PluginExtensionPointRemoteChannel.make(
              pluginExtensionPointUnwrapped.commandTopic.resources->Array.map(
                Adapter.fromInteropResolved,
              ),
            )
            Some((pluginExtensionPointUnwrapped, pluginExtensionPointCommandTopicRemoteChannel))
          }
        | None =>
          // Fallback: use local admin extension point data (e.g. in-memory platform)
          switch localAdminResolvedEP {
          | Some(resolvedEP) =>
            let remoteChannel = PluginExtensionPointRemoteChannel.make(
              resolvedEP.commandTopic.resources->Array.map(Adapter.fromInteropResolved),
            )
            Some((resolvedEP, remoteChannel))
          | None => None
          }
        }

        let publishToPluginExtensionPoint: ReventlessInfra.CommandTopic.publishJsons = switch coreSetup {
        | Some((_, remoteChannel)) => remoteChannel.remotePublish
        | None => async _ => ()
        }

        let (extensionsOutputs, extensionsHandlers, extensionRegistryInfos) =
          extensions->createExtensions(
            ~pluginName=name,
            ~publishToPluginExtensionPoint,
            ~publishToAggregates,
            ~publishToReadModels,
            ~queryEngine,
            ~opts,
          )

        let extensionPointsDefinitions = extensionPointsOutputs->extractExtensionPointDefinitions
        let extensionsDefinitions = extensionsOutputs->extractExtensionDefinitions

        module Set = Belt.Set.String

        let collectAggregateNames = ex =>
          ex
          ->Set.fromArray
          ->Set.remove(ReventlessInfra.ExtensionMapping.NoDelegate.name)

        let extensionPointAggregateNames =
          extensionPointsOutputs
          ->Array.flatMap(ex => ex.aggregateNames)
          ->collectAggregateNames

        let extensionAggregateNames =
          extensionsOutputs
          ->Array.flatMap(ex => ex.aggregateNames)
          ->collectAggregateNames

        let eventTopics =
          aggregatesOutputs->Aggregate.filterEventTopics(
            extensionPointAggregateNames->Set.union(extensionAggregateNames),
          )
        // Include DCB EventTopic so the EventCollector subscribes to DynamoDB Stream events
        switch dcbResult.dcbEventLogOutputs {
        | Some(dcbOutputs) => eventTopics->Dict.set(name ++ "DcbEventLog", dcbOutputs.eventTopic)
        | None => ()
        }
        switch coreSetup {
        | Some((pluginExtensionPointUnwrapped, _)) =>
          eventTopics->Dict.set(
            PluginExtensionPointSpec.name,
            {
              resources: pluginExtensionPointUnwrapped.eventTopic.resources->Array.map(
                AdapterDeploytime.fromInteropResource,
              ),
            },
          )
        | None => ()
        }

        let childName = name->ComponentType.name(Plugin.componentType)

        module EventCollectorHelper = MakeEventCollectorHelper(
          RuntimeEnvironment,
          EventCollectorChannel,
          PluginRuntimeBuilder,
        )
        let (eventCollector, eventCollectorOutputs, eventCollectorUrn) = EventCollectorHelper.make(
          ~name=childName,
          ~eventTopics,
          ~opts,
        )

        // Capture deployTarget synchronously before the Pulumi.Output.apply callback.
        // deployPlugin resets hooks.deployTarget to "Domain" after P.make() returns,
        // so reading it inside the async callback would always yield "Domain".
        let capturedDeployTarget = Spec.hooks.deployTarget.contents

        // DCB EventLog definition — Some when this plugin has a DcbEventLog
        // component, None otherwise. Admin's manageSubscriptions reads this to
        // provision cross-plugin SNS subscriptions from peer plugins' DCB
        // topics → this plugin's EventCollector, and vice-versa. The eventTopic
        // resource's `id` is the SNS topic ARN (same convention as
        // extensionPointDefinition.eventTopic).
        let dcbEventLogDef: Pulumi.Output.t<option<Reventless.Plugin.dcbEventLogDefinition>> =
          switch dcbResult.dcbEventLogOutputs {
          | None => Pulumi.Output.make(None)
          | Some(dcbOutputs) =>
            switch dcbOutputs.eventTopic.resources->Array.get(0) {
            | Some(r) =>
              r.id->Pulumi.Output.apply(arn => Some({
                Reventless.Plugin.name: name ++ "DcbEventLog",
                eventTopicArn: arn,
              }))
            | None => Pulumi.Output.make(None)
            }
          }

        let pluginDefinition =
          (extensionPointsDefinitions, eventCollectorUrn, dcbEventLogDef)
          ->Pulumi.Output.all3
          ->Pulumi.Output.apply(((extensionPointsDefinitions, eventCollectorUrn, dcbEventLogDef)) => {
            Reventless.Plugin.id,
            name,
            version,
            extensionPoints: extensionPointsDefinitions,
            extensions: extensionsDefinitions,
            eventCollector: eventCollectorUrn,
            extensionProtocols: [],
            apiSchemaFragment: Some(apiSchemaFragment),
            apiTarget: Some(capturedDeployTarget),
            uiFragments,
            structure: pluginStructure,
            dcbEventLog: dcbEventLogDef,
            // Business role from the deploy-time metadata registry (set via
            // registerPluginMetadata). Unset → Domain. Rides the handshake to the
            // plugin-lifecycle projection so the admin can segregate infrastructure.
            kind: Plugin_Helpers.pluginMetadataRegistry.contents
            ->Option.flatMap(m => m.kind)
            ->Option.getOr(Plugin_Helpers.Domain),
          })

        // Bundled Plugin EventCollector reconstructs Extension_Operations at
        // cold start from HANDLER_CONFIG, which needs concrete cmd-topic SQS
        // URLs for every aggregate/slice a user extension may publish to.
        let aggregateQueueUrls: dict<Pulumi.Output.t<string>> = Dict.make()
        aggregateResources
        ->Dict.toArray
        ->Array.forEach(((aggName, resources)) =>
          switch resources->Array.get(0) {
          | Some(r) => aggregateQueueUrls->Dict.set(aggName, r.id)
          | None => ()
          }
        )
        // All DCB StateChangeSlices share the same dcb command topic — map
        // every slice name to that single URL so PublishStateChangeSliceCommand
        // routes correctly regardless of which slice the extension targets.
        switch dcbResult.dcbCommandTopicQueueUrl {
        | Some(url) =>
          stateChangeSlices->Array.forEach((module(Sc: StateChangeSlice.T)) =>
            aggregateQueueUrls->Dict.set(Sc.Spec.name, url)
          )
        | None => ()
        }

        // Per-RM EventCollector SQS URL — populated only for plugins that
        // expose RMs the bundled handler may enqueue events into directly.
        let readModelQueueUrls: dict<Pulumi.Output.t<string>> = Dict.make()
        readModelsOutputs
        ->Dict.toArray
        ->Array.forEach(((rmName, rmOut)) => {
          let urlOutput =
            rmOut.eventCollector->Pulumi.Output.flatMap(ecOutputs =>
              switch ecOutputs.resources->Array.get(0) {
              | Some(r) => r.id
              | None => Pulumi.Output.make("")
              }
            )
          readModelQueueUrls->Dict.set(rmName, urlOutput)
        })

        switch coreSetup {
        | Some((pluginExtensionPointUnwrapped, _)) => {
            let (
              connectPluginExtensionOutputs,
              connectPluginExtensionIncomingEventHandler,
            ) = createConnectPluginExtension(
              ~pluginDefinition,
              ~publishToPluginExtensionPoint,
              ~publishToAggregates,
              ~readModelNamesForSourceName,
              ~publishToReadModels,
              ~queryEngine,
              ~opts,
            )
            let _ = EventCollectorHelper.connect(
              ~eventCollector,
              ~eventTopics,
              ~extensionPointsOutputs,
              ~extensionsOutputs,
              ~pluginExtensionPointUnwrapped,
              ~pluginDefinition,
              ~connectPluginExtensionIncomingEventHandler,
              ~extensionsHandlers,
              ~extensionPointsHandlers,
              ~connectPluginExtensionOutputs,
              ~extensionRegistryInfos,
              ~extensionPointRegistryInfos,
              ~aggregateQueueUrls,
              ~readModelQueueUrls,
              ~readModelNamesForSourceName,
            )
          }
        | None =>
          // No admin connection — connect EventCollector without ConnectPluginExtension
          let _ = EventCollectorHelper.connect(
            ~eventCollector,
            ~eventTopics,
            ~extensionPointsOutputs,
            ~extensionsOutputs,
            ~pluginDefinition,
            ~extensionsHandlers,
            ~extensionPointsHandlers,
            ~extensionRegistryInfos,
            ~aggregateQueueUrls,
            ~readModelQueueUrls,
            ~readModelNamesForSourceName,
          )
        }

        let tasksOutputs = createTasks(
          tasks,
          ~aggregatesOutputs,
          ~scheduler,
          ~schedulerRoleUrn,
          ~publishToAggregates,
          ~queryEngine,
          ~resourceNaming=Spec.resourceNaming,
          ~opts,
        )

        let resolvers = allQueryDbs->createResolvers

        // Wire subscription infrastructure (StateTopic, EventLogSubscription) after resolvers.
        // Gives the AWS platform access to allQueryDbs, allEventTopics, and eventLogEntries
        // without coupling reventless-core to reventless-aws.
        Spec.hooks.subscriptionInfraHook->Option.forEach(hook =>
          hook({allQueryDbs, allEventTopics, eventLogEntries, opts})
        )

        module SpecificHeartbeat = Heartbeat_Builder.Make(HeartbeatRunner)
        let heartbeat = SpecificHeartbeat.make(~name=childName, ~opts)
        let handler = SpecificHeartbeat.makeHandler(
          ~id,
          ~timeout=heartbeatInterval,
          ~publishToPluginExtensionPoint,
        )
        switch coreSetup {
        | Some((_, pluginExtensionPointCommandTopicRemoteChannel)) =>
          // Notify platform hook that the EP channel is available (AWS extracts SQS URL for bundled heartbeat)
          Spec.hooks.onHeartbeatEpChannelAvailable->Option.forEach(hook =>
            hook(pluginExtensionPointCommandTopicRemoteChannel->Obj.magic, ~pluginId=id)
          )
          heartbeat->PluginRuntimeBuilder.forPluginHeartbeat(
            ~handler,
            ~connect=SpecificHeartbeat.connect(
              heartbeat,
              ~remoteChannel=pluginExtensionPointCommandTopicRemoteChannel,
              ~timeout=heartbeatInterval,
              ...
            ),
          )
        | None =>
          heartbeat->PluginRuntimeBuilder.forPluginHeartbeat(~handler, ~connect=(~runtime as _) =>
            ()
          )
        }

        // Connect DCB command topic to its Lambda runtime (if DCB is configured)
        dcbResult.dcbRuntimeSetup->Option.forEach(dcbRuntimeSetup => dcbRuntimeSetup())

        {
          id,
          version,
          heartbeatInterval,
          eventCollector: eventCollectorOutputs,
          extensionPoints: extensionPointsOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          extensions: extensionsOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          aggregates: aggregatesOutputs,
          stateChangeSlices: dcbResult.stateChangeSlicesOutputs,
          stateViewSlices: dcbResult.stateViewSlicesOutputs,
          automationSlices: dcbResult.automationSlicesOutputs,
          outboundTranslationSlices: dcbResult.outboundTranslationSlicesOutputs,
          inboundTranslationSlices: dcbResult.inboundTranslationSlicesOutputs,
          readModels: readModelsOutputs,
          tasks: tasksOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          resolvers,
          heartbeat: heartbeat->Component.outputs,
          dcbEventLog: dcbResult.dcbEventLogOutputs,
          uiFragments: (uiFragments: option<Reventless.Plugin.uiFragmentManifest>),
        }
      })
    }

    let pluginOutputs: Plugin.outputs = {
      id: builderOutputs->Pulumi.Output.apply(outputs => outputs.id),
      version: builderOutputs->Pulumi.Output.apply(outputs => outputs.version),
      heartbeatInterval: builderOutputs->Pulumi.Output.apply(outputs => outputs.heartbeatInterval),
      eventCollector: builderOutputs->Pulumi.Output.apply(outputs => outputs.eventCollector),
      extensionPoints: builderOutputs->Pulumi.Output.apply(outputs => outputs.extensionPoints),
      extensions: builderOutputs->Pulumi.Output.apply(outputs => outputs.extensions),
      aggregates: builderOutputs->Pulumi.Output.apply(outputs => outputs.aggregates),
      stateChangeSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.stateChangeSlices),
      stateViewSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.stateViewSlices),
      automationSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.automationSlices),
      outboundTranslationSlices: builderOutputs->Pulumi.Output.apply(outputs =>
        outputs.outboundTranslationSlices
      ),
      inboundTranslationSlices: builderOutputs->Pulumi.Output.apply(outputs =>
        outputs.inboundTranslationSlices
      ),
      readModels: builderOutputs->Pulumi.Output.apply(outputs => outputs.readModels),
      tasks: builderOutputs->Pulumi.Output.apply(outputs => outputs.tasks),
      resolvers: builderOutputs->Pulumi.Output.apply(outputs => outputs.resolvers),
      heartbeat: builderOutputs->Pulumi.Output.apply(outputs => outputs.heartbeat),
      dcbEventLog: builderOutputs->Pulumi.Output.apply(outputs => outputs.dcbEventLog),
      apiSchemaFragment: Pulumi.Output.make(Some(apiSchemaFragment)),
      uiFragments: builderOutputs->Pulumi.Output.apply(outputs => outputs.uiFragments),
      pluginStructure: Pulumi.Output.make(pluginStructure),
    }
    let _ = self->Component.setOutputs(pluginOutputs)

    // Compute and store the _interopMeta stack export value.  User entry-point
    // code retrieves it via Plugin_Helpers.getInteropMeta() and exports it
    // alongside "tasks", "plugin", and "eventMappers".
    // Assign directly — do NOT wrap in Some().  Pulumi.Output.t is a JS Proxy;
    // wrapping a Proxy in Caml_option.some() triggers the BS_PRIVATE sentinel bug.
    interopMetaOutput :=
      builderOutputs->Pulumi.Output.apply(outputs =>
        outputs
        ->toInteropMeta
        ->S.reverseConvertToJsonOrThrow(ReventlessInterop.ExportMeta.schema)
      )

    Logger.currentPluginName := _prevPluginName
  }

  let makeAutoUIManifest = (
    ~remoteEntryUrl: string,
    ~name: string,
    ~pluginStructure: Reventless.Plugin.pluginStructure,
    ~readModelPositions: array<string>=[],
    ~aggregatePositions: array<string>=[],
  ): Reventless.Plugin.uiFragmentManifest => {
    // Internal queryable components are hidden from the AutoUI manifest. They
    // remain fully wired (resolvers, GraphQL schema, queryable defs,
    // authorization) — visibility is a UX hint, not a security boundary. See
    // docs/plans/done/component-visibility-annotations.md
    let isVisibleQueryable = (q: Reventless.Plugin.queryableDef) =>
      switch q.visibility {
      | Some("Internal") => false
      | _ => true
      }
    let visibleReadModels = pluginStructure.readModels->Array.filter(isVisibleQueryable)
    let visibleStateViewSlices = pluginStructure.stateViewSlices->Array.filter(isVisibleQueryable)
    let listPanel = (q: Reventless.Plugin.queryableDef): Reventless.Plugin.panelManifestEntry => {
      fragmentId: name ++ "." ++ q.name ++ ".list",
      title: q.name,
      description: "",
      positions: readModelPositions,
      requiredAccess: None,
    }
    let detailPanel = (w: Reventless.Plugin.writableDef): Reventless.Plugin.panelManifestEntry => {
      fragmentId: name ++ "." ++ w.name ++ ".detail",
      title: w.name,
      description: "",
      positions: aggregatePositions,
      requiredAccess: None,
    }
    let listPage = (q: Reventless.Plugin.queryableDef): Reventless.Plugin.pageManifestEntry => {
      fragmentId: name ++ "." ++ q.name ++ ".list",
      title: q.name,
      menuEntry: {label: q.name, icon: None, group: None, sortOrder: 0},
      requiredAccess: None,
    }
    let panels = Array.flat([
      visibleReadModels->Array.map(listPanel),
      visibleStateViewSlices->Array.map(listPanel),
      pluginStructure.aggregates->Array.map(detailPanel),
      pluginStructure.stateChangeSlices->Array.map(detailPanel),
    ])
    let pages = Array.flat([
      visibleReadModels->Array.map(listPage),
      visibleStateViewSlices->Array.map(listPage),
    ])
    {remoteEntryUrl, panels, pages}
  }

  let makePluginDefinition = (
    ~name: string,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=[],
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >=[],
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=[],
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=[],
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>=[],
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>=[],
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>=[],
    ~extensions: array<module(ReventlessInfra.Extension.Blueprint)>=[],
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPointMapping.Mapping)>=[],
    ~componentChapters: dict<string>=Dict.make(),
  ): Reventless.Plugin.pluginStructure =>
    Plugin_Structure.make(
      ~name,
      ~aggregates,
      ~readModels,
      ~stateViewSlices,
      ~stateChangeSlices,
      ~automationSlices,
      ~outboundTranslationSlices,
      ~inboundTranslationSlices,
      ~extensions,
      ~extensionPoints,
      ~componentChapters,
    )

  let make = (
    ~name,
    ~heartbeatInterval,
    ~extensionPoints=[],
    ~extensions=[],
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=[],
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >=[],
    ~tasks=[],
    ~stateChangeSlices=[],
    ~stateViewSlices=[],
    ~automationSlices=[],
    ~outboundTranslationSlices=[],
    ~inboundTranslationSlices=[],
    ~systemCallableComponents=[],
    ~uiFragments: option<Reventless.Plugin.uiFragmentManifest>=?,
    ~pluginStructure: option<Reventless.Plugin.pluginStructure>=?,
    ~opts=?,
  ) => {
    PluginRuntimeBuilder.registerPluginName(name)
    let version = Reventless.PackageVersion.fromCaller()
    Component.make(
      ~componentType=Plugin.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(
        ~version,
        ~heartbeatInterval,
        ~extensionPoints,
        ~extensions,
        ~aggregates,
        ~readModels,
        ~tasks,
        ~stateChangeSlices,
        ~stateViewSlices,
        ~automationSlices,
        ~outboundTranslationSlices,
        ~inboundTranslationSlices,
        ~systemCallableComponents,
        ~uiFragments,
        ~pluginStructure,
        ...
      ),
      ~opts,
    )
  }
}
