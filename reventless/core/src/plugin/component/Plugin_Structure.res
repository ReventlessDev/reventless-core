// Pure metadata extraction from spec modules: the pluginStructure that Auto UI,
// the event graph and MCP tooling consume. Standalone, so it unit-tests without
// a Platform.

let log = Logger.fromEnv()

// Whether a field can name a record, stated over `SchemaType`'s IR so every
// shape it grows is excluded before it exists. `Nullable` unwraps; a `Semantic`
// wrapper is refused — a bucket key or URL is not prose.
let rec isLabelShape = (t: SchemaType.schemaType): bool =>
  switch t {
  | ScalarString => true
  | Nullable(inner) => isLabelShape(inner)
  // Written out rather than left to the catch-all: no single string names a row
  // whose rendering depends on its arm.
  | TaggedUnion(_, _) => false
  | _ => false
  }

// Whether a field can hold a lifecycle: a closed set of values, or an optional
// one. A free-text `lifecycle: string` is not a lifecycle — filtering a command
// menu against `allowedStates` needs states to compare with.
let rec isLifecycleShape = (t: SchemaType.schemaType): bool =>
  switch t {
  | Enum(_, _) => true
  | Nullable(inner) => isLifecycleShape(inner)
  // A union is a closed set of *shapes*, not of values, and `allowedStates`
  // compares values. The same answer the ppx gives `@lifecycle` on a union
  // field, which is a compile error — this is the convention rung agreeing.
  | TaggedUnion(_, _) => false
  | _ => false
  }

// Field names that say "this one is the record's name" in the only way
// available short of the `@displayName` annotation. Matched case-insensitively
// and *exactly*: `customerName` holds a customer's name, not this record's.
let conventionalLabelNames = ["name", "title", "label", "displayname"]

let shapeOfField = (~entityName: string, ~name: string, schema: S.t<unknown>): SchemaType.schemaType =>
  SchemaType.fromSury(~parentName=entityName, ~fieldName=name, schema)

// The field holding the entity's lifecycle, for filtering a per-row command menu:
// `@lifecycle`, else an enum field literally named `lifecycle`, else None. Not
// keyed on `status` — a promiscuous name that would guess, and guess often.
let lifecycleFieldFromStateSchema = (
  ~entityName: string,
  stateSchema: S.t<unknown>,
): option<string> => {
  let annotated = switch Reventless.StateAnnotations.getSpec(stateSchema) {
  | Some(spec) => spec.lifecycle
  | None => None
  }
  switch annotated {
  | Some(_) as some => some
  | None =>
    switch stateSchema {
    | Object({properties}) =>
      properties
      ->Dict.get("lifecycle")
      ->Option.flatMap(schema =>
        isLifecycleShape(shapeOfField(~entityName, ~name="lifecycle", schema))
          ? Some("lifecycle")
          : None
      )
    | _ => None
    }
  }
}

// The field whose truth withdraws a row from ordinary reads. Annotation-only —
// no convention rung, since guessing wrong here makes rows vanish.
let retiredFromStateSchema = (
  stateSchema: S.t<unknown>,
): option<Reventless.StateAnnotations.retiredSpec> =>
  switch Reventless.StateAnnotations.getSpec(stateSchema) {
  | Some(spec) => spec.retired
  | None => None
  }

let retiredFieldFromStateSchema = (stateSchema: S.t<unknown>): option<string> =>
  retiredFromStateSchema(stateSchema)->Option.map(r => r.field)

// The states a row is retired *in*, for the enum form; `None` is the boolean
// form. Published beside `retiredField` so a client holds the whole predicate.
let retiredValuesFromStateSchema = (stateSchema: S.t<unknown>): option<array<string>> =>
  retiredFromStateSchema(stateSchema)->Option.flatMap(r => r.values)

// Whether a reference to a retired row still resolves its name. Read off the
// retirement itself, so a record cannot declare the reach of one it lacks.
let namedWhenRetiredFromStateSchema = (stateSchema: S.t<unknown>): bool =>
  retiredFromStateSchema(stateSchema)->Option.mapOr(false, r => r.namedWhenRetired)

// What one record's `@retired` could be told about its own field. Three outcomes,
// because "nothing to check" and "could not check" are different facts.
type retiredCheck =
  | NotDeclared
  // Why the names could not be compared — reported, never skipped in silence.
  | Unchecked(string)
  | Checked(array<string>)

// The check the PPX cannot make (it sees the payload only as a name; the schema
// says whether that name is a case of the field's enum). A name the enum does not
// declare is a failure — the predicate then matches no row and every row stays
// visible. A `value` on a field that is not the lifecycle is only a warning: a
// modelling judgement rather than a wrong name.
let checkRetiredValue = (~entityName: string, stateSchema: S.t<unknown>): retiredCheck =>
  switch retiredFromStateSchema(stateSchema) {
  // The boolean form names no state, so there is nothing to compare. Not a skip.
  | None | Some({values: None}) => NotDeclared
  | Some({field, values: Some(values)}) =>
    let named = values->Array.join(", ")
    let lifecycle = lifecycleFieldFromStateSchema(~entityName, stateSchema)
    if lifecycle != Some(field) {
      log.warn(
        ~comp="Plugin_Structure",
        `${entityName}: @retired(${named}) is on "${field}", which is not this record's lifecycle field${lifecycle
          ->Option.map(f => ` (that is "${f}")`)
          ->Option.getOr(
            " (it declares none)",
          )}. A retirement state no command's declared edge can name loses the command filtering the state form exists for.`,
      )
    }
    let declared = switch stateSchema {
    | Object({properties}) =>
      properties
      ->Dict.get(field)
      ->Option.map(schema =>
        switch shapeOfField(~entityName, ~name=field, schema) {
        | Enum(_, values) => values
        | Nullable(Enum(_, values)) => values
        | _ => []
        }
      )
      ->Option.getOr([])
    | _ => []
    }
    if Array.length(declared) == 0 {
      Unchecked(
        `${entityName}: @retired(${named}) is on "${field}", whose shape carries no cases to check the names against.`,
      )
    } else {
      // Reported per state rather than as a set: one wrong entry among three still
      // narrows something, so the symptom is a subset of rows leaking rather than
      // all of them — which is harder to spot than the single-value case was.
      Checked(
        values
        ->Array.filter(v => !(declared->Array.includes(v)))
        ->Array.map(
          v =>
            `${entityName}: @retired(${v}) names a state "${field}" does not declare — known values: ${declared->Array.join(
                ", ",
              )}.`,
        ),
      )
    }
  }

// Raised together, after every view is walked, so an author sees every bad name
// at once. Retroactive: a deployed plugin with a stale value goes red on its next
// build, which is the point.
let reportRetiredStates = (
  ~pluginName: string,
  ~failures: array<string>,
  ~unchecked: array<string>,
): unit => {
  if Array.length(unchecked) > 0 {
    log.warn(
      ~comp="Plugin_Structure",
      `${pluginName}: ${unchecked
        ->Array.length
        ->Int.toString} @retired declaration(s) could not be checked.\n` ++
      unchecked->Array.join("\n"),
    )
  }
  if Array.length(failures) > 0 {
    JsError.throwWithMessage(
      `${pluginName}: @retired names states that do not exist.\n` ++ failures->Array.join("\n"),
    )
  }
}

// The states a record's lifecycle field can hold — the field a command's
// declared edge is written in terms of. `None`: no lifecycle; `Some([])`: one
// with no cases.
let lifecycleStatesFromStateSchema = (
  ~entityName: string,
  stateSchema: S.t<unknown>,
): option<array<string>> =>
  lifecycleFieldFromStateSchema(~entityName, stateSchema)->Option.flatMap(field =>
    switch stateSchema {
    | Object({properties}) =>
      properties
      ->Dict.get(field)
      ->Option.map(schema =>
        switch shapeOfField(~entityName, ~name=field, schema) {
        | Enum(_, values) => values
        | Nullable(Enum(_, values)) => values
        | _ => []
        }
      )
    | _ => None
    }
  )

