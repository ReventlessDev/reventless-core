// Pure metadata extraction from spec modules.
// Extracts the pluginStructure (component graph metadata) that Auto UI, the
// event-graph view, and MCP tooling consume. Kept standalone so it can be
// unit-tested without spinning up a Platform.

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
): Reventless.Plugin.pluginStructure => {
  let variantNames = schema => Reventless.DcbTag.extractVariantNames(schema)
  let qualify = (~prefix, names) => names->Array.map(n => prefix ++ "." ++ n)

  // Aggregate commands that initialize a new aggregate instance are Collection-level
  // (shown as table-top buttons); all others are Instance-level (shown per-row).
  let isCreateCommandName = name =>
    ["Add", "Create", "Register", "Open", "Initialize", "Place", "Submit", "Start"]->Array.some(p =>
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
            Some({
              Reventless.Plugin.name: variantName,
              schema: (v->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
              level,
              aggregateIdField,
              mutationField: mutationFieldFor(variantName),
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
    | Union({anyOf}) => anyOf->Array.filterMap(v => toCommandDef(~isAggregate, ~mutationFieldFor, v))
    | _ =>
      // Single-variant command types compile to a bare Object schema, not a Union.
      toCommandDef(~isAggregate, ~mutationFieldFor, commandSchema)->Option.mapOr([], def => [def])
    }

  // ── Per-component event type extraction ────────────────────────────────────

  let scsProduced =
    stateChangeSlices->Array.map((module(SCS: ReventlessInfra.StateChangeSlice.T)) => (
      SCS.Spec.name,
      qualify(~prefix=name, variantNames(SCS.Spec.eventSchema)),
    ))
  let scsConsumed =
    stateChangeSlices->Array.map((module(SCS: ReventlessInfra.StateChangeSlice.T)) => (
      SCS.Spec.name,
      qualify(~prefix=name, variantNames(SCS.Spec.consumedEventSchema)),
    ))

  let aggProduced =
    aggregates->Array.map((module(A: ReventlessInfra.Aggregate.T with type api = api)) => (
      A.Spec.name,
      qualify(~prefix=name, variantNames(A.Spec.eventSchema)),
    ))

  let svsConsumed =
    stateViewSlices->Array.map((module(SVS: ReventlessInfra.StateViewSlice.T)) => (
      SVS.Spec.name,
      qualify(~prefix=name, variantNames(SVS.Spec.consumedEventSchema)),
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

  let readModelDefs =
    readModels->Array.map((
      module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
    ) => {
      let qf = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
      ({
        Reventless.Plugin.name: R.Spec.name,
        queryField: qf.listFieldName,
        schema: (R.Spec.stateSchema->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
        consumedEventTypes: [],
        linkedWriteSide: [],
      }: Reventless.Plugin.queryableDef)
    })

  let stateViewDefs =
    stateViewSlices->Array.mapWithIndex((module(SVS: ReventlessInfra.StateViewSlice.T), i) => {
      let qf = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=SVS.Spec.name)
      let (_, consumed) = svsConsumed->Array.getUnsafe(i)
      ({
        Reventless.Plugin.name: SVS.Spec.name,
        queryField: qf.listFieldName,
        schema: (SVS.Spec.stateSchema->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
        consumedEventTypes: consumed,
        linkedWriteSide: linkedWriteSideFor(consumed),
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
    automationSlices->Array.map((module(AS: ReventlessInfra.AutomationSlice.T)) => ({
      Reventless.Plugin.name: AS.Spec.name,
      consumedEventTypes: qualify(~prefix=name, variantNames(AS.Spec.consumedEventSchema)),
      producedCommandTypes: qualify(~prefix=name, variantNames(AS.Spec.commandSchema)),
      targetName: AS.Spec.targetName,
    }: Reventless.Plugin.automationSliceDef))

  // ── Outbound translation slices ───────────────────────────────────────────

  let outboundTranslationSliceDefs =
    outboundTranslationSlices->Array.map((module(OTS: ReventlessInfra.OutboundTranslationSlice.T)) => ({
      Reventless.Plugin.name: OTS.Spec.name,
      consumedEventTypes: qualify(~prefix=name, variantNames(OTS.Spec.consumedEventSchema)),
      inboundCommandTypes: qualify(~prefix=name, variantNames(OTS.Spec.inboundCommandSchema)),
      targetName: OTS.Spec.targetName,
    }: Reventless.Plugin.outboundTranslationSliceDef))

  // ── Inbound translation slices ────────────────────────────────────────────

  let inboundTranslationSliceDefs =
    inboundTranslationSlices->Array.map((module(ITS: ReventlessInfra.InboundTranslationSlice.T)) => ({
      Reventless.Plugin.name: ITS.Spec.name,
      commandTypes: qualify(~prefix=name, variantNames(ITS.Spec.commandSchema)),
      targetName: ITS.Spec.targetName,
    }: Reventless.Plugin.inboundTranslationSliceDef))

  // ── Extensions ───────────────────────────────────────────────────────────

  let extensionDefs =
    extensions->Array.map((module(E: ReventlessInfra.Extension.Blueprint)) => {
      let delegateNames = E.mappings->Array.map((module(M: E.Mapping)) => M.delegateName)
      ({
        Reventless.Plugin.name: E.Spec.name,
        delegateNames,
        eventTypes: qualify(~prefix=E.Spec.name, variantNames(E.Spec.eventSchema)),
        commandTypes: qualify(~prefix=E.Spec.name, variantNames(E.Spec.commandSchema)),
      }: Reventless.Plugin.extensionDef)
    })

  {
    readModels: readModelDefs,
    stateViewSlices: stateViewDefs,
    stateChangeSlices: stateChangeDefs,
    aggregates: aggregateDefs,
    automationSlices: automationSliceDefs,
    outboundTranslationSlices: outboundTranslationSliceDefs,
    inboundTranslationSlices: inboundTranslationSliceDefs,
    extensions: extensionDefs,
  }
}
