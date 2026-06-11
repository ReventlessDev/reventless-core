// Pure metadata extraction from spec modules.
// Extracts the pluginStructure (component graph metadata) that Auto UI, the
// event-graph view, and MCP tooling consume. Kept standalone so it can be
// unit-tested without spinning up a Platform.

let log = Logger.fromEnv()

// Returns (labelField, searchableFields) from a state schema.
// Source ladder:
//   1. @displayName spec present → "displayName" + spec.fields (raw underlying fields)
//   2. First non-id, non-`*Id`/`*Ids`, non-TAG, string-typed field in declaration order
//   3. "id" fallback with a logged warning (no searchable fields)
//
// `*Id` / `*Ids` fields (e.g. `productId`, `customerId`, `orderIds`) are entity
// references, not human-readable labels — skipping them lets a sibling like
// `name` win even when it appears later in declaration order.
let isIdLikeFieldName = (name: string): bool =>
  name == "id" || name->String.endsWith("Id") || name->String.endsWith("Ids")

// Resolve the field that holds the entity's lifecycle status, used by
// AutoUI to filter the per-row command menu against each command's
// `allowedStates`. Resolution order:
//   1. Field annotated `@status` (PPX-emitted; see StateAnnotations).
//   2. Field literally named `"status"` (convention; mirrors how
//      labelField falls back to a conventionally-named string field).
//   3. None — filter is inert for this read model.
let statusFieldFromStateSchema = (
  stateSchema: S.t<unknown>,
): option<string> => {
  let annotated = switch Reventless.StateAnnotations.getSpec(stateSchema) {
  | Some(spec) => spec.status
  | None => None
  }
  switch annotated {
  | Some(_) as some => some
  | None =>
    switch stateSchema {
    | Object({items}) =>
      items
      ->Array.find(item => item.location == "status")
      ->Option.map(item => item.location)
    | _ => None
    }
  }
}

let labelFieldsFromStateSchema = (
  ~entityName: string,
  stateSchema: S.t<unknown>,
): (string, array<string>) =>
  switch Reventless.DisplayName.getSpec(stateSchema) {
  | Some(spec) => ("displayName", spec.fields)
  | None =>
    let firstStringItem = switch stateSchema {
    | Object({items}) =>
      items->Array.find(item =>
        item.location != "TAG" &&
        !isIdLikeFieldName(item.location) &&
        switch item.schema {
        | String(_) => true
        | _ => false
        }
      )
    | _ => None
    }
    switch firstStringItem {
    | Some(item) => (item.location, [item.location])
    | None =>
      log.warn(
        ~comp="Plugin_Structure",
        `${entityName}: no @displayName annotation and no suitable string field — labelField falls back to "id"`,
      )
      ("id", [])
    }
  }