// ── The port's translation table ─────────────────────────────────────────────
//
// The PPX reads the table off the mapping's own arms, so these checks are what
// stands behind a HAND-WRITTEN one — the escape hatch for a mapping whose arms
// the PPX refused to guess at. Names raise (both sides are `@schema` types, so a
// non-constructor is a mistake); the probe below is best-effort and reports what
// it could not follow.

let translationTableFailures = (
  ~label: string,
  ~declared: array<ReventlessInfra.ExtensionPointMapping.publishedEvent>,
  ~publishedNames: array<string>,
  ~sourceNames: array<string>,
): array<string> => {
  let failures = []
  let push = msg => failures->Array.push(msg)->ignore
  declared->Array.forEach(({name, fromEventTypes}) => {
    if !(publishedNames->Array.includes(name)) {
      push(
        `${label}: publishedEvents names "${name}", which the extension point does not ` ++
        `publish — it declares ${publishedNames->Array.join(", ")}.`,
      )
    }
    fromEventTypes->Array.forEach(src => {
      if !(sourceNames->Array.includes(src)) {
        push(
          `${label}: publishedEvents says "${name}" comes from "${src}", which is not an ` ++
          `event of ${sourceNames->Array.join(", ")}.`,
        )
      }
    })
  })
  failures
}

// What the probe saw against what was declared. Produced-but-undeclared raises
// (the probe watched it happen); declared-but-unproduced only warns (the arm may
// branch on a payload the probe cannot synthesise). Unfollowed sources are not
// judged at all — "did not look" must not read as "no edge".
let translationTableDrift = (
  ~label: string,
  ~declared: array<ReventlessInfra.ExtensionPointMapping.publishedEvent>,
  ~observed: array<(string, string)>,
  ~followed: array<string>,
): (array<string>, array<string>) => {
  let declaredEdges = declared->Array.reduce([], (acc, {name, fromEventTypes}) =>
    Array.concat(acc, fromEventTypes->Array.map(src => (src, name)))
  )
  let has = (edges, (src, pub)) => edges->Array.some(((s, p)) => s == src && p == pub)

  let failures =
    observed
    ->Array.filter(edge => !(declaredEdges->has(edge)))
    ->Array.map(((src, pub)) =>
      `${label}: "${src}" publishes "${pub}", which publishedEvents does not declare.`
    )

  let warnings =
    declaredEdges
    ->Array.filter(((src, pub)) => followed->Array.includes(src) && !(observed->has((src, pub))))
    ->Array.map(((src, pub)) =>
      `${label}: publishedEvents declares "${src}" → "${pub}", which the mapping did not ` ++
      `produce for a synthesised "${src}".`
    )

  (failures, warnings)
}

// The subscriber's mirror, resolved against the union of both command sets:
// publishing back to the port is as real an edge as publishing inward.
let handledTableFailures = (
  ~label: string,
  ~declared: array<ReventlessInfra.ExtensionMapping.handledEvent>,
  ~eventNames: array<string>,
  ~commandNames: array<string>,
): array<string> => {
  let failures = []
  declared->Array.forEach(({name, toCommandTypes}) => {
    if !(eventNames->Array.includes(name)) {
      failures
      ->Array.push(
        `${label}: handledEvents names "${name}", which the extension point does not ` ++
        `publish — it declares ${eventNames->Array.join(", ")}.`,
      )
      ->ignore
    }
    toCommandTypes->Array.forEach(cmd =>
      if !(commandNames->Array.includes(cmd)) {
        failures
        ->Array.push(
          `${label}: handledEvents says "${name}" routes to "${cmd}", which is neither a ` ++
          `delegate command nor an extension point command — ${commandNames->Array.join(", ")}.`,
        )
        ->ignore
      }
    )
  })
  failures
}

// The command direction's two tables. Both key on an EP command and value a list
// of delegate names, so one check serves them: `keyed` names the table, `keyKind`
// and `valueKind` name what each side must be.
let commandTableFailures = (
  ~label: string,
  ~keyed: string,
  ~valueKind: string,
  ~rows: array<(string, array<string>)>,
  ~keyNames: array<string>,
  ~valueNames: array<string>,
): array<string> => {
  let failures = []
  let push = msg => failures->Array.push(msg)->ignore
  rows->Array.forEach(((name, values)) => {
    if !(keyNames->Array.includes(name)) {
      push(
        `${label}: ${keyed} names "${name}", which is not a command of the extension ` ++
        `point — it declares ${keyNames->Array.join(", ")}.`,
      )
    }
    values->Array.forEach(v =>
      if !(valueNames->Array.includes(v)) {
        push(
          `${label}: ${keyed} says "${name}" ${valueKind} "${v}", which the delegate does ` ++
          `not declare — ${valueNames->Array.join(", ")}.`,
        )
      }
    )
  })
  failures
}

// The probe's stand-ins. A mapping can only reach the query engine behind a
// promise, and such an arm is reported as unfollowed anyway.
let probeId = "probe"
let probeMeta: Reventless.Message.meta = {
  service: "Plugin_Structure",
  time: "",
  msgId: "",
  correlationId: "",
}
let probeQueryEngine: Reventless.QueryEngine.operations = {
  scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => [],
}

// One place raises, at the end of the build: a stale table drifts in more than
// one spot, and stopping at the first would hide the rest.
let reportTranslationTables = (
  ~pluginName: string,
  ~failures: array<string>,
  ~warnings: array<string>,
): unit => {
  if Array.length(warnings) > 0 {
    log.warn(~comp="Plugin_Structure", `${pluginName}:\n` ++ warnings->Array.join("\n"))
  }
  if Array.length(failures) > 0 {
    JsError.throwWithMessage(
      `${pluginName}: the declared translation table does not match the mapping.\n` ++
      failures->Array.join("\n"),
    )
  }
}

// A command's declared edge names states belonging to another component's enum,
// and nothing forces a spec to pick the one its linked view declares. Both sides
// are in hand here. A state the linked views do not declare raises (this runs at assembly,
// never in a Lambda, so that is a failed deploy); no resolvable view only warns.
// Checked against the UNION of the linked views: a slice feeding two is not
// claiming which one.
//
// The compiler has already resolved the switch's constructors, so what survives
// to here is a component naming the wrong lifecycle enum rather than misspelling
// a state — the half of the check `lifecycleState` cannot make, since nothing
// forces a spec to pick its linked view's enum.
let checkDeclaredTransitions = (
  ~pluginName: string,
  ~writables: array<Reventless.Plugin.writableDef>,
  ~lifecycleStatesByView: dict<array<string>>,
): unit => {
  let unvalidated = ref(0)
  let failures = []

  writables->Array.forEach(w =>
    w.commands->Array.forEach(cmd => {
      let declared = Array.concat(
        cmd.allowedStates->Option.getOr([]),
        switch cmd.targetState {
        | Some(t) => [t]
        | None => []
        },
      )
      if Array.length(declared) > 0 {
        let known =
          w.linkedViews->Array.reduce([], (acc, view) =>
            switch lifecycleStatesByView->Dict.get(view) {
            | Some(states) => Array.concat(acc, states)
            | None => acc
            }
          )
        if Array.length(known) == 0 {
          unvalidated := unvalidated.contents + 1
        } else {
          declared
          ->Array.filter(state => !(known->Array.includes(state)))
          ->Array.forEach(state =>
            failures
            ->Array.push(
              `${w.name}.${cmd.name} declares state "${state}", which none of its ` ++
              `linked views declare — ${w.linkedViews->Array.join(
                  ", ",
                )} know ${known->Array.join(", ")}.`,
            )
            ->ignore
          )
        }
      }
    })
  )

  // Reported rather than silent: a plugin nothing could be checked against looks
  // exactly like a plugin that passed, and that population is the one most
  // likely to be carrying a stale name.
  if unvalidated.contents > 0 {
    log.warn(
      ~comp="Plugin_Structure",
      `${pluginName}: ${unvalidated.contents->Int.toString} command(s) declare a transition ` ++
      `but no linked view declares a lifecycle to check it against.`,
    )
  }

  if Array.length(failures) > 0 {
    JsError.throwWithMessage(
      `${pluginName}: a declared transition names states that do not exist.\n` ++
      failures->Array.join("\n"),
    )
  }
}

