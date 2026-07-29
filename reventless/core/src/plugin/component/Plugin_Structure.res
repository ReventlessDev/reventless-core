// Pure metadata extraction from spec modules.
// Extracts the pluginStructure (component graph metadata) that Auto UI, the
// event-graph view, and MCP tooling consume. Kept standalone so it can be
// unit-tested without spinning up a Platform.

let log = Logger.fromEnv()

// What a field *is* is `SchemaType`'s question, and it is the IR every other
// schema consumer here reads. The two predicates below are the only two answers
// this module needs; both are stated over the IR rather than over sury shapes,
// so a field that is a date, a reference or an enum is one for the label picker
// too.

// Whether a field can name a record. `Nullable` unwraps — an optional name is
// still the entity's name, absent on some rows, which is a rendering question
// rather than a declaration one. A `Semantic` wrapper is refused: it is the
// schema saying the string means something other than prose (a storage ref, a
// URL), and a bucket key is not a name. `DateTime`, `EntityId`, `Enum` and every
// composite shape fall out of the catch-all without being named — which is the
// point of reading an IR rather than restating it: the next shape it grows is
// excluded before it exists.
let rec isLabelShape = (t: SchemaType.schemaType): bool =>
  switch t {
  | ScalarString => true
  | Nullable(inner) => isLabelShape(inner)
  | _ => false
  }

// Whether a field can hold a lifecycle status: a closed set of values, or an
// optional one. A free-text `status: string` is not a lifecycle — filtering a
// command menu against `allowedStates` needs states to compare with.
let rec isStatusShape = (t: SchemaType.schemaType): bool =>
  switch t {
  | Enum(_, _) => true
  | Nullable(inner) => isStatusShape(inner)
  | _ => false
  }

// Field names that say "this one is the record's name" in the only way
// available short of the `@displayName` annotation. Matched case-insensitively
// and *exactly*: `customerName` holds a customer's name, not this record's.
let conventionalLabelNames = ["name", "title", "label", "displayname"]

let shapeOfItem = (~entityName: string, item: S.item): SchemaType.schemaType =>
  SchemaType.fromSury(~parentName=entityName, ~fieldName=item.location, item.schema)

// Resolve the field that holds the entity's lifecycle status, used to filter a
// per-row command menu against each command's `allowedStates`. Resolution order:
//   1. Field annotated `@status` (PPX-emitted; see StateAnnotations).
//   2. Field literally named `"status"` whose IR shape is an enum (convention;
//      mirrors how labelField falls back to a conventionally-named field).
//   3. None — filter is inert for this read model.
let statusFieldFromStateSchema = (
  ~entityName: string,
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
      ->Array.find(item =>
        item.location == "status" && isStatusShape(shapeOfItem(~entityName, item))
      )
      ->Option.map(item => item.location)
    | _ => None
    }
  }
}

