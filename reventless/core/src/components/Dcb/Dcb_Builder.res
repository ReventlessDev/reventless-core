// Converts a file:// module URL to a path relative to the project root (located by lerna.json),
// resolving symlinks so workspace packages show their source location rather than node_modules.
// Falls back to the bare URL string on any error.
let log = Logger.fromEnv()

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
  // SQS URL of the DCB command topic — shared by all StateChangeSlices in this
  // plugin. Surfaced so the bundled Plugin EventCollector Lambda can dispatch
  // PublishStateChangeSliceCommand actions from user extensions to the right
  // queue. Resolves to "" when the plugin has no DCB slices — deliberately NOT
  // option<Pulumi.Output.t<string>> (that combination is a repo-wide
  // anti-pattern; it minted the nested-option sentinel that broke the
  // collector's SendMessage grant). The Output is gated on the topic's
  // `Component.operations`, so it resolves only after the topic finished
  // constructing — see the construction site and
  // docs/analysis/ec-publish-to-aggregates-grant-broken.md.
  dcbCommandTopicQueueUrl: Pulumi.Output.t<string>,
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
  dcbCommandTopicQueueUrl: Pulumi.Output.make(""),
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
    // API mutation-field prefix for a slice's GraphQL command fields. Defaults to `name`
    // (`${plugin}_${command}`), so plugins are unchanged. The admin builder passes "Platform"
    // so its exposed slice commands render as `Platform_RegisterApiFragment` — byte-equal to
    // `Api_Naming.adminField("RegisterApiFragment")`, keeping the hand-declared admin SDL and
    // the auto-bound DCB resolver field names aligned.
    ~apiNamePrefix: string=name,
    // True for the platform admin build — routes the DCB mutation resolvers to the Platform API
    // (via the provider hook's `hooks.adminApi`) in split mode. Plugins leave it false.
    ~onAdminApi: bool=false,
    ~environment: string="",
    ~platformName: string="",
    ~aggregateEventTopics: EventTopic.allOutputs=Dict.make(),
    // `(Aggregate name, its event schema)` for every aggregate in this plugin.
    // Feeds the produced/consumed check only — an outbound or automation slice
    // may name an Aggregate as a source, and without these its events look like
    // events nothing produces. Deliberately *not* folded into `produced`, which
    // also drives DCB GSI creation: an aggregate's events live on its own
    // EventLog and must not mint indexes on the DCB table.
    ~aggregateProducedEvents: array<(string, S.t<unknown>)>=[],
    // Per-aggregate command publishers, keyed by Aggregate `Spec.name`. An
    // OutboundTranslationSlice naming one in `targetName` publishes its command
    // through that aggregate's CommandTopic instead of this plugin's DCB topic —
    // the two are handled by different Lambdas, so sending an aggregate command
    // to the DCB queue delivers it somewhere nothing handles it.
    //
    // Populated before this runs (`createAggregatesWithoutEventMappers`), so the
    // publisher is in hand by the time a slice is built. DCB StateChangeSlice
    // publishers are registered *after* and are deliberately absent: a slice
    // targeting one wants the DCB topic, which is the fallback.
    ~publishToAggregates: dict<Pulumi.Output.t<CommandTopic.publishJsons>>=Dict.make(),
    ~stateChangeSlices: array<module(StateChangeSlice.T)>,
    ~stateViewSlices: array<module(StateViewSlice.T)>,
    ~automationSlices: array<module(AutomationSlice.T)>,
    ~outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>,
    ~inboundTranslationSlices: array<module(InboundTranslationSlice.T)>,
    // Spec names of slices whose GraphQL fields a deploy-time system caller
    // (machine credentials — IAM/SigV4 on AWS) must invoke — sets
    // `systemCallable` on the matching mutation / state-view query schema entries.
    ~systemCallableComponents: array<string>=[],
    // Per-component runtime hints keyed by slice `Spec.name`; forwarded into each
    // slice's `make`. Empty for admin/legacy callers.
    ~componentRuntime: dict<ReventlessInfra.RuntimeHints.t>=Dict.make(),
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

        switch Reventless.DcbValidation.validateProducedAndConsumed(
          ~produced=produced->Array.concat(aggregateProducedEvents),
          ~consumed,
        ) {
        | Error(errors) =>
          errors->Array.forEach(err =>
            log.error(~comp="Dcb_Builder", `DCB validation error (${err.sliceName}): ${err.message}`)
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

        // Tag keys declared `@crossPartition` across the produced event schemas.
        // Derived once at build time (the scope is a property of the tag key, and
        // must agree across every producer that carries it). Threaded to both the
        // decision-model query builder (fan a cross-partition scalar tag into its
        // own single-tag clause) and the storage adapter (read routing +
        // fence scope), keeping read-scope = fence-scope per tag.
        let crossPartitionTagKeys =
          producedSchemas
          ->Array.flatMap(schema => Reventless.DcbTag.extractCrossPartitionTagKeys(schema))
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

        // A tag key's scope must agree across every producer that carries it,
        // else the (writer-driven) fence is ambiguous. Non-fatal — surfaces a
        // mismatch loudly without aborting the deploy.
        Reventless.DcbValidation.validateCrossPartitionScope(
          ~producers=produced,
        )->Array.forEach(err =>
          log.error(
            ~comp="Dcb_Builder",
            `DCB cross-partition scope error (${err.sliceName}): ${err.message}`,
          )
        )

        // Map each produced event type to its full produced tag-key set. Threaded
        // into each StateChangeSlice so the decision-model query drops vacuous
        // (type, tag) clause combinations (a type that can't carry the clause's
        // tag) — pure dead-clause removal, results unchanged. Built from the
        // producer schemas (not consumers' `consumedEventSchema`, which may
        // under-declare tags a slice legitimately reads by).
        let tagKeysByEventType =
          producedSchemas
          ->Array.map(schema => Reventless.DcbTag.extractTagKeysByEventType(schema))
          ->Reventless.DcbTag.mergeTagKeysByEventType

        // Warn on composite (multi-tag) decision reads that would silently miss an
        // event carrying extra tags (the tag_composite key is the event's full tag
        // set, so composite reads are exact-match). Non-fatal — today's slices are
        // aligned; the guard catches a tag added to a multi-tag event later.
        Reventless.DcbValidation.validateCompositeReads(
          ~slices=stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) => (
            Sc.Spec.name,
            Sc.Spec.commandSchema->S.castToUnknown,
            Sc.Spec.consumedEventSchema->S.castToUnknown,
          )),
          ~producedTagKeys=tagKeysByEventType,
        )->Array.forEach(w =>
          log.warn(~comp="Dcb_Builder", `DCB composite-read warning (${w.sliceName}): ${w.message}`)
        )

        // --- Phase 2 (dcb-tag-scope-inference): derive scope from the global slice
        // graph and THREAD it into the decision-query wiring, replacing the
        // annotation-based extraction. The derived `tagKeysByEventType` is what
        // fixes the sibling leak — a foreign reference key (e.g. `categoryId` on
        // `ProductAdded`) is payload, so the cross-partition read clause no longer
        // sweeps up sibling products. Cross-partition fan-out and capacity reads are
        // preserved (generalised rule 3). Safety guard: if any slice's partition is
        // ambiguous we keep the annotated values for the whole boundary rather than
        // thread a partial inference. See docs/plans/dcb-tag-scope-inference.md.
        let inferenceShapes =
          stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            Reventless.DcbTag.sliceShapeFromSchemas(
              ~name=Sc.Spec.name,
              ~commandSchema=Sc.Spec.commandSchema->S.castToUnknown,
              ~consumedEventSchema=Sc.Spec.consumedEventSchema->S.castToUnknown,
              ~eventSchema=Sc.Spec.eventSchema->S.castToUnknown,
            )
          )
        let inferred = Reventless.DcbScopeInference.infer(inferenceShapes)
        if inferred.crossPartitionTagKeys != crossPartitionTagKeys {
          log.info(
            ~comp="Dcb_Builder",
            `DCB scope-inference diff: crossPartitionTagKeys annotated=[${crossPartitionTagKeys->Array.join(
                ", ",
              )}] inferred=[${inferred.crossPartitionTagKeys->Array.join(", ")}]`,
          )
        }
        inferred.tagKeysByEventType
        ->Dict.toArray
        ->Array.forEach(((eventType, inferredKeys)) => {
          let annotatedKeys = tagKeysByEventType->Dict.get(eventType)->Option.getOr([])
          let dropped = annotatedKeys->Array.filter(k => !(inferredKeys->Array.includes(k)))
          if dropped->Array.length > 0 {
            log.info(
              ~comp="Dcb_Builder",
              `DCB scope-inference diff: ${eventType} indexes [${inferredKeys->Array.join(
                  ", ",
                )}] (inferred) vs [${annotatedKeys->Array.join(
                  ", ",
                )}] (annotated) — payload now: [${dropped->Array.join(", ")}]`,
            )
          }
        })
        inferred.ambiguities->Array.forEach(((sliceName, reason)) =>
          log.warn(
            ~comp="Dcb_Builder",
            `DCB scope-inference ambiguity (${sliceName}): ${reason}`,
          )
        )

        // Validate any remaining explicit @crossPartition against the derived scope:
        // contradictions (a key marked cross-partition that is the slice's own
        // partition) are likely bugs; redundant annotations can simply be dropped.
        let scopeAnnotations =
          stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) => (
            Sc.Spec.name,
            Reventless.DcbTag.extractCrossPartitionTagKeys(Sc.Spec.eventSchema->S.castToUnknown),
          ))
        let scopeIssues = Reventless.DcbValidation.validateScopeVsInference(
          ~annotations=scopeAnnotations,
          ~inferred,
        )
        scopeIssues.contradictions->Array.forEach(e =>
          log.warn(~comp="Dcb_Builder", `DCB scope contradiction (${e.sliceName}): ${e.message}`)
        )
        scopeIssues.redundancies->Array.forEach(e =>
          log.info(~comp="Dcb_Builder", `DCB scope (${e.sliceName}): ${e.message}`)
        )

        // All-or-nothing: thread the derived scope only when every slice resolved.
        // An ambiguous boundary keeps the annotated values (no partial inference).
        // Both this builder and the deployed command-handler entry point
        // (DcbCommandTopicEntryPoint.mjs) route through `DcbTag.deriveEffectiveScope`
        // so the runtime decision query cannot drift from this scope — see
        // docs/analysis/dcb-runtime-scope-annotation-drift.md.
        let {
          crossPartitionTagKeys: effectiveCrossPartitionTagKeys,
          tagKeysByEventType: effectiveTagKeysByEventType,
        } = Reventless.DcbTag.deriveEffectiveScope(
          stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) => {
            Reventless.DcbTag.name: Sc.Spec.name,
            commandSchema: Sc.Spec.commandSchema->S.castToUnknown,
            consumedEventSchema: Sc.Spec.consumedEventSchema->S.castToUnknown,
            eventSchema: Sc.Spec.eventSchema->S.castToUnknown,
          }),
        )

        module DcbEventLog = DcbEventLog_Builder.Make(
          DcbEventLogStorage,
          DcbEventTopicPublisher,
        )
        let dcbEventLog =
          DcbEventLog.make(
            ~name,
            ~indexes,
            ~partitionTag,
            ~crossPartitionTagKeys=effectiveCrossPartitionTagKeys,
            ~opts,
          )

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
        let dcbCommandTopic = DcbCommandTopic.make(~name=`${name}Dcb`, ~owner={kind: ComponentType.Plugin, name}, ~opts)

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
          let t = DcbAsyncCommandTopic.make(~name=`${name}DcbAsync`, ~owner={kind: ComponentType.Plugin, name}, ~opts)
          HooksConfig.hooks.onDcbCommandTopicCreated->Option.forEach(hook => hook(t->Obj.magic))
          Some(t)
        } else {
          None
        }

        let stateChangeSlicesOutputs =
          syncSlices
          ->Array.map((module(StateChangeSlice: StateChangeSlice.T)) => {
            let ch = StateChangeSlice.make(
              ~dcbEventLog,
              ~publishJsons,
              ~tagKeysByEventType=effectiveTagKeysByEventType,
              ~crossPartitionTagKeys=effectiveCrossPartitionTagKeys,
              ~runtime=?componentRuntime->Dict.get(StateChangeSlice.Spec.name),
              ~opts,
            )
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
              let ch = StateChangeSlice.make(
                ~dcbEventLog,
                ~publishJsons=asyncPublishJsons,
                ~tagKeysByEventType=effectiveTagKeysByEventType,
                ~crossPartitionTagKeys=effectiveCrossPartitionTagKeys,
                ~runtime=?componentRuntime->Dict.get(StateChangeSlice.Spec.name),
                ~opts,
              )
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
                ~fields=Api_Naming.sliceMutationFields(
                  ~plugin=apiNamePrefix,
                  ~slice=S.Spec.name,
                  ~commandSchema,
                )->Array.map(((f, _)) => f),
                ~commandSchema,
                ~commandAuthorization=S.Spec.commandAuthorization->Obj.magic,
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
                ~fields=Api_Naming.sliceMutationFields(
                  ~plugin=apiNamePrefix,
                  ~slice=S.Spec.name,
                  ~commandSchema,
                )->Array.map(((f, _)) => f),
                ~commandSchema,
                ~commandAuthorization=S.Spec.commandAuthorization->Obj.magic,
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
                  // One generateCommand backs every constructor's field — the TAG is
                  // injected by the resolver per field, so a single binding suffices.
                  let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
                    ~publishJsons=ops.publishJsons,
                    ~publishJsonsAndWait=?ops.publishJsonsAndWait,
                    ~serviceName=S.Spec.name,
                    ~commandSchema=S.Spec.commandSchema->Obj.magic,
                    ~componentKind=CommandGenerator_Callback.StateChangeSlice,
                    ~stripIdFromParams=false,
                  )
                  Api_Naming.sliceMutationFields(~plugin=apiNamePrefix, ~slice=S.Spec.name, ~commandSchema)
                  ->Array.forEach(((fieldName, _)) => bindHandler(~field=fieldName, ~generateCommand))
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
                    // One generateCommand backs every constructor's field — the TAG is
                    // injected by the resolver per field, so a single binding suffices.
                    let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
                      ~publishJsons=asyncOps.publishJsons,
                      ~publishJsonsAndWait=?asyncOps.publishJsonsAndWait,
                      ~serviceName=S.Spec.name,
                      ~commandSchema=S.Spec.commandSchema->Obj.magic,
                      ~componentKind=CommandGenerator_Callback.StateChangeSlice,
                      ~stripIdFromParams=false,
                    )
                    Api_Naming.sliceMutationFields(~plugin=apiNamePrefix, ~slice=S.Spec.name, ~commandSchema)
                    ->Array.forEach(((fieldName, _)) => bindHandler(~field=fieldName, ~generateCommand))
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
          let label = Plugin_Structure.labelFieldsFromStateSchema(
            ~entityName=V.Spec.name,
            V.Spec.stateSchema->S.castToUnknown,
          )
          let qn = {
            ...qn,
            labelField: label.field,
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
            let sv = StateViewSlice.make(
              ~dcbEventLog,
              ~runtime=?componentRuntime->Dict.get(StateViewSlice.Spec.name),
              ~opts,
            )
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
            let as_ = AutoSlice.make(
              ~allEventTopics,
              ~publishJsons,
              ~context,
              ~runtime=?componentRuntime->Dict.get(AutoSlice.Spec.name),
              ~opts,
            )
            (AutoSlice.Spec.name, as_->Component.outputs)
          })
          ->Dict.fromArray

        // Create OutboundTranslationSlices
        let outboundTranslationSlicesOutputs =
          outboundTranslationSlices
          ->Array.map((module(OTS: OutboundTranslationSlice.T)) => {
            // Where this slice's inbound command goes. `targetName` naming an
            // Aggregate routes to that aggregate's CommandTopic; anything else —
            // a DCB slice, or no target at all — keeps the plugin's DCB topic,
            // which is what every slice wanted before aggregates were reachable.
            let targetPublishJsons =
              OTS.Spec.targetName
              ->Option.flatMap(target => publishToAggregates->Dict.get(target))
              ->Option.getOr(publishJsons)

            let ots = OTS.make(
              ~dcbEventLog,
              // Same dict the AutomationSlices get, so an outbound slice can
              // name an Aggregate source by its Spec.name.
              ~allEventTopics,
              ~publishJsons=targetPublishJsons,
              ~runtime=?componentRuntime->Dict.get(OTS.Spec.name),
              ~opts,
            )
            (OTS.Spec.name, ots->Component.outputs)
          })
          ->Dict.fromArray

        // Create InboundTranslationSlices
        let inboundTranslationSliceData =
          inboundTranslationSlices->Array.map((
            module(ITS: InboundTranslationSlice.T),
          ) => {
            let its = ITS.make(
              ~publishJsons,
              ~runtime=?componentRuntime->Dict.get(ITS.Spec.name),
              ~opts,
            )
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
                    let response =
                      result
                      ->InboundTranslationSlice_Callback.receiveResultToOutcome
                      ->CommandTopic.commandOutcomeToJson
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

        // Resources the sync Lambda needs access to. An InboundTranslationSlice
        // exposes its audit table under `queryDb.resources` — its top-level
        // `resources` is empty — and the sync DCB command Lambda is the Route 0
        // target that writes those audit rows. Granting only `outputs.resources`
        // left the Lambda role without `PutItem` on the audit table, so every
        // audit write failed with AccessDenied (swallowed at the write site,
        // surfacing only as a permanently empty audit view). Include the audit
        // table's resources so the role can write it.
        let dcbResources = Array.concat(
          stateChangeSlicesOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources),
          inboundTranslationSlicesOutputs
          ->Dict.valuesToArray
          ->Array.flatMap(outputs => Array.concat(outputs.resources, outputs.queryDb.resources)),
        )

        // Resources the async Lambda needs access to
        let asyncDcbResources =
          asyncStateChangeSlicesOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources)

        let inboundFieldNames =
          inboundTranslationSliceData->Array.map(((_, fieldName, _, _)) => fieldName)
        let inboundSchemas = inboundTranslationSliceData->Array.map(((_, _, _, schema)) => schema)

        // Collect DCB mutation field names + TAGs for AppSync resolver creation
        // (excludes @noApi slices — includes both sync and async)
        // One (fieldName, TAG) pair per API-exposed command constructor. The AWS
        // resolver layer (CommandGeneratorResolvers_AppSync.makeDcb) zips these into
        // one resolver per field, each injecting its own constructor TAG into the
        // Lambda payload — so a multi-command slice's every command is dispatchable.
        let dcbMutationData =
          stateChangeSlices->Array.flatMap((
            module(S: StateChangeSlice.T),
          ) => {
            let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
            if ApiNoApiHelpers.isNoApi(commandSchema) {
              []
            } else {
              Api_Naming.sliceMutationFields(~plugin=apiNamePrefix, ~slice=S.Spec.name, ~commandSchema)
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
                onAdminApi,
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

        // Per-component runtime overrides (plugin.json `runtime`) for the
        // StateChangeSlices hosted on each shared DCB command Lambda. Only
        // explicit overrides contribute (default 0); the platform folds them
        // with the per-flavor commandHandlerConfig floor. Sync slices land on
        // `<Plugin>DcbCmdHandler`, async on `<Plugin>DcbAsyncCmdHandler`.
        let sliceMemoryFloor = slices =>
          slices->Array.reduce(0, (acc, module(M: StateChangeSlice.T)) =>
            Math.Int.max(acc, ReventlessInfra.RuntimeHints.resolveMemory(componentRuntime->Dict.get(M.Spec.name), ~default=0))
          )
        let sliceTimeoutFloor = slices =>
          slices->Array.reduce(0, (acc, module(M: StateChangeSlice.T)) =>
            Math.Int.max(acc, ReventlessInfra.RuntimeHints.resolveTimeout(componentRuntime->Dict.get(M.Spec.name), ~default=0))
          )

        let dcbRuntimeSetup = () => {
          dcbCommandTopic->RuntimeBuilder.forDcbCommandTopic(
            ~handler=dcbHandler,
            ~connect=dcbConnectFn,
            ~memorySize=sliceMemoryFloor(syncSlices),
            ~timeout=sliceTimeoutFloor(syncSlices),
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
              ~memorySize=sliceMemoryFloor(asyncSlices),
              ~timeout=sliceTimeoutFloor(asyncSlices),
            )
          })
        }

        // DCB-specific API schema entries
        //
        // Stage E2: a DCB StateChangeSlice has a single GraphQL field but its
        // command type may declare multiple constructors with different
        // authorization rules. The @aws_auth directive operates at field
        // granularity, so we read the auth for the first constructor (matching
        // the existing dcbTags convention at line 549 above). When all
        // constructors share the file-level default, this is exact; when they
        // differ, resolver-level enforcement still fires inside the per-slice
        // handler (the file-level rule applied here is the least-restrictive
        // bound).
        let permissionForFirstConstructor = (
          ~commandSchema: S.t<unknown>,
          ~commandAuthorization: unknown => Reventless.Authorization.permission,
        ): option<Reventless.Authorization.permission> => {
          let names = Reventless.DcbTag.extractAllVariantNames(commandSchema->Obj.magic)
          switch names->Array.get(0) {
          | None => None
          | Some(first) =>
            let hasPayload =
              Reventless.DcbTag.isVariantPayloadBearing(commandSchema->Obj.magic, first)
            let syntheticCmd: unknown =
              hasPayload ? {"TAG": first}->Obj.magic : first->Obj.magic
            Some(commandAuthorization(syntheticCmd))
          }
        }
        let mutationEntriesFromSlices =
          stateChangeSlices->Array.filterMap((
            module(S: StateChangeSlice.T),
          ) => {
            let commandSchema = S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema
            let fieldSpecs =
              Api_Naming.sliceMutationFields(~plugin=apiNamePrefix, ~slice=S.Spec.name, ~commandSchema)
            if ApiNoApiHelpers.isNoApi(commandSchema) || fieldSpecs->Array.length == 0 {
              None
            } else {
              let sliceDef =
                pluginStructure->Option.flatMap(s =>
                  s.stateChangeSlices->Array.find(d => d.name == S.Spec.name)
                )
              // One SDL field per constructor, each with its own constructor's args and
              // its own per-constructor authorization rule.
              let commandAuthorization: unknown => Reventless.Authorization.permission =
                S.Spec.commandAuthorization->Obj.magic
              let fieldPermissions = Dict.make()
              fieldSpecs->Array.forEach(((fieldName, ctor)) => {
                let hasPayload =
                  Reventless.DcbTag.isVariantPayloadBearing(commandSchema->Obj.magic, ctor)
                let syntheticCmd: unknown =
                  hasPayload ? {"TAG": ctor}->Obj.magic : ctor->Obj.magic
                fieldPermissions->Dict.set(fieldName, commandAuthorization(syntheticCmd))
              })
              Some({
                ReventlessInfra.Api.fieldNames: fieldSpecs->Array.map(((f, _)) => f),
                commandSchema,
                fieldPermissions,
                // Slice key fields (e.g. `orderId`) are payload args; there is no
                // separate aggregate `id`. A multi-variant slice command is a sury
                // `Union`, so without this the generator would inject `id: ID!`.
                injectIdArg: false,
                systemCallable: systemCallableComponents->Array.includes(S.Spec.name),
                linkedViews: ?sliceDef->Option.map(d => d.linkedViews),
                consistencyRead: ?sliceDef->Option.flatMap(d => d.consistencyRead),
              })
            }
          })

        let mutationEntriesFromInboundSlices =
          inboundTranslationSlices->Array.map((
            module(ITS: InboundTranslationSlice.T),
          ) => {
            let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=ITS.Spec.name)
            let fieldPermissions = Dict.make()
            switch permissionForFirstConstructor(
              ~commandSchema=ITS.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema,
              ~commandAuthorization=ITS.Spec.commandAuthorization->Obj.magic,
            ) {
            | Some(rule) => fieldPermissions->Dict.set(fieldName, rule)
            | None => ()
            }
            {
              ReventlessInfra.Api.fieldNames: [fieldName],
              commandSchema: ITS.Spec.externalInputSchema->S.castToUnknown,
              fieldPermissions,
              injectIdArg: false,
            }
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
            permission: V.Spec.authorization,
            systemCallable: systemCallableComponents->Array.includes(V.Spec.name),
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
            stateSchema: AutomationSlice_Callback.todoRowSchemaFor(
              A.Spec.todoItemSchema,
            )->S.castToUnknown,
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
            stateSchema: OutboundTranslationSlice_Callback.todoRowSchemaFor(
              O.Spec.outboundItemSchema,
            )->S.castToUnknown,
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

        // Derive the DCB command topic's queue URL *after* the component's
        // construct has stored its real resources. This reads `Component.outputs`
        // as a synchronous side channel inside a callback gated on a DIFFERENT
        // output (`Component.operations`, which resolves only post-construct) —
        // reading `resources[0].id` at build time instead captured the SQS
        // Queue's not-yet-resolved `.id`, which degenerated to the
        // `{BS_PRIVATE_NESTED_SOME_NONE: 0}` nested-option sentinel and silently
        // broke the Plugin EventCollector's sqs:SendMessage grant (cross-plugin
        // extension → DCB-slice publishes → IAM AccessDenied).
        //
        // CONSUMER CONSTRAINT: because the value comes from that gated
        // side-channel read (not from the `operations` payload itself), it must
        // be resolved with a direct `.apply`, NOT batched through
        // `Pulumi.Output.all`/`all2` — `all` invokes the callback at a different
        // point in the graph where the side-channel read still yields the
        // sentinel (verified on both preview and up). The EC grant builder
        // therefore resolves it per-target. See
        // docs/analysis/ec-publish-to-aggregates-grant-broken.md.
        let dcbCommandTopicQueueUrl =
          dcbCommandTopic
          ->Component.operations
          ->Pulumi.Output.flatMap(_ops => {
            let outputs: CommandTopic.outputs = dcbCommandTopic->Component.outputs->Obj.magic
            switch outputs.resources->Array.get(0) {
            | Some(r) => r.id
            | None => Pulumi.Output.make("")
            }
          })
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
          dcbCommandTopicQueueUrl,
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
