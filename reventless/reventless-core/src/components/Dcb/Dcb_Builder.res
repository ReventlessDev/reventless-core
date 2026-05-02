// Converts a file:// module URL to a path relative to the project root (located by lerna.json),
// resolving symlinks so workspace packages show their source location rather than node_modules.
// Falls back to the bare URL string on any error.
let toRelativePath: string => string = %raw(`function toRelativePath(moduleUrl) {
  try {
    const fs = process.getBuiltinModule('node:fs');
    const path = process.getBuiltinModule('node:path');
    const { fileURLToPath } = process.getBuiltinModule('node:url');
    const builderReal = fs.realpathSync(fileURLToPath(import.meta.url));
    const sliceReal = fs.realpathSync(fileURLToPath(moduleUrl));
    let dir = path.dirname(builderReal);
    while (dir !== path.dirname(dir)) {
      if (fs.existsSync(path.join(dir, 'lerna.json'))) break;
      dir = path.dirname(dir);
    }
    return path.relative(dir, sliceReal).replace(/\.mjs$/, '.res');
  } catch(e) {
    return moduleUrl.replace('file://', '');
  }
}`)

type dcbResult = {
  dcbEventLogOutputs: option<DcbEventLog.outputs>,
  stateChangeSlicesOutputs: dict<StateChangeSlice.outputs>,
  stateViewSlicesOutputs: dict<StateViewSlice.outputs>,
  automationSlicesOutputs: dict<AutomationSlice.outputs>,
  outboundTranslationSlicesOutputs: dict<OutboundTranslationSlice.outputs>,
  inboundTranslationSlicesOutputs: dict<InboundTranslationSlice.outputs>,
  dcbRuntimeSetup: option<unit => unit>,
  // Shared publishJsons for all DCB StateChangeSlices in this plugin (same command topic).
  // Used by Plugin_Builder to register slice names in publishToAggregates so extensions
  // can dispatch commands to DCB slices via the same mechanism as regular aggregates.
  dcbPublishJsons: option<Pulumi.Output.t<CommandTopic.publishJsons>>,
  mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
}

let emptyResult: dcbResult = {
  dcbEventLogOutputs: None,
  stateChangeSlicesOutputs: Dict.make(),
  stateViewSlicesOutputs: Dict.make(),
  automationSlicesOutputs: Dict.make(),
  outboundTranslationSlicesOutputs: Dict.make(),
  inboundTranslationSlicesOutputs: Dict.make(),
  dcbRuntimeSetup: None,
  dcbPublishJsons: None,
  mutationEntries: [],
  queryEntries: [],
  eventLogEntries: [],
}