// Returns (labelField, searchableFields) from a state schema.
// Source ladder:
//   1. @displayName spec present → "displayName" + spec.fields (raw underlying fields)
//   2. A candidate field named `name`/`title`/`label`/`displayName`
//   3. The first candidate in declaration order
//   4. "id" fallback with a logged warning (no searchable fields)
//
// A *candidate* is a non-TAG field, not literally named `id`, whose IR shape can
// name a record (`isLabelShape`). Rungs 2 and 3 are both guesses, and the order
// between them matters: declaration order alone means a state gains a new name
// whenever a field is inserted above the old one — a `placedAt` added so date
// views have something to key off renames every order to a timestamp.
//
// `id` is excluded here rather than by the IR because `SchemaType` treats a name
// that short as an ordinary string; every other reference — `*Id`/`*Ids`, a DCB
// tag, a `Reference.to` — is already an `EntityId` there.
let labelFieldsFromStateSchema = (
  ~entityName: string,
  stateSchema: S.t<unknown>,
): (string, array<string>) =>
  switch Reventless.DisplayName.getSpec(stateSchema) {
  | Some(spec) => ("displayName", spec.fields)
  | None =>
    let candidates = switch stateSchema {
    | Object({items}) =>
      items->Array.filter(item =>
        item.location != "TAG" &&
        item.location != "id" &&
        isLabelShape(shapeOfItem(~entityName, item))
      )
    | _ => []
    }
    let conventional = candidates->Array.find(item => {
      let lower = item.location->String.toLowerCase
      conventionalLabelNames->Array.some(n => n == lower)
    })
    let picked = switch conventional {
    | Some(_) as some => some
    | None => candidates->Array.get(0)
    }
    switch picked {
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
  // Component name → chapter (intra-plugin grouping band), captured at build time
  // from each component's source folder by the plugin generator. A component whose
  // spec name has no entry (or lives directly under a kind-folder) carries no chapter
  // and renders flat. Keyed by `Spec.name`, which equals the source filename stem for
  // every graph-node kind, so the generator can build this map from the discovered
  // file paths. See `Codegen.chapterOf` and docs/plans/deployed-chapter-grouping.md.
  ~componentChapters: dict<string>=Dict.make(),
): Reventless.Plugin.pluginStructure => {
  let chapterOf = (compName: string): option<string> => componentChapters->Dict.get(compName)
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
  ): option<Reventless.Plugin.commandDef> => {
    // Build a commandDef for one variant. `properties` is the variant's field dict —
    // empty for a payload-less variant (e.g. `| Archive`), which compiles to a bare
    // `S.literal("Archive")` string rather than an `{TAG, ...}` object.
    let mkDef = (~variantName, ~properties) => {
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
      let allowedStates = ApiAllowedStatesHelpers.getAllowedStates(parentSchema, ~variantName)
      // Declared `@targetState` (the command's *to* status), read the same way
      // as allowedStates. None ⇒ AutoUI's board resolver falls back to its
      // name-stem heuristic.
      let targetState = ApiTargetStateHelpers.getTargetState(parentSchema, ~variantName)
      // API-exposed iff the whole command isn't @noApi and this variant
      // isn't in its @noApi-variants set — mirrors the API-generation filter
      // (Plugin_Helpers / PluginBaseFragment). Drives the event-graph API badge.
      let apiExposed =
        !ApiNoApiHelpers.isNoApi(parentSchema) &&
        switch ApiNoApiHelpers.getExcludedVariants(parentSchema) {
        | Some(excluded) => !(excluded->Set.has(variantName))
        | None => true
        }
      ({
        Reventless.Plugin.name: variantName,
        schema: (v->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
        level,
        aggregateIdField,
        // A non-exposed (`@noApi`) variant has no callable mutation field. For a
        // single-exposed-command slice, `mutationFieldFor` resolves *every*
        // variant — including the `@noApi` one — to the slice's one mutation
        // field, so emitting it here would hand the non-exposed variant a
        // sibling's callable-looking field (e.g. `ReopenOrder` →
        // `Ordering_CancelOrder`). Emit an empty sentinel instead; the variant
        // stays listed with `apiExposed: false` for the event-graph badge, but
        // no consumer can mistake it for a callable field. Exposed variants are
        // byte-identical.
        mutationField: apiExposed ? mutationFieldFor(variantName) : "",
        references,
        allowedStates,
        targetState,
        apiExposed: Some(apiExposed),
      }: Reventless.Plugin.commandDef)
    }
    switch v {
    | Object({properties}) =>
      properties
      ->Dict.get("TAG")
      ->Option.flatMap(tagSchema =>
        switch tagSchema {
        | String({const: ?Some(variantName)}) => Some(mkDef(~variantName, ~properties))
        | _ => None
        }
      )
    // Payload-less command variants (`| Archive`) compile to a bare string literal,
    // not an `{TAG, ...}` object. They still get a generated mutation (API generation
    // walks the schema via extractAllVariantNames), so surface them here too —
    // otherwise the event graph hides a command the API actually exposes.
    | String({const: ?Some(variantName)}) => Some(mkDef(~variantName, ~properties=Dict.make()))
    | _ => None
    }
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

  // ── Per-variant event field extraction (Phase 6.3) ─────────────────────────
  // Mirrors toCommandDef/extractCommandDefs for emitted events: name (TAG const),
  // payload JSON Schema, and cross-entity references.

  let toEventDef = (v: S.t<unknown>): option<Reventless.Plugin.eventDef> => {
    let mkDef = (~variantName, ~properties) => {
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
      ({
        Reventless.Plugin.name: variantName,
        schema: (v->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
        references,
      }: Reventless.Plugin.eventDef)
    }
    switch v {
    | Object({properties}) =>
      properties
      ->Dict.get("TAG")
      ->Option.flatMap(tagSchema =>
        switch tagSchema {
        | String({const: ?Some(variantName)}) => Some(mkDef(~variantName, ~properties))
        | _ => None
        }
      )
    // Payload-less event variants (`| Archived`) compile to a bare string literal.
    // DCB-projection lookups can't WHERE-clause on them, so they stay out of
    // producedEventTypes/consumedEventTypes; but the full `events` list carries them
    // so the event graph can still draw the emitted (orphan) event node.
    | String({const: ?Some(variantName)}) => Some(mkDef(~variantName, ~properties=Dict.make()))
    | _ => None
    }
  }

  let extractEventDefs = (eventSchema: S.t<unknown>): array<Reventless.Plugin.eventDef> =>
    switch eventSchema {
    | Union({anyOf}) => anyOf->Array.filterMap(toEventDef)
    | _ => toEventDef(eventSchema)->Option.mapOr([], def => [def])
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

  // ── Declared object stores ─────────────────────────────────────────────────
  //
  // A field typed as a storage ref states that the deployment needs the named
  // store to exist. Read that declaration the same way `Reference.getTarget` is
  // read for entity references, so the requirement travels with the plugin's
  // structure instead of living only inside a field's schema, where the deploy
  // would have to re-walk every component to find it.
  //
  // An unqualified store belongs to the declaring plugin, so every collected
  // entry is qualified to `{plugin}.{store}` — one shape, and the string is
  // directly the store's identity. Many fields legitimately name one store, so
  // the result is deduplicated.

  let storesFromProperties = (properties: dict<S.t<unknown>>): array<string> =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((_, fieldSchema)) =>
      Reventless.StorageRef.getStore(fieldSchema)->Option.map(target =>
        target.plugin->Option.getOr(name) ++ "." ++ target.store
      )
    )

  // Commands and events are unions of per-variant objects; state is a single
  // object. Both reduce to "the properties of every object in this schema".
  let storesFromSchema = (schema: S.t<unknown>): array<string> => {
    let fromVariant = v =>
      switch v {
      | S.Object({properties}) => storesFromProperties(properties)
      | _ => []
      }
    switch schema {
    | Union({anyOf}) => anyOf->Array.flatMap(fromVariant)
    | other => fromVariant(other)
    }
  }

  let requiredStores =
    [
      aggregates->Array.flatMap((module(A: ReventlessInfra.Aggregate.T with type api = api)) =>
        Array.concat(
          storesFromSchema(A.Spec.commandSchema->S.castToUnknown),
          storesFromSchema(A.Spec.eventSchema->S.castToUnknown),
        )
      ),
      stateChangeSlices->Array.flatMap((module(SCS: ReventlessInfra.StateChangeSlice.T)) =>
        Array.concat(
          storesFromSchema(SCS.Spec.commandSchema->S.castToUnknown),
          storesFromSchema(SCS.Spec.eventSchema->S.castToUnknown),
        )
      ),
      stateViewSlices->Array.flatMap((module(SVS: ReventlessInfra.StateViewSlice.T)) =>
        storesFromSchema(SVS.Spec.stateSchema->S.castToUnknown)
      ),
      readModels->Array.flatMap((
        module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
      ) => storesFromSchema(R.Spec.stateSchema->S.castToUnknown)),
      automationSlices->Array.flatMap((module(AS: ReventlessInfra.AutomationSlice.T)) =>
        storesFromSchema(AS.Spec.commandSchema->S.castToUnknown)
      ),
      inboundTranslationSlices->Array.flatMap((
        module(ITS: ReventlessInfra.InboundTranslationSlice.T),
      ) => storesFromSchema(ITS.Spec.commandSchema->S.castToUnknown)),
    ]
    ->Array.flat
    ->Belt.Set.String.fromArray
    ->Belt.Set.String.toArray

  // ── Build queryable defs ───────────────────────────────────────────────────
  //
  // Internal ReadModels and StateViewSlices (marked `@@reventless.visibility(Internal)`)
  // are CARRIED in pluginStructure, tagged via `queryableDef.visibility` (`None` = Public,
  // `Some("Internal")` = Internal). Developer tools — the `reventless-gwt` / VSCode domain
  // graph and dead-code analysis — read them so an Internal view still shows up there. The
  // deployed AutoUI's consumers (Platform_ComponentDefinitionsApi menu/pages) re-filter on
  // the tag so the live UI keeps hiding them — see Visibility.res, which documents this contract.
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
      // The events this read model projects from, qualified to the plugin's event ids so
      // they match the producers' nodes in the graph. Was empty — which dropped projection
      // edges for any event reaching the read model via a DCB-log-sourced mapping (a classic
      // aggregate→view link is also drawn from the producer's linkedViews, deduped downstream).
      let consumed = qualify(~prefix=name, R.consumedEventNames)
      ({
        Reventless.Plugin.name: R.Spec.name,
        queryField: qf.listFieldName,
        schema: stateSchema->SuryToJsonSchema.deriveObjectSchema->JSON.stringify,
        consumedEventTypes: consumed,
        linkedWriteSide: linkedWriteSideFor(consumed),
        labelField,
        searchableFields,
        statusField: statusFieldFromStateSchema(~entityName=R.Spec.name, stateSchema),
        visibility: visibilityTag(R.Spec.visibility),
        chapter: chapterOf(R.Spec.name),
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
        statusField: statusFieldFromStateSchema(~entityName=SVS.Spec.name, stateSchema),
        visibility: visibilityTag(SVS.Spec.visibility),
        chapter: chapterOf(SVS.Spec.name),
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
          ~mutationFieldFor=variantName =>
            Api_Naming.sliceMutationFieldFor(
              ~plugin=name,
              ~slice=SCS.Spec.name,
              ~commandSchema=SCS.Spec.commandSchema->S.castToUnknown,
              ~variant=variantName,
            ),
          SCS.Spec.commandSchema->S.castToUnknown,
        ),
        producedEventTypes: produced,
        consumedEventTypes: consumed,
        linkedViews: linkedSvsFor(produced),
        consistencyRead: consistencyReadFor(consumed),
        events: extractEventDefs(SCS.Spec.eventSchema->S.castToUnknown),
        chapter: chapterOf(SCS.Spec.name),
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
        events: extractEventDefs(A.Spec.eventSchema->S.castToUnknown),
        chapter: chapterOf(A.Spec.name),
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
        chapter: chapterOf(AS.Spec.name),
      }: Reventless.Plugin.automationSliceDef)
    })

  // ── Outbound translation slices ───────────────────────────────────────────

  let outboundTranslationSliceDefs =
    outboundTranslationSlices->Array.map((module(OTS: ReventlessInfra.OutboundTranslationSlice.T)) => ({
      Reventless.Plugin.name: OTS.Spec.name,
      consumedEventTypes: qualify(~prefix=name, eventVariantNames(OTS.Spec.consumedEventSchema)),
      inboundCommandTypes: qualify(~prefix=name, commandVariantNames(OTS.Spec.inboundCommandSchema)),
      targetName: OTS.Spec.targetName,
      externalSystem: OTS.Spec.externalSystem,
      chapter: chapterOf(OTS.Spec.name),
    }: Reventless.Plugin.outboundTranslationSliceDef))

  // ── Inbound translation slices ────────────────────────────────────────────

  let inboundTranslationSliceDefs =
    inboundTranslationSlices->Array.map((module(ITS: ReventlessInfra.InboundTranslationSlice.T)) => ({
      Reventless.Plugin.name: ITS.Spec.name,
      commandTypes: qualify(~prefix=name, commandVariantNames(ITS.Spec.commandSchema)),
      targetName: ITS.Spec.targetName,
      externalSystem: ITS.Spec.externalSystem,
      chapter: chapterOf(ITS.Spec.name),
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

  let epByName: Dict.t<(array<string>, array<string>, array<string>)> = Dict.make()
  extensionPoints->Array.forEach((module(M: ReventlessInfra.ExtensionPointMapping.Mapping)) => {
    let epName = M.ExtensionPoint.name
    let sourceEvents = qualify(~prefix=name, eventVariantNames(M.Delegate.eventSchema->S.castToUnknown))
    // The EP's inbound command protocol (variants of its `command` type). Empty
    // for a `command = unit` EP — an events-out-only boundary that routes nothing.
    let commands = qualify(~prefix=epName, commandVariantNames(M.ExtensionPoint.commandSchema))
    let (dels, evs, cmds) = epByName->Dict.get(epName)->Option.getOr(([], [], []))
    epByName->Dict.set(
      epName,
      (Array.concat(dels, [M.Delegate.name]), Array.concat(evs, sourceEvents), Array.concat(cmds, commands)),
    )
  })
  let extensionPointDefs =
    epByName
    ->Dict.toArray
    ->Array.map(((epName, (dels, evs, cmds))) => ({
      Reventless.Plugin.name: epName,
      delegateNames: dedupe(dels),
      sourceEventTypes: dedupe(evs),
      commandTypes: Some(dedupe(cmds)),
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
    requiredStores: Some(requiredStores),
  }
}