// Whether the declared transitions AGREE across an entity — a graph of valid names
// can still leave a state nothing reaches. Warnings only: a smell is not a mistake,
// and one that stops a deploy gets silenced rather than fixed. Pure, so the rule
// tests without a log; `checkLifecycleTopology` reports.
let lifecycleTopologyFindings = (
  ~writables: array<Reventless.Plugin.writableDef>,
  ~lifecycleStatesByView: dict<array<string>>,
): array<(string, string)> => {
  let findings = []
  lifecycleStatesByView
  ->Dict.toArray
  ->Array.forEach(((view, states)) => {
    // Arrival only, so a creating command (a target and no from-set) counts
    // towards reachability like any other edge.
    let reachable = writables->Array.reduce([], (acc, w) =>
      w.linkedViews->Array.includes(view)
        ? Array.concat(acc, w.commands->Array.filterMap(cmd => cmd.targetState))
        : acc
    )
    if Array.length(reachable) > 0 {
      // Rows start in the first declared state, so nothing pointing at it is fine.
      let initial = states->Array.get(0)

      states->Array.forEach(state => {
        if !(reachable->Array.includes(state)) && Some(state) != initial {
          findings
          ->Array.push((
            view,
            `no command declares a transition INTO "${state}" — it is unreachable ` ++
            `unless something outside this plugin's declarations puts a row there.`,
          ))
          ->ignore
        }
        // NOT checked: a state with no way out. Terminal states are ordinary,
        // and the only fix a lint could suggest — `@retired` — withdraws the
        // rows from reads rather than marking an ending.
      })
    }
  })
  findings
}

let checkLifecycleTopology = (
  ~pluginName: string,
  ~writables: array<Reventless.Plugin.writableDef>,
  ~lifecycleStatesByView: dict<array<string>>,
): unit =>
  lifecycleTopologyFindings(~writables, ~lifecycleStatesByView)->Array.forEach(((view, message)) =>
    log.warn(~comp="Plugin_Structure", `${pluginName}/${view}: ${message}`)
  )

// NOT here: an event-consumption completeness check. `consumedEventTypes` drops
// payload-less variants, which is exactly what a lifecycle-moving event usually
// is — so the events such a rule is about are the ones this metadata omits.

// Which rung produced the label, published as `labelFieldSource`: a consumer with
// a name rule of its own has to rank a declaration (rung 1) against a guess.
type labelFieldSource =
  | Annotation
  | Convention
  | Position
  | Fallback

let labelFieldSourceToString = (s: labelFieldSource): string =>
  switch s {
  | Annotation => "annotation"
  | Convention => "convention"
  | Position => "position"
  | Fallback => "fallback"
  }

type labelResolution = {
  field: string,
  searchableFields: array<string>,
  source: labelFieldSource,
}

// The field a state is named by: `@displayName`, else a candidate named
// name/title/label/displayName, else the first candidate, else `id` with a
// warning. A candidate is a non-TAG field, not named `id`, passing `isLabelShape`.
let labelFieldsFromStateSchema = (
  ~entityName: string,
  stateSchema: S.t<unknown>,
): labelResolution =>
  switch Reventless.DisplayName.getSpec(stateSchema) {
  | Some(spec) => {field: "displayName", searchableFields: spec.fields, source: Annotation}
  | None =>
    let candidates = switch stateSchema {
    | Object({properties}) =>
      properties
      ->Dict.toArray
      ->Array.filter(((name, schema)) =>
        name != "TAG" && name != "id" && isLabelShape(shapeOfField(~entityName, ~name, schema))
      )
    | _ => []
    }
    let conventional = candidates->Array.find(((name, _)) => {
      let lower = name->String.toLowerCase
      conventionalLabelNames->Array.some(n => n == lower)
    })
    let picked = switch conventional {
    | Some((name, _)) => Some((name, Convention))
    | None => candidates->Array.get(0)->Option.map(((name, _)) => (name, Position))
    }
    switch picked {
    | Some((name, source)) => {
        field: name,
        searchableFields: [name],
        source,
      }
    | None =>
      log.warn(
        ~comp="Plugin_Structure",
        `${entityName}: no @displayName annotation and no suitable string field — labelField falls back to "id"`,
      )
      {field: "id", searchableFields: [], source: Fallback}
    }
  }

// ── Per-variant event / error field extraction ───────────────────────────────
// Mirrors the command walk for emitted events. Module-level so Platform_Admin,
// whose components never pass through `make`, derives its defs the same way.

// A variant's cross-entity references, shared by the command and event walks.
// `getFieldTarget`, not `getTarget`: an `array<string>` field declares it on the
// element schema.
let extractReferences = (properties: dict<S.t<unknown>>): array<
  Reventless.Plugin.fieldReference,
> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((fieldName, fieldSchema)) =>
    Reventless.Reference.getFieldTarget(fieldSchema)->Option.map(target => (
      {
        Reventless.Plugin.fieldName,
        entity: target.entity,
        plugin: target.plugin,
      }: Reventless.Plugin.fieldReference
    ))
  )