module Make = (
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
  DcbCommandTopicChannelAsync: CommandTopic_Adapter.Channel,
  RuntimeBuilder: PluginRuntime_Builder.T,
  HooksConfig: Plugin_Helpers.HooksConfig,
) => {
  let construct = (
    ~name: string,
    ~childName: string,
    ~environment: string="",
    ~platformName: string="",
    ~aggregateEventTopics: EventTopic.allOutputs=Dict.make(),
    ~stateChangeSlices: array<module(StateChangeSlice.T)>,
    ~stateViewSlices: array<module(StateViewSlice.T)>,
    ~automationSlices: array<module(AutomationSlice.T)>,
    ~outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>,
    ~inboundTranslationSlices: array<module(InboundTranslationSlice.T)>,
    ~pluginStructure: option<Reventless.Plugin.pluginStructure>=?,
    ~opts: Pulumi.ComponentResource.options,
  ): dcbResult => {
    // DCB requires at least one StateChangeSlice to produce events to the event log.
    // View/automation/translation slices are consumers and need produced events to exist.
    let hasDcb = stateChangeSlices->Array.length > 0
    if hasDcb {
        // Partition slices by channel mode (set by MakeAsync vs Make)
        let syncSlices = stateChangeSlices->Array.filter((module(M: StateChangeSlice.T)) => !M.isAsync)
        let asyncSlices = stateChangeSlices->Array.filter((module(M: StateChangeSlice.T)) => M.isAsync)

        // Run validation: check produced vs consumed event compatibility
        let produced =
          stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            (Sc.Spec.name, Sc.Spec.eventSchema->S.castToUnknown)
          )
        let producedNamed =
          stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            (Sc.Spec.name, toRelativePath(Sc.Spec.moduleUrl), Sc.Spec.eventSchema->S.castToUnknown)
          )
        let consumed =
          stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            (Sc.Spec.name, Sc.Spec.consumedEventSchema->S.castToUnknown)
          )
          ->Array.concat(
            stateViewSlices->Array.map((module(V: StateViewSlice.T)) =>
              (V.Spec.name, V.Spec.consumedEventSchema->S.castToUnknown)
            ),
          )
          ->Array.concat(
            // Plan 04: AutomationSlice has per-source Mappings, each carrying
            // its own `sourceEventSchema`. Validation contributes one entry per
            // (slice, source) pair so unknown variants surface against the right
            // mapping context.
            automationSlices->Array.flatMap((module(A: AutomationSlice.T)) =>
              A.Automation.mappings->Array.map((module(M: A.Automation.Mapping)) =>
                (A.Spec.name, M.sourceEventSchema->S.castToUnknown)
              )
            ),
          )
          ->Array.concat(
            outboundTranslationSlices->Array.map((module(O: OutboundTranslationSlice.T)) =>
              (O.Spec.name, O.Spec.consumedEventSchema->S.castToUnknown)
            ),
          )

        switch Reventless.DcbValidation.validateProducedAndConsumed(~produced, ~consumed) {
        | Error(errors) =>
          errors->Array.forEach(err =>
            Console.error(`DCB validation error (${err.sliceName}): ${err.message}`)
          )
        | Ok() => ()
        }

        // Extract tagged fields from all produced event schemas for DynamoDB GSI creation
        let producedSchemas = produced->Array.map(((_, schema)) => schema)
        let indexes =
          producedSchemas
          ->Array.flatMap(schema => Reventless.DcbTag.extractTaggedFields(schema))
          ->(arr => {
            let seen = Set.make()
            arr->Array.filter(f => {
              if seen->Set.has(f) {
                false
              } else {
                seen->Set.add(f)
                true
              }
            })
          })
          ->Array.map(tagKey => `tag_${tagKey}`)
        let indexes = if indexes->Array.length > 1 {
          indexes->Array.concat(["tag_composite"])
        } else {
          indexes
        }

        let partitionTag = Reventless.DcbTag.derivePartitionTag(producedNamed)

        module DcbEventLog = DcbEventLog_Builder.Make(
          DcbEventLogStorage,
          DcbEventTopicPublisher,
        )
        let dcbEventLog = DcbEventLog.make(~name, ~indexes, ~partitionTag, ~opts)

        // Notify platform hook that DCB EventLog was created (AWS extracts table name)
        HooksConfig.hooks.onDcbEventLogCreated->Option.forEach(hook =>
          hook(dcbEventLog->Obj.magic)
        )

        // Create sync CommandTopic for sync StateChangeSlices (and all other DCB slice types)
        module DcbCommandTopicSpec = {
          module Id = Reventless.Id.String
          let name = childName
          @schema
          type command = JSON.t
        }
        module DcbCommandTopic = CommandTopic_Builder.Make(
          DcbCommandTopicSpec,
          DcbCommandTopicChannel,
        )
        let dcbCommandTopic = DcbCommandTopic.make(~name=`${childName}-dcb-command-topic`, ~opts)

        // Notify platform hook that DCB CommandTopic was created (AWS extracts SQS queue URL)
        HooksConfig.hooks.onDcbCommandTopicCreated->Option.forEach(hook =>
          hook(dcbCommandTopic->Obj.magic)
        )

        let publishJsons =
          dcbCommandTopic
          ->Component.operations
          ->Pulumi.Output.apply(ops => ops.publishJsons)

        // Create FIFO CommandTopic for async StateChangeSlices (only if any are configured)
        module DcbCommandTopicSpecAsync = {
          module Id = Reventless.Id.String
          let name = childName ++ "Async"
          @schema
          type command = JSON.t
        }
        module DcbAsyncCommandTopic = CommandTopic_Builder.Make(
          DcbCommandTopicSpecAsync,
          DcbCommandTopicChannelAsync,
        )
        let asyncDcbCommandTopicOpt = if asyncSlices->Array.length > 0 {
          let t = DcbAsyncCommandTopic.make(~name=`${childName}-dcb-async-command-topic`, ~opts)
          HooksConfig.hooks.onDcbCommandTopicCreated->Option.forEach(hook => hook(t->Obj.magic))
          Some(t)
        } else {
          None
        }

        let stateChangeSlicesOutputs =
          syncSlices
          ->Array.map((module(StateChangeSlice: StateChangeSlice.T)) => {
            let ch = StateChangeSlice.make(~dcbEventLog, ~publishJsons, ~opts)
            (StateChangeSlice.Spec.name, ch->Component.outputs)
          })
          ->Dict.fromArray

        // Create async slice components using the FIFO CommandTopic's publishJsons
        let asyncStateChangeSlicesOutputs =
          switch asyncDcbCommandTopicOpt {
          | None => Dict.make()
          | Some(asyncDcbCommandTopic) =>
            let asyncPublishJsons =
              asyncDcbCommandTopic->Component.operations->Pulumi.Output.apply(ops => ops.publishJsons)
            asyncSlices
            ->Array.map((module(StateChangeSlice: StateChangeSlice.T)) => {
              let ch = StateChangeSlice.make(~dcbEventLog, ~publishJsons=asyncPublishJsons, ~opts)
              (StateChangeSlice.Spec.name, ch->Component.outputs)
            })
            ->Dict.fromArray
          }

        // Phase 1: Register DCB mutation SDL + resolver stubs via platform hook
        switch HooksConfig.hooks.mutationResolverHook {
        | Some(registerResolver) =>
          syncSlices->Array.forEach((
            module(S: StateChangeSlice.T),
          ) => {
            let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
            if !(ApiNoApiHelpers.isNoApi(commandSchema)) {
              registerResolver(
                ~kind=Dcb,
                ~fields=[Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)],
                ~commandSchema,
              )
            }
          })
          asyncSlices->Array.forEach((
            module(S: StateChangeSlice.T),
          ) => {
            let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
            if !(ApiNoApiHelpers.isNoApi(commandSchema)) {
              registerResolver(
                ~kind=Dcb,
                ~fields=[Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)],
                ~commandSchema,
              )
            }
          })
        | None => ()
        }

        // Phase 2: Bind generateCommand to resolver stubs when publishJsons resolves
        // Sync slices use sync CommandTopic ops (publishJsonsAndWait → CommandAccepted/Rejected)
        // Async slices use async CommandTopic ops (publishJsons only → CommandPending)
        switch HooksConfig.hooks.mutationBindHook {
        | Some(bindHandler) =>
          let _ =
            dcbCommandTopic
            ->Component.operations
            ->Pulumi.Output.apply(ops => {
              syncSlices->Array.forEach((
                module(S: StateChangeSlice.T),
              ) => {
                let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
                if !(ApiNoApiHelpers.isNoApi(commandSchema)) {
                  let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)
                  let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
                    ~publishJsons=ops.publishJsons,
                    ~publishJsonsAndWait=?ops.publishJsonsAndWait,
                    ~serviceName=S.Spec.name,
                    ~commandSchema=S.Spec.commandSchema->Obj.magic,
                    ~componentKind=CommandGenerator_Callback.StateChangeSlice,
                    ~stripIdFromParams=false,
                  )
                  bindHandler(~field=fieldName, ~generateCommand)
                }
              })
            })
          switch asyncDcbCommandTopicOpt {
          | None => ()
          | Some(asyncDcbCommandTopic) =>
            let _ =
              asyncDcbCommandTopic
              ->Component.operations
              ->Pulumi.Output.apply(asyncOps => {
                asyncSlices->Array.forEach((
                  module(S: StateChangeSlice.T),
                ) => {
                  let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
                  if !(ApiNoApiHelpers.isNoApi(commandSchema)) {
                    let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)
                    let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
                      ~publishJsons=asyncOps.publishJsons,
                      ~publishJsonsAndWait=?asyncOps.publishJsonsAndWait,
                      ~serviceName=S.Spec.name,
                      ~commandSchema=S.Spec.commandSchema->Obj.magic,
                      ~componentKind=CommandGenerator_Callback.StateChangeSlice,
                      ~stripIdFromParams=false,
                    )
                    bindHandler(~field=fieldName, ~generateCommand)
                  }
                })
              })
          }
        | None => ()
        }

        // Populate query field names registry for all slice types BEFORE creating them
        stateViewSlices->Array.forEach((
          module(V: StateViewSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=V.Spec.name)
          let (labelField, _searchableFields) = Plugin_Structure.labelFieldsFromStateSchema(
            ~entityName=V.Spec.name,
            V.Spec.stateSchema->S.castToUnknown,
          )
          let qn = {
            ...qn,
            labelField,
            connectionFilterTypeName: qn.returnTypeName ++ "Filter",
          }
          let qn = switch V.Spec.subIdConfig {
          | Some(_) =>
            {
              ...qn,
              itemsFieldName: qn.singleFieldName ++ "Items",
              itemsFilterTypeName: qn.returnTypeName ++ "ItemsFilter",
            }
          | None => qn
          }
          Plugin_Helpers.queryFieldNamesRegistry->Dict.set(V.Spec.name, qn)
          Plugin_Helpers.stateSchemaRegistry->Dict.set(
            V.Spec.name,
            V.Spec.stateSchema->S.castToUnknown,
          )
        })

        automationSlices->Array.forEach((
          module(A: AutomationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=A.queryDbName)
          Plugin_Helpers.queryFieldNamesRegistry->Dict.set(A.queryDbName, qn)
        })

        outboundTranslationSlices->Array.forEach((
          module(O: OutboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=O.queryDbName)
          Plugin_Helpers.queryFieldNamesRegistry->Dict.set(O.queryDbName, qn)
        })

        inboundTranslationSlices->Array.forEach((
          module(I: InboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=I.queryDbName)
          Plugin_Helpers.queryFieldNamesRegistry->Dict.set(I.queryDbName, qn)
        })

        // Create StateViewSlices
        let stateViewSlicesOutputs =
          stateViewSlices
          ->Array.map((module(StateViewSlice: StateViewSlice.T)) => {
            let sv = StateViewSlice.make(~dcbEventLog, ~opts)
            (StateViewSlice.Spec.name, sv->Component.outputs)
          })
          ->Dict.fromArray

        // Build the full topic dict: aggregate event topics + this plugin's
        // own DCB event topic (keyed by `<pluginName>DcbEventLog` per Plan 03
        // convention). AutomationSlice mappings reference topics by these keys.
        let allEventTopics = aggregateEventTopics->Dict.copy
        allEventTopics->Dict.set(
          name ++ "DcbEventLog",
          (dcbEventLog->Component.outputs).eventTopic,
        )

        // Create AutomationSlices
        let automationSlicesOutputs =
          automationSlices
          ->Array.map((module(AutoSlice: AutomationSlice.T)) => {
            let context: Reventless.AutomationSlice.context = {
              environment,
              platformName,
              pluginName: name,
              sliceName: AutoSlice.Spec.name,
            }
            let as_ = AutoSlice.make(~allEventTopics, ~publishJsons, ~context, ~opts)
            (AutoSlice.Spec.name, as_->Component.outputs)
          })
          ->Dict.fromArray

        // Create OutboundTranslationSlices
        let outboundTranslationSlicesOutputs =
          outboundTranslationSlices
          ->Array.map((module(OTS: OutboundTranslationSlice.T)) => {
            let ots = OTS.make(~dcbEventLog, ~publishJsons, ~opts)
            (OTS.Spec.name, ots->Component.outputs)
          })
          ->Dict.fromArray

        // Create InboundTranslationSlices
        let inboundTranslationSliceData =
          inboundTranslationSlices->Array.map((
            module(ITS: InboundTranslationSlice.T),
          ) => {
            let its = ITS.make(~publishJsons, ~opts)
            let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=ITS.Spec.name)

            switch HooksConfig.hooks.inboundMutationResolverHook {
            | Some(registerResolver) =>
              registerResolver(
                ~fieldName,
                ~externalInputSchema=ITS.Spec.externalInputSchema->S.castToUnknown,
              )
            | None => ()
            }

            switch HooksConfig.hooks.inboundMutationBindReceiveHook {
            | Some(bindReceive) =>
              let _ =
                its
                ->Component.operations
                ->Pulumi.Output.apply(ops => bindReceive(~fieldName, ~receive=ops.receive))
            | None => ()
            }

            (ITS.Spec.name, fieldName, its, ITS.Spec.externalInputSchema->S.castToUnknown)
          })

        let inboundTranslationSlicesOutputs =
          inboundTranslationSliceData
          ->Array.map(((specName, _, its, _)) => (specName, its->Component.outputs))
          ->Dict.fromArray

        // Collect InboundTranslationSlice receive functions for composite handler routing
        let inboundReceiversOutput =
          inboundTranslationSliceData
          ->Array.map(((_, fieldName, its, _)) =>
            its
            ->Component.operations
            ->Pulumi.Output.apply(ops => (fieldName, ops.receive))
          )
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray)

        // Composite handler: SQS commands (StateChangeSlice) + direct invocations (InboundTranslation)
        // + AppSync direct invocations (CommandGenerator.payload format)
        let dcbHandlerBase = DcbCommandTopic.makeFilteringHandler(dcbCommandTopic)

        // Shared generateCommand for AppSync direct invocations — all sync StateChangeSlices
        // share the same DCB CommandTopic's publishJsons, so a single function suffices.
        // commandSchema validation is skipped (permissive JSON.t schema) because AppSync
        // already validates input against the SDL.
        let dcbGenerateCommandOutput =
          dcbCommandTopic
          ->Component.operations
          ->Pulumi.Output.apply(ops =>
            CommandGenerator_Callback.makeGenerateCommand(
              ~publishJsons=ops.publishJsons,
              ~publishJsonsAndWait=?ops.publishJsonsAndWait,
              ~serviceName=name,
              ~commandSchema=S.json->S.castToUnknown,
              ~componentKind=CommandGenerator_Callback.StateChangeSlice,
              ~stripIdFromParams=false,
            )
          )

        let dcbHandler =
          (dcbHandlerBase, inboundReceiversOutput, dcbGenerateCommandOutput)
          ->Pulumi.Output.all3
          ->Pulumi.Output.apply(((baseHandler, receivers, generateCommand)) => {
            let composite = (event, ctx) => {
              let raw: dict<JSON.t> = event->Obj.magic
              switch raw->Dict.get("__inboundTranslation") {
              | Some(_) =>
                let fieldName =
                  raw
                  ->Dict.get("fieldName")
                  ->Option.flatMap(JSON.Decode.string)
                  ->Option.getOr("")
                let args = raw->Dict.get("arguments")->Option.getOr(JSON.Encode.null)
                switch receivers->Dict.get(fieldName) {
                | Some(receiveFn) =>
                  Effect.promise(async () => {
                    let result = await receiveFn(args)
                    let response = switch result {
                    | Ok(targetIds) =>
                      targetIds->Array.map(JSON.Encode.string)->JSON.Encode.array
                    | Error(msg) => msg->JSON.Encode.string
                    }
                    response->Obj.magic
                  })
                | None => baseHandler(event, ctx)
                }
              | None =>
                // Check for CommandGenerator.payload format (AppSync direct invocation)
                switch (raw->Dict.get("command"), raw->Dict.get("arguments")) {
                | (Some(JSON.String(_)), Some(_)) =>
                  let payload: CommandGenerator.payload = event->Obj.magic
                  (generateCommand(payload)->Effect.map(msgId => msgId->Obj.magic))->Obj.magic
                | _ => baseHandler(event, ctx)
                }
              }
            }
            composite->Obj.magic
          })

        // Resources the sync Lambda needs access to
        let dcbResources = Array.concat(
          stateChangeSlicesOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources),
          inboundTranslationSlicesOutputs
          ->Dict.valuesToArray
          ->Array.flatMap(outputs => outputs.resources),
        )

        // Resources the async Lambda needs access to
        let asyncDcbResources =
          asyncStateChangeSlicesOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources)

        let inboundFieldNames =
          inboundTranslationSliceData->Array.map(((_, fieldName, _, _)) => fieldName)
        let inboundSchemas = inboundTranslationSliceData->Array.map(((_, _, _, schema)) => schema)

        // Collect DCB mutation field names + TAGs for AppSync resolver creation
        // (excludes @noApi slices — includes both sync and async)
        let dcbMutationData =
          stateChangeSlices->Array.filterMap((
            module(S: StateChangeSlice.T),
          ) => {
            let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
            if ApiNoApiHelpers.isNoApi(commandSchema) {
              None
            } else {
              let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)
              let constructorNames =
                Reventless.DcbTag.extractVariantNames(S.Spec.commandSchema->Obj.magic)
              let tag = constructorNames->Array.get(0)->Option.getOr(S.Spec.name)
              Some((fieldName, tag))
            }
          })
        let dcbFieldNames = dcbMutationData->Array.map(((f, _)) => f)
        let dcbTags = dcbMutationData->Array.map(((_, t)) => t)

        let dcbConnectFn = (~runtime) => {
          DcbCommandTopic.connect(~runtime, ~resources=dcbResources, dcbCommandTopic)

          if inboundFieldNames->Array.length > 0 {
            switch HooksConfig.hooks.inboundAppSyncResolverHook {
            | Some(hook) =>
              hook({
                runtime: runtime->Obj.magic,
                fieldNames: inboundFieldNames,
                externalInputSchemas: inboundSchemas,
                opts,
              })
            | None => ()
            }
          }

          if dcbFieldNames->Array.length > 0 {
            switch HooksConfig.hooks.dcbAppSyncResolverHook {
            | Some(hook) =>
              hook({
                runtime: runtime->Obj.magic,
                fieldNames: dcbFieldNames,
                tags: dcbTags,
                opts,
              })
            | None => ()
            }
          }
        }

        // Notify platform hook that all DCB slices are created (AWS calls finish on bundled builders).
        // Pass dcbEventLog so the platform can wait for its operations to resolve before calling finish().
        HooksConfig.hooks.onDcbSlicesCreated->Option.forEach(hook =>
          hook(dcbEventLog->Obj.magic)
        )

        let dcbRuntimeSetup = () => {
          dcbCommandTopic->RuntimeBuilder.forDcbCommandTopic(
            ~handler=dcbHandler,
            ~connect=dcbConnectFn,
          )
          // Set up async CommandTopic Lambda if any async slices are configured
          asyncDcbCommandTopicOpt->Option.forEach(asyncDcbCommandTopic => {
            let asyncDcbHandler = DcbAsyncCommandTopic.makeFilteringHandler(asyncDcbCommandTopic)
            let asyncDcbConnectFn = (~runtime) =>
              DcbAsyncCommandTopic.connect(
                ~runtime,
                ~resources=asyncDcbResources,
                asyncDcbCommandTopic,
              )
            asyncDcbCommandTopic->RuntimeBuilder.forDcbCommandTopic(
              ~handler=asyncDcbHandler->Obj.magic,
              ~connect=asyncDcbConnectFn,
            )
          })
        }

        // DCB-specific API schema entries
        let mutationEntriesFromSlices =
          stateChangeSlices->Array.filterMap((
            module(S: StateChangeSlice.T),
          ) => {
            let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
            if ApiNoApiHelpers.isNoApi(commandSchema) {
              None
            } else {
              let sliceDef =
                pluginStructure->Option.flatMap(s =>
                  s.stateChangeSlices->Array.find(d => d.name == S.Spec.name)
                )
              Some({
                ReventlessInfra.Api.fieldNames: [Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)],
                commandSchema,
                linkedViews: ?sliceDef->Option.map(d => d.linkedViews),
                consistencyRead: ?sliceDef->Option.flatMap(d => d.consistencyRead),
              })
            }
          })

        let mutationEntriesFromInboundSlices =
          inboundTranslationSlices->Array.map((
            module(ITS: InboundTranslationSlice.T),
          ) => {
            ReventlessInfra.Api.fieldNames: [Api_Naming.sliceMutationField(~plugin=name, ~slice=ITS.Spec.name)],
            commandSchema: ITS.Spec.externalInputSchema->S.castToUnknown,
          })

        let stateViewEntries = stateViewSlices->Array.map((
          module(V: StateViewSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=V.Spec.name)
          let subIdField = V.Spec.subIdConfig->Option.map(c => c.subIdField)
          let indexes = V.Spec.config.indexes
          let indexQueries = if indexes->Array.length > 0 {Some(indexes)} else {None}
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: V.Spec.stateSchema->Reventless.DcbTag.toUnknownSchema,
            authorization: None,
            includeIdParam: qn.includeIdParam,
            connectionSpec: true,
            subIdField: ?subIdField,
            indexQueries: ?indexQueries,
          }
        })

        let automationEntries = automationSlices->Array.map((
          module(A: AutomationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=A.queryDbName)
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: AutomationSlice_Callback.todoRowSchema->S.castToUnknown,
            authorization: None,
            connectionSpec: true,
          }
        })

        let outboundEntries = outboundTranslationSlices->Array.map((
          module(O: OutboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=O.queryDbName)
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: OutboundTranslationSlice_Callback.todoRowSchema->S.castToUnknown,
            authorization: None,
            connectionSpec: true,
          }
        })

        let inboundEntries = inboundTranslationSlices->Array.map((
          module(I: InboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=I.queryDbName)
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: InboundTranslationSlice_Callback.auditRowSchema->S.castToUnknown,
            authorization: None,
            connectionSpec: true,
          }
        })

        // Collect all event schemas from produced events for eventLogEntries
        let allProducedSchemas =
          stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            Sc.Spec.eventSchema->S.castToUnknown
          )

        {
          dcbEventLogOutputs: Some(dcbEventLog->Component.outputs),
          stateChangeSlicesOutputs: Dict.fromArray(
            Array.concat(
              stateChangeSlicesOutputs->Dict.toArray,
              asyncStateChangeSlicesOutputs->Dict.toArray,
            ),
          ),
          stateViewSlicesOutputs,
          automationSlicesOutputs,
          outboundTranslationSlicesOutputs,
          inboundTranslationSlicesOutputs,
          dcbRuntimeSetup: Some(dcbRuntimeSetup),
          dcbPublishJsons: Some(publishJsons),
          mutationEntries: Array.concat(mutationEntriesFromSlices, mutationEntriesFromInboundSlices),
          queryEntries: stateViewEntries
            ->Array.concat(automationEntries)
            ->Array.concat(outboundEntries)
            ->Array.concat(inboundEntries),
          eventLogEntries: if allProducedSchemas->Array.length > 0 {
            // Use the first produced event schema as representative for the event log
            [
              {
                ReventlessInfra.Api.busKey: name ++ "DcbEventLog",
                displayName: name,
                eventSchema: allProducedSchemas->Array.getUnsafe(0),
              },
            ]
          } else {
            []
          },
        }
    } else {
      emptyResult
    }
  }
}
