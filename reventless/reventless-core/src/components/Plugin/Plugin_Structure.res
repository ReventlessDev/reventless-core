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
): Reventless.Plugin.pluginStructure => {
  let variantNames = schema => Reventless.DcbTag.extractVariantNames(schema)

  let commandLevelAndId = (~isAggregate, properties: dict<S.t<unknown>>) =>
    if isAggregate {
      (Reventless.Plugin.Instance, None)
    } else {
      let taggedField =
        properties
        ->Dict.toArray
        ->Array.find(((fieldName, fieldSchema)) =>
          fieldName != "TAG" &&
            (Reventless.DcbTag.isTagged(fieldSchema) ||
              Reventless.DcbTag.isTaggedArray(fieldSchema))
        )
      switch taggedField {
      | Some((fieldName, _)) => (Reventless.Plugin.Instance, Some(fieldName))
      | None => (Reventless.Plugin.Collection, None)
      }
    }

  let toCommandDef = (~isAggregate, v: S.t<unknown>): option<Reventless.Plugin.commandDef> =>
    switch v {
    | Object({properties}) =>
      properties
      ->Dict.get("TAG")
      ->Option.flatMap(tagSchema =>
        switch tagSchema {
        | String({const: ?Some(variantName)}) => {
            let (level, aggregateIdField) = commandLevelAndId(~isAggregate, properties)
            Some({
              Reventless.Plugin.name: variantName,
              schema: (v->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
              level,
              aggregateIdField,
            })
          }
        | _ => None
        }
      )
    | _ => None
    }

  let extractCommandDefs = (~isAggregate, commandSchema: S.t<unknown>): array<
    Reventless.Plugin.commandDef,
  > =>
    switch commandSchema {
    | Union({anyOf}) => anyOf->Array.filterMap(v => toCommandDef(~isAggregate, v))
    | _ =>
      // Single-variant command types compile to a bare Object schema, not a Union.
      toCommandDef(~isAggregate, commandSchema)->Option.mapOr([], def => [def])
    }

  // ── Per-component event type extraction ────────────────────────────────────

  let scsProduced =
    stateChangeSlices->Array.map((module(SCS: ReventlessInfra.StateChangeSlice.T)) => (
      SCS.Spec.name,
      variantNames(SCS.Spec.eventSchema),
    ))
  let scsConsumed =
    stateChangeSlices->Array.map((module(SCS: ReventlessInfra.StateChangeSlice.T)) => (
      SCS.Spec.name,
      variantNames(SCS.Spec.consumedEventSchema),
    ))

  let aggProduced =
    aggregates->Array.map((module(A: ReventlessInfra.Aggregate.T with type api = api)) => (
      A.Spec.name,
      variantNames(A.Spec.eventSchema),
    ))

  let svsConsumed =
    stateViewSlices->Array.map((module(SVS: ReventlessInfra.StateViewSlice.T)) => (
      SVS.Spec.name,
      variantNames(SVS.Spec.consumedEventSchema),
    ))

  let allWritableProduced: array<(string, array<string>)> = Array.concat(scsProduced, aggProduced)

  // ── Cross-reference helpers ────────────────────────────────────────────────

  let intersects = (a: array<string>, b: array<string>) =>
    a->Array.some(x => b->Array.includes(x))

  let linkedViewsFor = (producedTypes: array<string>): array<string> =>
    svsConsumed->Array.filterMap(((viewName, consumed)) =>
      if intersects(producedTypes, consumed) {
        Some(viewName)
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
  // Ties (equal overlap scores) resolve to None rather than guessing.
  let consistencyReadFor = (scsConsumedTypes: array<string>): option<string> => {
    let scored =
      svsConsumed
      ->Array.map(((viewName, consumed)) => {
        let overlap = consumed->Array.filter(e => scsConsumedTypes->Array.includes(e))
        (viewName, overlap->Array.length)
      })
      ->Array.filter(((_, score)) => score > 0)
      ->Array.toSorted(((_, a), (_, b)) => Int.compare(b, a))
    switch scored->Array.length {
    | 0 => None
    | 1 =>
      let (viewName, _) = scored->Array.getUnsafe(0)
      Some(viewName)
    | _ =>
      let (viewName, top) = scored->Array.getUnsafe(0)
      let (_, second) = scored->Array.getUnsafe(1)
      top > second ? Some(viewName) : None
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
        commands: extractCommandDefs(~isAggregate=false, SCS.Spec.commandSchema->S.castToUnknown),
        producedEventTypes: produced,
        consumedEventTypes: consumed,
        linkedViews: linkedViewsFor(produced),
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
        commands: extractCommandDefs(~isAggregate=true, A.Spec.commandSchema->S.castToUnknown),
        producedEventTypes: produced,
        consumedEventTypes: [],
        linkedViews: linkedViewsFor(produced),
        consistencyRead: None,
      }: Reventless.Plugin.writableDef)
    })

  {
    readModels: readModelDefs,
    stateViewSlices: stateViewDefs,
    stateChangeSlices: stateChangeDefs,
    aggregates: aggregateDefs,
  }
}