let toEventDef = (v: S.t<unknown>): option<Reventless.Plugin.eventDef> => {
  let mkDef = (~variantName, ~properties) => {
    let references = extractReferences(properties)
    ({
      Reventless.Plugin.name: variantName,
      // Derived for the same reason as `commandDef.schema`: an event's field
      // markers are the write side's half of the same vocabulary.
      schema: v->SuryToJsonSchema.deriveObjectSchema->JSON.stringify,
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
  // Payload-less variants compile to a bare string literal. Kept here (though not
  // in produced/consumedEventTypes) so the graph can draw the orphan node.
  | String({const: ?Some(variantName)}) => Some(mkDef(~variantName, ~properties=Dict.make()))
  | _ => None
  }
}

let extractEventDefs = (eventSchema: S.t<unknown>): array<Reventless.Plugin.eventDef> =>
  switch eventSchema {
  | AnyOf({anyOf}) => anyOf->Array.filterMap(toEventDef)
  | _ => toEventDef(eventSchema)->Option.mapOr([], def => [def])
  }

// Errors walk identically to events; only the def type differs, so a consumer
// can tell a refusal from a fact. Shared rather than copied, so they cannot drift.
let extractErrorDefs = (errorSchema: S.t<unknown>): array<Reventless.Plugin.errorDef> =>
  extractEventDefs(errorSchema)->Array.map(({name, schema, references}) => (
    {name, schema, references}: Reventless.Plugin.errorDef
  ))

// Module-level like the event walk: the synthetic Platform_Admin structure has no
// `module(Aggregate.T)` to hand `make`, and a second copy of this walk is what let
// its metadata drift from the SDL.

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

// The server's rule as keys a client checks against `identity.groups ++
// config.accessTiers`; an any-of, since `isAllowed` is `some`. The rules asking
// for nothing checkable — and `DenyAll` — publish no keys rather than an
// unsatisfiable one.
let accessKeysFor = (rule: Reventless.Authorization.permission): option<array<string>> =>
  switch rule {
  | AllowGroups(groups) if groups->Array.length > 0 => Some(groups)
  | AllowGroups(_) | AllowAuthenticated | AllowAnonymous | DenyAll => None
  }

// Each mutation argument's GraphQL type onto its property, so a consumer declares
// the variable the server expects. Mutates the freshly derived schema in place.
let annotateArgTypes = (schema: JSON.t, argTypes: dict<string>): JSON.t => {
  schema
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("properties"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.forEach(props =>
    props
    ->Dict.toArray
    ->Array.forEach(((key, prop)) =>
      switch (argTypes->Dict.get(key), prop->JSON.Decode.object) {
      | (Some(gqlType), Some(p)) =>
        p->Dict.set("x-reventless-graphql-type", JSON.Encode.string(gqlType))
      | _ => ()
      }
    )
  )
  schema
}

let toCommandDef = (
  ~isAggregate,
  ~mutationFieldFor: string => string,
  ~parentSchema: S.t<unknown>,
  // The PPX-generated `command => permission`. Per VARIANT, not per component:
  // one aggregate carries commands with very different audiences, and a
  // component-level shortcut would gate `AddProduct` and `PlaceOrder` alike.
  ~commandAuthorization: unknown => Reventless.Authorization.permission,
  // The spec's `command => Transition.t<_>`, evaluated per variant the same way
  // `commandAuthorization` is, and the only declaration of an edge there is —
  // the PPX injects `Unrestricted` for a spec that writes no switch.
  //
  // Read at `t<string>` because this is the erasure boundary: the spec declares
  // its edges over the linked view's own lifecycle enum, whose arms are
  // payload-less and therefore ARE their own names at run time. The one cast
  // that says so is the same `->Obj.magic` every spec member arrives through
  // (see the call sites below), so `Transition` itself asserts nothing about
  // representation and stays parameterised all the way down.
  ~commandTransition: unknown => Reventless.Transition.t<string>,
  v: S.t<unknown>,
): option<Reventless.Plugin.commandDef> => {
  // Build a commandDef for one variant. `properties` is the variant's field dict —
  // empty for a payload-less variant (e.g. `| Archive`), which compiles to a bare
  // `S.literal("Archive")` string rather than an `{TAG, ...}` object.
  let mkDef = (~variantName, ~properties) => {
    let (level, aggregateIdField) = commandLevelAndId(~isAggregate, ~variantName, properties)
    let references = extractReferences(properties)
    // Evaluated against a synthetic value per constructor, the same shape the
    // resolver builds at call time: a payload-bearing variant compiles to
    // `{TAG, ...}`, a payload-less one to a bare string.
    let syntheticCommand: unknown =
      Reventless.DcbTag.isVariantPayloadBearing(parentSchema, variantName)
        ? {"TAG": variantName}->Obj.magic
        : variantName->Obj.magic
    // The spec's own switch, which is exhaustive — so it also speaks for a
    // constructor the host did not declare but spliced from a trait.
    //
    // An edge is ONE declaration, so the two fields are read off it together.
    // `targetState: None` ⇒ AutoUI's board resolver falls back to its name-stem
    // heuristic.
    let declared = commandTransition(syntheticCommand)
    let allowedStates = Reventless.Transition.allowedStates(declared)
    let targetState = Reventless.Transition.targetState(declared)
    // API-exposed iff the whole command isn't @noApi and this variant
    // isn't in its @noApi-variants set — mirrors the API-generation filter
    // (Plugin_Helpers / PluginBaseFragment). Drives the event-graph API badge.
    let apiExposed =
      !ApiNoApiHelpers.isNoApi(parentSchema) &&
      switch ApiNoApiHelpers.getExcludedVariants(parentSchema) {
      | Some(excluded) => !(excluded->Set.has(variantName))
      | None => true
      }
    let requiredAccess = accessKeysFor(commandAuthorization(syntheticCommand))
    // See the note on the record's `mutationField` for why a non-exposed
    // variant gets the empty sentinel. It has no callable field, and the
    // argument type names are composed *from* that field name, so there is
    // nothing to publish for it either.
    let mutationField = apiExposed ? mutationFieldFor(variantName) : ""
    let jsonSchema = v->SuryToJsonSchema.deriveObjectSchema
    let annotatedSchema = if apiExposed {
      GraphQL_FragmentGenerator.mutationArgTypes(~fieldName=mutationField, v)->Option.mapOr(
        jsonSchema,
        annotateArgTypes(jsonSchema, _),
      )
    } else {
      jsonSchema
    }
    ({
      Reventless.Plugin.name: variantName,
      // The derived schema, not sury's raw one, which drops every `x-reventless-*`
      // marker the PPX put on the fields. Also carries `x-reventless-graphql-type`.
      schema: annotatedSchema->JSON.stringify,
      level,
      aggregateIdField,
      // Empty for a `@noApi` variant: `mutationFieldFor` would resolve it to a
      // sibling's field, which reads as callable. Exposed variants are unchanged.
      mutationField,
      references,
      allowedStates,
      targetState,
      apiExposed: Some(apiExposed),
      requiredAccess,
      // Resolved from this constructor's own properties, not the union's: two
      // commands in one slice can disagree about whether they record an owner,
      // and the write path stamps per constructor for the same reason.
      ownerField: Reventless.Owner.fieldNamesOfProperties(properties)->Array.get(0),
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
  ~commandAuthorization: unknown => Reventless.Authorization.permission,
  ~commandTransition: unknown => Reventless.Transition.t<string>,
  commandSchema: S.t<unknown>,
): array<Reventless.Plugin.commandDef> =>
  switch commandSchema {
  | AnyOf({anyOf}) =>
    anyOf->Array.filterMap(v =>
      toCommandDef(
        ~isAggregate,
        ~mutationFieldFor,
        ~parentSchema=commandSchema,
        ~commandAuthorization,
        ~commandTransition,
        v,
      )
    )
  | _ =>
    // Single-variant command types compile to a bare Object schema, not a Union.
    toCommandDef(
      ~isAggregate,
      ~mutationFieldFor,
      ~parentSchema=commandSchema,
      ~commandAuthorization,
      ~commandTransition,
      commandSchema,
    )->Option.mapOr([], def => [def])
  }

// Omitted for the default `Public` so a published def stays compact: absent and
// "public" are the same answer, and writing one would make every ordinary view
// carry a word that says nothing.
let visibilityTag = (v: Reventless.Visibility.t): option<string> =>
  switch v {
  | Public => None
  | Internal => Some("Internal")
  }

/**
 A read model's `queryableDef` assembled from its spec, for the platform's own
 components: `make` takes `module(ReadModel.T)` values, and at structure-assembly
 time the platform has no built module to hand itself. Every extractor here is the
 one `make` calls, so the two cannot drift — a hand-written record did, four times.
 */
let queryableDefFromSpec = (
  ~plugin: string,
  ~name: string,
  ~stateSchema: S.t<unknown>,
  ~authorization: Reventless.Authorization.permission,
  ~visibility: Reventless.Visibility.t=Public,
  ~consumedEventTypes: array<string>=[],
  ~linkedWriteSide: array<string>=[],
  ~chapter: option<string>=?,
): Reventless.Plugin.queryableDef => {
  let qf = Api_Naming.queryFieldNamesForReadModel(~plugin, ~name)
  let label = labelFieldsFromStateSchema(~entityName=name, stateSchema)
  // The same call the capability deriver makes, so the published key and the key
  // the generated filter/order-by is built from cannot disagree.
  let keyField = GraphQL_FragmentGenerator.resolveKeyField(~entityName=name, stateSchema)
  {
    Reventless.Plugin.name: name,
    queryField: qf.listFieldName,
    schema: stateSchema->SuryToJsonSchema.deriveObjectSchema->JSON.stringify,
    consumedEventTypes,
    linkedWriteSide,
    labelField: label.field,
    searchableFields: label.searchableFields,
    labelFieldSource: Some(labelFieldSourceToString(label.source)),
    lifecycleField: lifecycleFieldFromStateSchema(~entityName=name, stateSchema),
    ownerField: Reventless.Owner.fieldNames(stateSchema)->Array.get(0),
    retiredField: retiredFieldFromStateSchema(stateSchema),
    retiredValues: retiredValuesFromStateSchema(stateSchema),
    namedWhenRetired: Some(namedWhenRetiredFromStateSchema(stateSchema)),
    visibility: visibilityTag(visibility),
    chapter,
    singleQueryField: Some(qf.singleFieldName),
    idField: keyField->Option.map(((f, _)) => f),
    idFieldSource: keyField->Option.map(((_, rung)) => rung),
    requiredAccess: accessKeysFor(authorization),
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
  // Component name → chapter, captured from each component's source folder by the
  // plugin generator. Keyed by `Spec.name`; no entry renders flat.
  ~componentChapters: dict<string>=Dict.make(),
): Reventless.Plugin.pluginStructure => {
  let chapterOf = (compName: string): option<string> => componentChapters->Dict.get(compName)
  // Payload-less variants dropped: the graph must not claim an edge a DCB lookup
  // cannot WHERE-clause on.
  let eventVariantNames = schema => Reventless.DcbTag.extractVariantNames(schema)
  // Every constructor, so the mutation surface stays addressable.
  let commandVariantNames = schema => Reventless.DcbTag.extractAllVariantNames(schema)
  let qualify = (~prefix, names) => names->Array.map(n => prefix ++ "." ++ n)
  let dedupe = (xs: array<string>) => xs->Belt.Set.String.fromArray->Belt.Set.String.toArray

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
  // A storage-ref field states the deployment needs that store. Collected here so
  // the requirement travels with the structure, qualified to `{plugin}.{store}`
  // and deduplicated, each entry keeping its `(component, field)` site.
  // `requiredStores` is derived from the same walk, so the two cannot disagree.

  let storesFromProperties = (~component, properties: dict<S.t<unknown>>): array<
    Reventless.Plugin.requiredStoreDeclaration,
  > =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((field, fieldSchema)) =>
      // `getFieldStore`, not `getStore`: a `@storageRef("s") urls: array<string>`
      // field carries the marker on its *element*, so reading the field schema
      // directly answered `None` and the store went unprovisioned — the same
      // silence as never having written the annotation.
      Reventless.StorageRef.getFieldStore(fieldSchema)->Option.map(((target, _arity)) => {
        Reventless.Plugin.store: target.plugin->Option.getOr(name) ++ "." ++ target.store,
        component,
        field,
        // The source text, not a guess: `target.plugin` is `None` exactly when the
        // field left the store unqualified, and only here does that survive.
        annotation: Some(
          switch target.plugin {
          | None => target.store
          | Some(plugin) => plugin ++ "." ++ target.store
          },
        ),
      })
    )

  // Commands and events are unions of per-variant objects; state is a single
  // object. Both reduce to "the properties of every object in this schema".
  let storesFromSchema = (~component, schema: S.t<unknown>): array<
    Reventless.Plugin.requiredStoreDeclaration,
  > => {
    let fromVariant = v =>
      switch v {
      | S.Object({properties}) => storesFromProperties(~component, properties)
      | _ => []
      }
    switch schema {
    | AnyOf({anyOf}) => anyOf->Array.flatMap(fromVariant)
    | other => fromVariant(other)
    }
  }

  let compareDeclarations = (
    a: Reventless.Plugin.requiredStoreDeclaration,
    b: Reventless.Plugin.requiredStoreDeclaration,
  ) => {
    let byStore = String.compare(a.store, b.store)
    if byStore != Ordering.equal {
      byStore
    } else {
      let byComponent = String.compare(a.component, b.component)
      if byComponent != Ordering.equal {
        byComponent
      } else {
        String.compare(a.field, b.field)
      }
    }
  }

  // ── One command name, one handler ──────────────────────────────────────────
  //
  // A DCB plugin routes a command by its bare type name: the runtime builds
  // `handlersByType[typeName]` across every StateChangeSlice in the plugin and
  // dispatches on the incoming command's TAG alone. Two slices declaring one name
  // therefore have one handler between them — the second registration overwrites
  // the first, and the plugin deploys.
  //
  // Refused here rather than logged there. The runtime notices only when it goes
  // to stamp owner fields, by which point the deploy has succeeded and the losing
  // slice is silently unreachable; a name is a compile-time fact and this is the
  // last place that can see all of them at once.
  //
  // Aggregates are exempt and are not checked: their commands are addressed per
  // component channel, so two aggregates sharing a command name is ordinary.
  let dcbCommandOwners: dict<array<string>> = Dict.make()
  stateChangeSlices->Array.forEach((module(SCS: ReventlessInfra.StateChangeSlice.T)) =>
    Reventless.DcbTag.extractAllVariantNames(
      SCS.Spec.commandSchema->S.castToUnknown,
    )->Array.forEach(cmd => {
      let owners = dcbCommandOwners->Dict.get(cmd)->Option.getOr([])
      dcbCommandOwners->Dict.set(cmd, Array.concat(owners, [SCS.Spec.name]))
    })
  )
  let clashes =
    dcbCommandOwners
    ->Dict.toArray
    ->Array.filter(((_, owners)) => owners->Array.length > 1)
    ->Array.toSorted((((a, _)), ((b, _))) => String.compare(a, b))
  if clashes->Array.length > 0 {
    JsError.throwWithMessage(
      `${name}: ` ++
      clashes
      ->Array.map((((cmd, owners))) =>
        `${owners->Array.join(" and ")} both declare the command "${cmd}"`
      )
      ->Array.join("; ") ++
      `.\n  A DCB plugin routes a command by its bare name, so one of these would never run. ` ++
      `Qualify them — the shipped traits' emitters prefix every name with the host they are ` ++
      `grafted onto, for exactly this reason.`,
    )
  }

  // One list feeds both the store collection and the lint below, so a field is
  // read exactly once by either.
  let storeDeclarationSites: array<(string, S.t<unknown>)> =
    [
      aggregates->Array.flatMap((module(A: ReventlessInfra.Aggregate.T with type api = api)) => [
        (A.Spec.name, A.Spec.commandSchema->S.castToUnknown),
        (A.Spec.name, A.Spec.eventSchema->S.castToUnknown),
      ]),
      stateChangeSlices->Array.flatMap((module(SCS: ReventlessInfra.StateChangeSlice.T)) => [
        (SCS.Spec.name, SCS.Spec.commandSchema->S.castToUnknown),
        (SCS.Spec.name, SCS.Spec.eventSchema->S.castToUnknown),
      ]),
      stateViewSlices->Array.map((module(SVS: ReventlessInfra.StateViewSlice.T)) => (
        SVS.Spec.name,
        SVS.Spec.stateSchema->S.castToUnknown,
      )),
      readModels->Array.map((
        module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
      ) => (R.Spec.name, R.Spec.stateSchema->S.castToUnknown)),
      automationSlices->Array.map((module(AS: ReventlessInfra.AutomationSlice.T)) => (
        AS.Spec.name,
        AS.Spec.commandSchema->S.castToUnknown,
      )),
      inboundTranslationSlices->Array.map((
        module(ITS: ReventlessInfra.InboundTranslationSlice.T),
      ) => (ITS.Spec.name, ITS.Spec.commandSchema->S.castToUnknown)),
    ]->Array.flat

  // Sorted for a deterministic manifest; identical triples collapse.
  let requiredStoreDeclarations =
    storeDeclarationSites
    ->Array.flatMap(((component, schema)) => storesFromSchema(~component, schema))
    ->Array.toSorted(compareDeclarations)
    ->Array.reduce([], (acc, d) =>
      switch acc->Array.last {
      | Some(prev) if prev == d => acc
      | _ => acc->Array.concat([d])
      }
    )

  let requiredStores =
    requiredStoreDeclarations
    ->Array.map(d => d.store)
    ->Belt.Set.String.fromArray
    ->Belt.Set.String.toArray

  // Two stores one edit apart provision twice. Hard failure, unlike the lint
  // below: by deploy time both buckets exist.
  switch Capability_Inference.collisions(requiredStoreDeclarations) {
  | [] => ()
  | found =>
    JsError.throwWithMessage(
      `${name}: two declared object stores look like one store misspelled.\n` ++
      found->Array.map(Capability_Inference.collisionMessage)->Array.join("\n"),
    )
  }

  // Capabilities a slice declares its `translate` reaches for. Sorted and
  // deduplicated for the same reason the store declarations are: the manifest is
  // committed, so it must not churn on a re-build. Only outbound translation
  // slices are handed `Capabilities.t`, so only they can declare.
  let requiredCapabilities =
    outboundTranslationSlices
    ->Array.flatMap((module(OTS: ReventlessInfra.OutboundTranslationSlice.T)) =>
      OTS.Spec.capabilityNeeds->Array.map(need => (
        {
          Reventless.Plugin.capability: Reventless.CapabilityNeed.toString(need),
          component: OTS.Spec.name,
        }: Reventless.Plugin.requiredCapabilityDeclaration
      ))
    )
    ->Array.toSorted((a, b) =>
      a.capability == b.capability
        ? String.compare(a.component, b.component)
        : String.compare(a.capability, b.capability)
    )
    ->Array.reduce([], (acc, d) =>
      switch acc->Array.last {
      | Some(prev) if prev == d => acc
      | _ => acc->Array.concat([d])
      }
    )

  // The traits grafted into this plugin, one entry per declaring component. The
  // component name is added here rather than declared: a trait cannot know which
  // component a host grafted it onto, and a host writing it down would be the one
  // hand-typed string this whole mechanism exists to avoid. Sorted and
  // deduplicated for the same reason the two declarations above are.
  let traitDeclarations = {
    let entry = (~component, decl: Reventless.Trait.t) => (
      {
        Reventless.Plugin.trait: decl.trait,
        version: decl.version,
        posture: Reventless.Trait.postureToString(decl.posture),
        component,
      }: Reventless.Plugin.traitDeclaration
    )
    [
      aggregates->Array.flatMap((module(A: ReventlessInfra.Aggregate.T with type api = api)) =>
        A.Spec.traits->Array.map(entry(~component=A.Spec.name, ...))
      ),
      stateChangeSlices->Array.flatMap((module(SCS: ReventlessInfra.StateChangeSlice.T)) =>
        SCS.Spec.traits->Array.map(entry(~component=SCS.Spec.name, ...))
      ),
      outboundTranslationSlices->Array.flatMap((
        module(OTS: ReventlessInfra.OutboundTranslationSlice.T),
      ) => OTS.Spec.traits->Array.map(entry(~component=OTS.Spec.name, ...))),
    ]
    ->Array.flat
    ->Array.toSorted((a, b) =>
      a.trait == b.trait ? String.compare(a.component, b.component) : String.compare(a.trait, b.trait)
    )
    ->Array.reduce([], (acc, d) =>
      switch acc->Array.last {
      | Some(prev) if prev == d => acc
      | _ => acc->Array.concat([d])
      }
    )
  }

  // Heuristic-only matches — a field *named* like a stored-object ref with no
  // `@storageRef` — warn and provision nothing. Declaration outranks inference;
  // the warning names the annotation that would settle it.
  storeDeclarationSites->Array.forEach(((component, schema)) =>
    Capability_Inference.scanSchema(~component, schema)->Array.forEach(w =>
      log.warn(~comp="Plugin_Structure", Capability_Inference.message(w))
    )
  )

  // ── Build queryable defs ───────────────────────────────────────────────────
  //
  // Internal views are carried here, tagged via `queryableDef.visibility`, so
  // developer tools see them; AutoUI's consumers re-filter on the tag.
  // View name -> the states its lifecycle field can hold, collected as the view
  // defs are built so the transition check below has both sides in one place.
  let lifecycleStatesByView: dict<array<string>> = Dict.make()
  let recordLifecycle = (~entityName, stateSchema) => {
    switch lifecycleStatesFromStateSchema(~entityName, stateSchema) {
    | Some(states) if Array.length(states) > 0 =>
      lifecycleStatesByView->Dict.set(entityName, states)
    | _ => ()
    }
  }

  // Collected as the view defs are built and reported once, so a plugin with
  // three bad names fails naming three rather than one at a time.
  let retiredFailures = []
  let retiredUnchecked = []
  let recordRetired = (~entityName, stateSchema) =>
    switch checkRetiredValue(~entityName, stateSchema) {
    | NotDeclared => ()
    | Unchecked(why) => retiredUnchecked->Array.push(why)->ignore
    | Checked(failures) => failures->Array.forEach(f => retiredFailures->Array.push(f)->ignore)
    }

  let readModelDefs =
    readModels
    ->Array.map((
      module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
    ) => {
      let qf = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
      let stateSchema = R.Spec.stateSchema->S.castToUnknown
      let label = labelFieldsFromStateSchema(~entityName=R.Spec.name, stateSchema)
      // The same call the capability deriver makes, so the published key and the
      // key the generated filter/order-by is built from cannot disagree.
      let keyField = GraphQL_FragmentGenerator.resolveKeyField(
        ~entityName=R.Spec.name,
        stateSchema,
      )
      // Qualified to the plugin's event ids so they match the producers' nodes.
      let consumed = qualify(~prefix=name, R.consumedEventNames)
      recordRetired(~entityName=R.Spec.name, stateSchema)
      recordLifecycle(~entityName=R.Spec.name, stateSchema)
      ({
        Reventless.Plugin.name: R.Spec.name,
        queryField: qf.listFieldName,
        schema: stateSchema->SuryToJsonSchema.deriveObjectSchema->JSON.stringify,
        consumedEventTypes: consumed,
        linkedWriteSide: linkedWriteSideFor(consumed),
        labelField: label.field,
        searchableFields: label.searchableFields,
        labelFieldSource: Some(labelFieldSourceToString(label.source)),
        lifecycleField: lifecycleFieldFromStateSchema(~entityName=R.Spec.name, stateSchema),
        // Same schema `lifecycleField` reads, so the two cannot disagree about which
        // fields this view has.
        ownerField: Reventless.Owner.fieldNames(stateSchema)->Array.get(0),
        retiredField: retiredFieldFromStateSchema(stateSchema),
        retiredValues: retiredValuesFromStateSchema(stateSchema),
        namedWhenRetired: Some(namedWhenRetiredFromStateSchema(stateSchema)),
        visibility: visibilityTag(R.Spec.visibility),
        chapter: chapterOf(R.Spec.name),
        // Taken from the `qf` record, never re-derived: `Api_Naming` is the only
        // place that decides how `Products`/`Categories` singularise, and the
        // point of publishing the name is that a consumer stops guessing it.
        singleQueryField: Some(qf.singleFieldName),
        idField: keyField->Option.map(((f, _)) => f),
        idFieldSource: keyField->Option.map(((_, rung)) => rung),
        requiredAccess: accessKeysFor(R.Spec.authorization),
      }: Reventless.Plugin.queryableDef)
    })

  let stateViewDefs =
    stateViewSlices->Array.mapWithIndex((module(SVS: ReventlessInfra.StateViewSlice.T), i) => {
      let qf = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=SVS.Spec.name)
      let (_, consumed) = svsConsumed->Array.getUnsafe(i)
      let stateSchema = SVS.Spec.stateSchema->S.castToUnknown
      let label = labelFieldsFromStateSchema(~entityName=SVS.Spec.name, stateSchema)
      let keyField = GraphQL_FragmentGenerator.resolveKeyField(
        ~entityName=SVS.Spec.name,
        stateSchema,
      )
      recordRetired(~entityName=SVS.Spec.name, stateSchema)
      recordLifecycle(~entityName=SVS.Spec.name, stateSchema)
      ({
        Reventless.Plugin.name: SVS.Spec.name,
        queryField: qf.listFieldName,
        schema: stateSchema->SuryToJsonSchema.deriveObjectSchema->JSON.stringify,
        consumedEventTypes: consumed,
        linkedWriteSide: linkedWriteSideFor(consumed),
        labelField: label.field,
        searchableFields: label.searchableFields,
        labelFieldSource: Some(labelFieldSourceToString(label.source)),
        lifecycleField: lifecycleFieldFromStateSchema(~entityName=SVS.Spec.name, stateSchema),
        ownerField: Reventless.Owner.fieldNames(stateSchema)->Array.get(0),
        retiredField: retiredFieldFromStateSchema(stateSchema),
        retiredValues: retiredValuesFromStateSchema(stateSchema),
        namedWhenRetired: Some(namedWhenRetiredFromStateSchema(stateSchema)),
        visibility: visibilityTag(SVS.Spec.visibility),
        chapter: chapterOf(SVS.Spec.name),
        singleQueryField: Some(qf.singleFieldName),
        idField: keyField->Option.map(((f, _)) => f),
        idFieldSource: keyField->Option.map(((_, rung)) => rung),
        requiredAccess: accessKeysFor(SVS.Spec.authorization),
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
          ~commandAuthorization=SCS.Spec.commandAuthorization->Obj.magic,
          ~commandTransition=SCS.Spec.commandTransition->Obj.magic,
          SCS.Spec.commandSchema->S.castToUnknown,
        ),
        producedEventTypes: produced,
        consumedEventTypes: consumed,
        linkedViews: linkedSvsFor(produced),
        consistencyRead: consistencyReadFor(consumed),
        events: extractEventDefs(SCS.Spec.eventSchema->S.castToUnknown),
        errors: extractErrorDefs(SCS.Spec.errorSchema->S.castToUnknown),
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
          ~commandAuthorization=A.Spec.commandAuthorization->Obj.magic,
          ~commandTransition=A.Spec.commandTransition->Obj.magic,
          A.Spec.commandSchema->S.castToUnknown,
        ),
        producedEventTypes: produced,
        consumedEventTypes: [],
        linkedViews: Array.concat(linkedSvsFor(produced), linkedReadModelsFor(A.Spec.name)),
        consistencyRead: None,
        events: extractEventDefs(A.Spec.eventSchema->S.castToUnknown),
        errors: extractErrorDefs(A.Spec.errorSchema->S.castToUnknown),
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

  let tableFailures = []
  let tableWarnings = []
  let pushAll = (into, xs) => xs->Array.forEach(x => into->Array.push(x)->ignore)

  // Every constructor, payload-less included: a declaration is checked against
  // what the author can write, not the payload-filtered subset the edges use.
  let allVariantNames = schema => Reventless.DcbTag.extractAllVariantNames(schema)

  let extensionDefs =
    extensions->Array.map((module(E: ReventlessInfra.Extension.Blueprint)) => {
      let delegateNames = E.mappings->Array.map((module(M: E.Mapping)) => M.delegateName)
      let epEventNames = allVariantNames(E.Spec.eventSchema)
      let epCommandNames = allVariantNames(E.Spec.commandSchema)

      // Mappings sharing one EP union their tables — the same event may route to
      // a different delegate's command in each.
      let commandsByEvent: Dict.t<array<string>> = Dict.make()
      let eventsByCommand: Dict.t<array<string>> = Dict.make()
      E.mappings->Array.forEach((module(M: E.Mapping)) => {
        let label = `${E.Spec.name} → ${M.delegateName}`
        pushAll(
          tableFailures,
          handledTableFailures(
            ~label,
            ~declared=M.handledEvents,
            ~eventNames=epEventNames,
            ~commandNames=Array.concat(M.delegateCommandNames, epCommandNames),
          ),
        )
        pushAll(
          tableFailures,
          commandTableFailures(
            ~label,
            ~keyed="issuedCommands",
            ~valueKind="comes from",
            ~rows=M.issuedCommands->Array.map(({name, fromEventTypes}) => (name, fromEventTypes)),
            ~keyNames=epCommandNames,
            ~valueNames=M.delegateEventNames,
          ),
        )
        M.issuedCommands->Array.forEach(({name: commandName, fromEventTypes}) => {
          let key = `${E.Spec.name}.${commandName}`
          eventsByCommand->Dict.set(
            key,
            Array.concat(
              eventsByCommand->Dict.get(key)->Option.getOr([]),
              qualify(~prefix=name, fromEventTypes),
            ),
          )
        })
        M.handledEvents->Array.forEach(({name: eventName, toCommandTypes}) => {
          // The qualifier says which way the command goes: plugin-qualified
          // inward, EP-qualified back to the port.
          let qualified =
            toCommandTypes->Array.map(cmd =>
              M.delegateCommandNames->Array.includes(cmd)
                ? `${name}.${cmd}`
                : `${E.Spec.name}.${cmd}`
            )
          let key = `${E.Spec.name}.${eventName}`
          commandsByEvent->Dict.set(
            key,
            Array.concat(commandsByEvent->Dict.get(key)->Option.getOr([]), qualified),
          )
        })
      })

      ({
        Reventless.Plugin.name: E.Spec.name,
        delegateNames,
        eventTypes: qualify(~prefix=E.Spec.name, eventVariantNames(E.Spec.eventSchema)),
        commandTypes: qualify(~prefix=E.Spec.name, commandVariantNames(E.Spec.commandSchema)),
        handledEvents: Some(
          commandsByEvent
          ->Dict.toArray
          ->Array.map(((eventName, cmds)) => ({
            Reventless.Plugin.name: eventName,
            toCommandTypes: dedupe(cmds),
          }: Reventless.Plugin.handledEventDef)),
        ),
        issuedCommands: Some(
          eventsByCommand
          ->Dict.toArray
          ->Array.map(((commandName, evs)) => ({
            Reventless.Plugin.name: commandName,
            fromEventTypes: dedupe(evs),
          }: Reventless.Plugin.issuedCommandDef)),
        ),
      }: Reventless.Plugin.extensionDef)
    })

  // ── Extension points (producer side) ──────────────────────────────────────
  //
  // Several mappings can target one EP, so group by its dotted name and union each
  // delegate's name and source events. Source events are plugin-qualified to match
  // `producedEventTypes`, so the graph can draw write-side → event → EP.

  let epByName: Dict.t<(array<string>, array<string>, array<string>)> = Dict.make()
  // Per EP: published event → the internal events producing it, unioned over
  // every mapping targeting it.
  let epPublished: Dict.t<Dict.t<array<string>>> = Dict.make()
  // The command direction's mirror: arriving command → the delegate commands it
  // routes to. Unioned the same way — one port's inbound protocol is split across
  // its mappings, so a command handled by a sibling is not dead surface.
  let epAccepted: Dict.t<Dict.t<array<string>>> = Dict.make()

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

    let label = `${epName} ← ${M.Delegate.name}`
    let publishedNames = allVariantNames(M.ExtensionPoint.eventSchema)
    let sourceNames = allVariantNames(M.Delegate.eventSchema->S.castToUnknown)
    pushAll(
      tableFailures,
      translationTableFailures(~label, ~declared=M.publishedEvents, ~publishedNames, ~sourceNames),
    )

    // ── The command direction ────────────────────────────────────────────────
    let acceptedNames = allVariantNames(M.ExtensionPoint.commandSchema)
    let delegateCommandNames = allVariantNames(M.Delegate.commandSchema)
    pushAll(
      tableFailures,
      commandTableFailures(
        ~label,
        ~keyed="acceptedCommands",
        ~valueKind="routes to",
        ~rows=M.acceptedCommands->Array.map(({name, toCommandTypes}) => (name, toCommandTypes)),
        ~keyNames=acceptedNames,
        ~valueNames=delegateCommandNames,
      ),
    )

    // The mirror of the published-event probe: one synthesised EP command per
    // constructor, through the author's own mapIncomingCommand. Cheaper than the
    // event probe — the signature reaches no query engine.
    let acceptedObserved = []
    acceptedNames->Array.forEach(cmd => {
      let synthesised = Reventless.DcbTag.isVariantPayloadBearing(
        M.ExtensionPoint.commandSchema->S.castToUnknown,
        cmd,
      )
        ? Dict.fromArray([("TAG", JSON.Encode.string(cmd))])->JSON.Encode.object
        : JSON.Encode.string(cmd)
      switch (
        try {
          let command =
            Reventless.Message.fillMissingDefaults(
              M.ExtensionPoint.commandSchema,
              synthesised,
              [],
            )->Reventless.Util_Sury.fromJson(M.ExtensionPoint.commandSchema)
          let decodedAs =
            command
            ->Reventless.Message.encode(M.ExtensionPoint.commandSchema)
            ->Reventless.Message.variantNameOfJson
          decodedAs != cmd
            ? Error(`a synthesised "${cmd}" decoded as "${decodedAs}"`)
            : Ok(M.mapIncomingCommand(probeId, command, probeMeta))
        } catch {
        | _ => Error(`the mapping raised on a synthesised "${cmd}"`)
        }
      ) {
      | Ok(actions) =>
        actions->Array.forEach(action =>
          switch action {
          | ReventlessInfra.ExtensionPointMapping.PublishCommand(_, routed) =>
            acceptedObserved
            ->Array.push((
              cmd,
              routed
              ->Reventless.Message.encode(M.Delegate.commandSchema)
              ->Reventless.Message.variantNameOfJson,
            ))
            ->ignore
          | HandleDirective(_, _) => ()
          }
        )
      | Error(reason) =>
        tableWarnings->Array.push(`${label}: not checked against the arms — ${reason}.`)->ignore
      }
    })
    acceptedObserved->Array.forEach(((cmd, routed)) =>
      if (
        !(
          M.acceptedCommands->Array.some(({name, toCommandTypes}) =>
            name == cmd && toCommandTypes->Array.includes(routed)
          )
        )
      ) {
        tableFailures
        ->Array.push(
          `${label}: "${cmd}" routes to "${routed}", which acceptedCommands does not declare.`,
        )
        ->ignore
      }
    )

    let acceptedTable = epAccepted->Dict.get(epName)->Option.getOr(Dict.make())
    M.acceptedCommands->Array.forEach(({name: accepted, toCommandTypes}) => {
      let key = `${epName}.${accepted}`
      acceptedTable->Dict.set(
        key,
        Array.concat(
          acceptedTable->Dict.get(key)->Option.getOr([]),
          qualify(~prefix=name, toCommandTypes),
        ),
      )
    })
    epAccepted->Dict.set(epName, acceptedTable)

    switch M.mapOutgoingEvent {
    | None =>
      if Array.length(M.publishedEvents) > 0 {
        tableFailures
        ->Array.push(
          `${label}: publishedEvents declares ${M.publishedEvents
            ->Array.length
            ->Int.toString} event(s), but the mapping has no mapOutgoingEvent and ` ++
          `publishes nothing.`,
        )
        ->ignore
      }
    | Some(mapOutgoing) =>
      // One synthesised event per Delegate constructor, through the author's own
      // function — not the compiled one, which logs and re-encodes.
      let observed = []
      let followed = []
      sourceNames->Array.forEach(src => {
        let synthesised = Reventless.DcbTag.isVariantPayloadBearing(
          M.Delegate.eventSchema->S.castToUnknown,
          src,
        )
          ? Dict.fromArray([("TAG", JSON.Encode.string(src))])->JSON.Encode.object
          : JSON.Encode.string(src)
        let outcome = try {
          // Filled directly rather than through `parseJsonTolerant`, which warns
          // about inventing values — here the invention is the point.
          let event =
            Reventless.Message.fillMissingDefaults(M.Delegate.eventSchema, synthesised, [])
            ->Reventless.Util_Sury.fromJson(M.Delegate.eventSchema)
          // A fabricated payload can decode as a sibling constructor; only a
          // value that round-trips is judged.
          let decodedAs =
            event
            ->Reventless.Message.encode(M.Delegate.eventSchema)
            ->Reventless.Message.variantNameOfJson
          if decodedAs != src {
            Error(`a synthesised "${src}" decoded as "${decodedAs}"`)
          } else {
            let actions = mapOutgoing(probeId, event, probeMeta, probeQueryEngine)
            actions->Array.forEach(action =>
              switch action {
              | ReventlessInfra.ExtensionPointMapping.PublishEvent(_, published) =>
                observed
                ->Array.push((
                  src,
                  published
                  ->Reventless.Message.encode(M.ExtensionPoint.eventSchema)
                  ->Reventless.Message.variantNameOfJson,
                ))
                ->ignore
              | PublishEventAsync(_) | HandleDirective(_, _) => ()
              }
            )
            // A promise hides what it will publish — leave the arm unjudged.
            actions->Array.some(action =>
              switch action {
              | PublishEventAsync(_) => true
              | PublishEvent(_, _) | HandleDirective(_, _) => false
              }
            )
              ? Error(`"${src}" publishes behind a promise`)
              : Ok()
          }
        } catch {
        | _ => Error(`the mapping raised on a synthesised "${src}"`)
        }
        switch outcome {
        | Ok() => followed->Array.push(src)->ignore
        | Error(reason) =>
          tableWarnings->Array.push(`${label}: not checked against the arms — ${reason}.`)->ignore
        }
      })

      let (failures, warnings) = translationTableDrift(
        ~label,
        ~declared=M.publishedEvents,
        ~observed,
        ~followed,
      )
      pushAll(tableFailures, failures)
      pushAll(tableWarnings, warnings)
    }

    // Dead protocol surface: an event of the published contract that no arm
    // produces, which a subscriber may already be routing.
    let declaredNames = M.publishedEvents->Array.map(p => p.name)
    publishedNames
    ->Array.filter(p => !(declaredNames->Array.includes(p)))
    ->Array.forEach(p =>
      tableWarnings
      ->Array.push(`${label}: the extension point publishes "${p}", which no arm produces.`)
      ->ignore
    )

    let table = epPublished->Dict.get(epName)->Option.getOr(Dict.make())
    M.publishedEvents->Array.forEach(({name: published, fromEventTypes}) => {
      let key = `${epName}.${published}`
      table->Dict.set(
        key,
        Array.concat(
          table->Dict.get(key)->Option.getOr([]),
          qualify(~prefix=name, fromEventTypes),
        ),
      )
    })
    epPublished->Dict.set(epName, table)
  })

  let extensionPointDefs =
    epByName
    ->Dict.toArray
    ->Array.map(((epName, (dels, evs, cmds))) => ({
      Reventless.Plugin.name: epName,
      delegateNames: dedupe(dels),
      sourceEventTypes: dedupe(evs),
      commandTypes: Some(dedupe(cmds)),
      publishedEvents: Some(
        epPublished
        ->Dict.get(epName)
        ->Option.getOr(Dict.make())
        ->Dict.toArray
        ->Array.map(((published, sources)) => ({
          Reventless.Plugin.name: published,
          fromEventTypes: dedupe(sources),
        }: Reventless.Plugin.publishedEventDef)),
      ),
      acceptedCommands: Some(
        epAccepted
        ->Dict.get(epName)
        ->Option.getOr(Dict.make())
        ->Dict.toArray
        ->Array.map(((accepted, routed)) => ({
          Reventless.Plugin.name: accepted,
          toCommandTypes: dedupe(routed),
        }: Reventless.Plugin.acceptedCommandDef)),
      ),
    }: Reventless.Plugin.extensionPointDef))

  // Dead inbound surface, judged only after every mapping on an EP has been seen:
  // one port's inbound protocol is split across its mappings, so a command the
  // Plugin mapping ignores may be the UiFragment mapping's whole job.
  epByName
  ->Dict.toArray
  ->Array.forEach(((epName, (_, _, cmds))) => {
    let handled =
      epAccepted->Dict.get(epName)->Option.getOr(Dict.make())->Dict.keysToArray
    cmds
    ->dedupe
    ->Array.forEach(cmd =>
      if !(handled->Array.includes(cmd)) {
        tableWarnings
        ->Array.push(
          `${epName}: the extension point accepts "${cmd}", which no arm handles — a ` ++
          `sender gets no error and nothing happens.`,
        )
        ->ignore
      }
    )
  })

  reportTranslationTables(~pluginName=name, ~failures=tableFailures, ~warnings=tableWarnings)

  // Second pass, on purpose: commands are built well before `linkedViews` is
  // assembled, so the check cannot run inline where the defs are made.
  checkDeclaredTransitions(
    ~pluginName=name,
    ~writables=Array.concat(stateChangeDefs, aggregateDefs),
    ~lifecycleStatesByView,
  )
  checkLifecycleTopology(
    ~pluginName=name,
    ~writables=Array.concat(stateChangeDefs, aggregateDefs),
    ~lifecycleStatesByView,
  )
  // Also a second pass, for a different reason: the failures are gathered per
  // view as those defs are built, and raising inline would report the first bad
  // name and hide the rest.
  reportRetiredStates(~pluginName=name, ~failures=retiredFailures, ~unchecked=retiredUnchecked)

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
    requiredStoreDeclarations: Some(requiredStoreDeclarations),
    traitDeclarations: Some(traitDeclarations),
    requiredCapabilities: Some(requiredCapabilities),
  }
}