let make = (
  type api role,
  ~name: string,
  ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=[],
  ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>=[],
  ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=[],
  ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=[],
  ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>=[],
  ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>=[],
  ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>=[],
  ~extensions: array<module(ReventlessInfra.Extension.Blueprint)>=[],
  ~extensionPoints: array<module(ReventlessInfra.ExtensionPointMapping.Mapping)>=[],
): Reventless.Plugin.pluginStructure => {
  // Event schemas: filter out payload-less variants — DCB event-type lookups
  // can't WHERE-clause on bare-string events, so the plugin graph mustn't
  // claim cross-component edges that the runtime can't honour.
  let eventVariantNames = schema => Reventless.DcbTag.extractVariantNames(schema)
  // Command schemas: keep every constructor (including payload-less) so the
  // GraphQL mutation surface stays addressable.
  let commandVariantNames = schema => Reventless.DcbTag.extractAllVariantNames(schema)
  let qualify = (~prefix, names) => names->Array.map(n => prefix ++ "." ++ n)

  // Aggregate commands that initialize a new aggregate instance are Collection-level
  // (shown as table-top buttons); all others are Instance-level (shown per-row).
  let isCreateCommandName = name =>
    ["Add", "Create", "Register", "Open", "Initialize", "Submit", "Start", "Place"]->Array.some(p =>
      name->String.startsWith(p)
    )

  let commandLevelAndId = (~isAggregate, ~variantName, properties: dict<S.t<unknown>>) =>
    if isAggregate {
      if isCreateCommandName(variantName) {
        (Reventless.Plugin.Collection, None)
      } else {
        (Reventless.Plugin.Instance, None)
      }
    } else {
      let taggedFields =
        properties
        ->Dict.toArray
        ->Array.filter(((fieldName, fieldSchema)) =>
          fieldName != "TAG" &&
            (Reventless.DcbTag.isTagged(fieldSchema) ||
              Reventless.DcbTag.isTaggedArray(fieldSchema))
        )
      let taggedField =
        taggedFields
        ->Array.find(((_, fieldSchema)) => Reventless.DcbTag.isPartitionTag(fieldSchema))
        ->Option.orElse(taggedFields->Array.get(0))
      switch taggedField {
      | Some((fieldName, _)) =>
        if isCreateCommandName(variantName) {
          // Creation command: Collection-level, but UUID is injected into the tagged ID field.
          (Reventless.Plugin.Collection, Some(fieldName))
        } else {
          (Reventless.Plugin.Instance, Some(fieldName))
        }
      | None => (Reventless.Plugin.Collection, None)
      }
    }

  let toCommandDef = (
    ~isAggregate,
    ~mutationFieldFor: string => string,
    ~parentSchema: S.t<unknown>,
    v: S.t<unknown>,
  ): option<Reventless.Plugin.commandDef> =>
    switch v {
    | Object({properties}) =>
      properties
      ->Dict.get("TAG")
      ->Option.flatMap(tagSchema =>
        switch tagSchema {
        | String({const: ?Some(variantName)}) => {
            let (level, aggregateIdField) = commandLevelAndId(~isAggregate, ~variantName, properties)
            let references =
              properties
              ->Dict.toArray
              ->Array.filterMap(((fieldName, fieldSchema)) =>
                Reventless.Reference.getTarget(fieldSchema)->Option.map(target => (
                  {
                    Reventless.Plugin.fieldName,
                    entity: target.entity,
                    plugin: target.plugin,
                  }: Reventless.Plugin.fieldReference
                ))
              )
            // Per-variant `allowedStates` lives on the *parent* command schema
            // (the PPX attaches a single dict<variantName, [|states|]> via
            // markAllowedStates). Look it up by variant name; back-compat
            // None when the variant lacks an @allowedStates annotation.
            let allowedStates =
              ApiAllowedStatesHelpers.getAllowedStates(parentSchema, ~variantName)
            Some({
              Reventless.Plugin.name: variantName,
              schema: (v->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
              level,
              aggregateIdField,
              mutationField: mutationFieldFor(variantName),
              references,
              allowedStates,
            })
          }
        | _ => None
        }
      )
    | _ => None
    }

  let extractCommandDefs = (
    ~isAggregate,
    ~mutationFieldFor: string => string,
    commandSchema: S.t<unknown>,
  ): array<Reventless.Plugin.commandDef> =>
    switch commandSchema {
    | Union({anyOf}) =>
      anyOf->Array.filterMap(v =>
        toCommandDef(~isAggregate, ~mutationFieldFor, ~parentSchema=commandSchema, v)
      )
    | _ =>
      // Single-variant command types compile to a bare Object schema, not a Union.
      toCommandDef(~isAggregate, ~mutationFieldFor, ~parentSchema=commandSchema, commandSchema)
      ->Option.mapOr([], def => [def])
    }

  // ── Per-component event type extraction ────────────────────────────────────

  let scsProduced =
    stateChangeSlices->Array.map((module(SCS: ReventlessInfra.StateChangeSlice.T)) => (
      SCS.Spec.name,
      qualify(~prefix=name, eventVariantNames(SCS.Spec.eventSchema)),
    ))
  let scsConsumed =
    stateChangeSlices->Array.map((module(SCS: ReventlessInfra.StateChangeSlice.T)) => (
      SCS.Spec.name,
      qualify(~prefix=name, eventVariantNames(SCS.Spec.consumedEventSchema)),
    ))

  let aggProduced =
    aggregates->Array.map((module(A: ReventlessInfra.Aggregate.T with type api = api)) => (
      A.Spec.name,
      qualify(~prefix=name, eventVariantNames(A.Spec.eventSchema)),
    ))

  let svsConsumed =
    stateViewSlices->Array.map((module(SVS: ReventlessInfra.StateViewSlice.T)) => (
      SVS.Spec.name,
      qualify(~prefix=name, eventVariantNames(SVS.Spec.consumedEventSchema)),
    ))

  let rmSourceNames =
    readModels->Array.map((
      module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
    ) => (R.Spec.name, R.sourceNames))

  let allWritableProduced: array<(string, array<string>)> = Array.concat(scsProduced, aggProduced)

  // ── Cross-reference helpers ────────────────────────────────────────────────

  let intersects = (a: array<string>, b: array<string>) =>
    a->Array.some(x => b->Array.includes(x))

  let linkedSvsFor = (producedTypes: array<string>): array<string> =>
    svsConsumed->Array.filterMap(((viewName, consumed)) =>
      if intersects(producedTypes, consumed) {
        Some(viewName)
      } else {
        None
      }
    )

  let linkedReadModelsFor = (aggregateName: string): array<string> =>
    rmSourceNames->Array.filterMap(((rmName, sources)) =>
      if sources->Array.includes(aggregateName) {
        Some(rmName)
      } else {
        None
      }
    )

  let linkedWriteSideFor = (consumedTypes: array<string>): array<string> =>
    allWritableProduced->Array.filterMap(((writableName, produced)) =>
      if intersects(consumedTypes, produced) {
        Some(writableName)
      } else {
        None
      }
    )

  // For a StateChangeSlice's consumedEventTypes, find the single best-matching StateViewSlice.
  // Primary sort: overlap score desc. Tie-break: total consumed events desc (larger view wins).
  // Remaining ties resolve to None.
  let consistencyReadFor = (scsConsumedTypes: array<string>): option<string> => {
    let scored =
      svsConsumed
      ->Array.map(((viewName, consumed)) => {
        let overlap = consumed->Array.filter(e => scsConsumedTypes->Array.includes(e))->Array.length
        let total = consumed->Array.length
        (viewName, overlap, total)
      })
      ->Array.filter(((_, overlap, _)) => overlap > 0)
      ->Array.toSorted(((_, a, aTotal), (_, b, bTotal)) => {
        let cmp = Int.compare(b, a)
        if cmp != Ordering.equal { cmp } else { Int.compare(bTotal, aTotal) }
      })
    switch scored->Array.length {
    | 0 => None
    | 1 =>
      let (viewName, _, _) = scored->Array.getUnsafe(0)
      Some(viewName)
    | _ =>
      let (viewName, top, topTotal) = scored->Array.getUnsafe(0)
      let (_, second, secondTotal) = scored->Array.getUnsafe(1)
      if top > second {
        Some(viewName)
      } else if top == second && topTotal > secondTotal {
        Some(viewName)
      } else {
        None
      }
    }
  }

  // ── Build queryable defs ───────────────────────────────────────────────────
  //
  // Internal ReadModels and StateViewSlices (marked `@@reventless.visibility(Internal)`)
  // are CARRIED in pluginStructure, tagged via `queryableDef.visibility` (`None` = Public,
  // `Some("Internal")` = Internal). Developer tools — the `reventless-gwt` / VSCode domain
  // graph and dead-code analysis — read them so an Internal view still shows up there. The
  // deployed AutoUI's consumers (Platform_UIDefinitionsApi menu/pages, Platform_EventGraph
  // web nodes, Platform_CrossPluginEdges) re-filter on the tag so the live UI keeps hiding
  // them — see Visibility.res, which documents this contract.
  let visibilityTag = (v: Reventless.Visibility.t): option<string> =>
    switch v {
    | Public => None
    | Internal => Some("Internal")
    }

  let readModelDefs =
    readModels
    ->Array.map((
      module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
    ) => {
      let qf = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
      let stateSchema = R.Spec.stateSchema->S.castToUnknown
      let (labelField, searchableFields) = labelFieldsFromStateSchema(
        ~entityName=R.Spec.name,
        stateSchema,
      )
      ({
        Reventless.Plugin.name: R.Spec.name,
        queryField: qf.listFieldName,
        schema: stateSchema->SuryToJsonSchema.deriveObjectSchema->JSON.stringify,
        consumedEventTypes: [],
        linkedWriteSide: [],
        labelField,
        searchableFields,
        statusField: statusFieldFromStateSchema(stateSchema),
        visibility: visibilityTag(R.Spec.visibility),
      }: Reventless.Plugin.queryableDef)
    })

  let stateViewDefs =
    stateViewSlices->Array.mapWithIndex((module(SVS: ReventlessInfra.StateViewSlice.T), i) => {
      let qf = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=SVS.Spec.name)
      let (_, consumed) = svsConsumed->Array.getUnsafe(i)
      let stateSchema = SVS.Spec.stateSchema->S.castToUnknown
      let (labelField, searchableFields) = labelFieldsFromStateSchema(
        ~entityName=SVS.Spec.name,
        stateSchema,
      )
      ({
        Reventless.Plugin.name: SVS.Spec.name,
        queryField: qf.listFieldName,
        schema: stateSchema->SuryToJsonSchema.deriveObjectSchema->JSON.stringify,
        consumedEventTypes: consumed,
        linkedWriteSide: linkedWriteSideFor(consumed),
        labelField,
        searchableFields,
        statusField: statusFieldFromStateSchema(stateSchema),
        visibility: visibilityTag(SVS.Spec.visibility),
      }: Reventless.Plugin.queryableDef)
    })

  // ── Build writable defs ────────────────────────────────────────────────────

  let stateChangeDefs =
    stateChangeSlices->Array.mapWithIndex((module(SCS: ReventlessInfra.StateChangeSlice.T), i) => {
      let (_, produced) = scsProduced->Array.getUnsafe(i)
      let (_, consumed) = scsConsumed->Array.getUnsafe(i)
      ({
        Reventless.Plugin.name: SCS.Spec.name,
        commands: extractCommandDefs(
          ~isAggregate=false,
          ~mutationFieldFor=_variantName => Api_Naming.sliceMutationField(~plugin=name, ~slice=SCS.Spec.name),
          SCS.Spec.commandSchema->S.castToUnknown,
        ),
        producedEventTypes: produced,
        consumedEventTypes: consumed,
        linkedViews: linkedSvsFor(produced),
        consistencyRead: consistencyReadFor(consumed),
      }: Reventless.Plugin.writableDef)
    })

  let aggregateDefs =
    aggregates->Array.mapWithIndex((
      module(A: ReventlessInfra.Aggregate.T with type api = api),
      i,
    ) => {
      let (_, produced) = aggProduced->Array.getUnsafe(i)
      ({
        Reventless.Plugin.name: A.Spec.name,
        commands: extractCommandDefs(
          ~isAggregate=true,
          ~mutationFieldFor=variantName => Api_Naming.aggregateMutationField(~plugin=name, ~aggregate=A.Spec.name, ~command=variantName),
          A.Spec.commandSchema->S.castToUnknown,
        ),
        producedEventTypes: produced,
        consumedEventTypes: [],
        linkedViews: Array.concat(linkedSvsFor(produced), linkedReadModelsFor(A.Spec.name)),
        consistencyRead: None,
      }: Reventless.Plugin.writableDef)
    })

  // ── Automation slices ────────────────────────────────────────────────────────

  let automationSliceDefs =
    automationSlices->Array.map((module(AS: ReventlessInfra.AutomationSlice.T)) => {
      // Plan 04: gather variant names across every per-source mapping. A
      // multi-source slice contributes the union; a single-source slice
      // contributes that one source's variants.
      let allConsumedVariants =
        AS.Automation.mappings
        ->Array.flatMap((module(M: AS.Automation.Mapping)) =>
          eventVariantNames(M.sourceEventSchema->S.castToUnknown)
        )
        ->Belt.Set.String.fromArray
        ->Belt.Set.String.toArray
      ({
        Reventless.Plugin.name: AS.Spec.name,
        consumedEventTypes: qualify(~prefix=name, allConsumedVariants),
        producedCommandTypes: qualify(~prefix=name, commandVariantNames(AS.Spec.commandSchema)),
        targetName: AS.Spec.targetName,
      }: Reventless.Plugin.automationSliceDef)
    })

  // ── Outbound translation slices ───────────────────────────────────────────

  let outboundTranslationSliceDefs =
    outboundTranslationSlices->Array.map((module(OTS: ReventlessInfra.OutboundTranslationSlice.T)) => ({
      Reventless.Plugin.name: OTS.Spec.name,
      consumedEventTypes: qualify(~prefix=name, eventVariantNames(OTS.Spec.consumedEventSchema)),
      inboundCommandTypes: qualify(~prefix=name, commandVariantNames(OTS.Spec.inboundCommandSchema)),
      targetName: OTS.Spec.targetName,
    }: Reventless.Plugin.outboundTranslationSliceDef))

  // ── Inbound translation slices ────────────────────────────────────────────

  let inboundTranslationSliceDefs =
    inboundTranslationSlices->Array.map((module(ITS: ReventlessInfra.InboundTranslationSlice.T)) => ({
      Reventless.Plugin.name: ITS.Spec.name,
      commandTypes: qualify(~prefix=name, commandVariantNames(ITS.Spec.commandSchema)),
      targetName: ITS.Spec.targetName,
    }: Reventless.Plugin.inboundTranslationSliceDef))

  // ── Extensions ───────────────────────────────────────────────────────────

  let extensionDefs =
    extensions->Array.map((module(E: ReventlessInfra.Extension.Blueprint)) => {
      let delegateNames = E.mappings->Array.map((module(M: E.Mapping)) => M.delegateName)
      ({
        Reventless.Plugin.name: E.Spec.name,
        delegateNames,
        eventTypes: qualify(~prefix=E.Spec.name, eventVariantNames(E.Spec.eventSchema)),
        commandTypes: qualify(~prefix=E.Spec.name, commandVariantNames(E.Spec.commandSchema)),
      }: Reventless.Plugin.extensionDef)
    })

  // ── Extension points (producer side) ──────────────────────────────────────
  //
  // The mapping modules connect one Delegate (an aggregate / DCB event log) to
  // one extension point. Several mappings can target the SAME extension point
  // (Make2 / Make3 / MakeMulti), so group by the EP's dotted spec name and union
  // each delegate's name + its source event types. Source events are qualified
  // with the plugin name to match `producedEventTypes` on the write-sides, so the
  // event graph can draw producing-write-side → event → extension-point.

  let dedupe = (xs: array<string>) =>
    xs->Belt.Set.String.fromArray->Belt.Set.String.toArray

  let epByName: Dict.t<(array<string>, array<string>)> = Dict.make()
  extensionPoints->Array.forEach((module(M: ReventlessInfra.ExtensionPointMapping.Mapping)) => {
    let epName = M.ExtensionPoint.name
    let sourceEvents = qualify(~prefix=name, eventVariantNames(M.Delegate.eventSchema->S.castToUnknown))
    let (dels, evs) = epByName->Dict.get(epName)->Option.getOr(([], []))
    epByName->Dict.set(epName, (Array.concat(dels, [M.Delegate.name]), Array.concat(evs, sourceEvents)))
  })
  let extensionPointDefs =
    epByName
    ->Dict.toArray
    ->Array.map(((epName, (dels, evs))) => ({
      Reventless.Plugin.name: epName,
      delegateNames: dedupe(dels),
      sourceEventTypes: dedupe(evs),
    }: Reventless.Plugin.extensionPointDef))

  {
    readModels: readModelDefs,
    stateViewSlices: stateViewDefs,
    stateChangeSlices: stateChangeDefs,
    aggregates: aggregateDefs,
    automationSlices: automationSliceDefs,
    outboundTranslationSlices: outboundTranslationSliceDefs,
    inboundTranslationSlices: inboundTranslationSliceDefs,
    extensions: extensionDefs,
    extensionPoints: Some(extensionPointDefs),
  }
}
