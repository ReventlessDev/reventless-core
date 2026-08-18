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

// Whether a field can hold a lifecycle: a closed set of values, or an optional
// one. A free-text `lifecycle: string` is not a lifecycle — filtering a command
// menu against `allowedStates` needs states to compare with.
let rec isLifecycleShape = (t: SchemaType.schemaType): bool =>
  switch t {
  | Enum(_, _) => true
  | Nullable(inner) => isLifecycleShape(inner)
  | _ => false
  }

// Field names that say "this one is the record's name" in the only way
// available short of the `@displayName` annotation. Matched case-insensitively
// and *exactly*: `customerName` holds a customer's name, not this record's.
let conventionalLabelNames = ["name", "title", "label", "displayname"]

let shapeOfField = (~entityName: string, ~name: string, schema: S.t<unknown>): SchemaType.schemaType =>
  SchemaType.fromSury(~parentName=entityName, ~fieldName=name, schema)

// Resolve the field that holds the entity's lifecycle, used to filter a per-row
// command menu against each command's `allowedStates`. Resolution order:
//   1. Field annotated `@lifecycle` (PPX-emitted; see StateAnnotations).
//   2. Field literally named `"lifecycle"` whose IR shape is an enum (convention;
//      mirrors how labelField falls back to a conventionally-named field).
//   3. None — filter is inert for this read model.
//
// The convention rung is keyed on `lifecycle` rather than `status` deliberately:
// `status` is a promiscuous name — geocoding progress, todo-queue progress and
// translation audit outcome all wear it — so a convention keyed on it guesses,
// and guesses often. `lifecycle` is a word nobody types by accident, so matching
// it is closer to a declaration written in the field name. A record whose field
// is honestly called something else annotates instead.
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

// The field whose truth withdraws a row from ordinary reads. Annotation-only:
// there is no convention rung here, and its absence is the point. `lifecycleField`
// may fall back to a field literally named "lifecycle" because guessing wrong makes
// a command menu filter oddly; guessing wrong here makes rows vanish for every
// caller who is not elevated, so a boolean named `archived` that nobody annotated
// stays exactly as visible as it was.
let retiredFromStateSchema = (
  stateSchema: S.t<unknown>,
): option<Reventless.StateAnnotations.retiredSpec> =>
  switch Reventless.StateAnnotations.getSpec(stateSchema) {
  | Some(spec) => spec.retired
  | None => None
  }

let retiredFieldFromStateSchema = (stateSchema: S.t<unknown>): option<string> =>
  retiredFromStateSchema(stateSchema)->Option.map(r => r.field)

// The states a row is retired *in*, for the enum form. `None` is the boolean
// form, where the value is always `true` and naming it would be a parameter that
// can only hold one thing. A set, because a lifecycle may be withdrawn by more
// than one state, and a one-member set is the ordinary case.
//
// Published beside `retiredField` rather than left for a consumer to dig out of
// the schema: a client that has the def in hand has the whole predicate, and two
// places deriving one comparison is how they come to disagree about it.
let retiredValuesFromStateSchema = (stateSchema: S.t<unknown>): option<array<string>> =>
  retiredFromStateSchema(stateSchema)->Option.flatMap(r => r.values)

// Whether a reference to a retired row of this view still resolves its name —
// `@namedWhenRetired`. Read off the retirement rather than from a second
// annotation, so a record cannot declare the reach of a retirement it does not
// have; the PPX refuses that pairing, and reading it here from the same place
// keeps the two halves agreeing by construction rather than by review.
let namedWhenRetiredFromStateSchema = (stateSchema: S.t<unknown>): bool =>
  retiredFromStateSchema(stateSchema)->Option.mapOr(false, r => r.namedWhenRetired)

// What one record's `@retired` declaration could be told about its own field.
//
// Three outcomes rather than a bool, because "nothing to check" and "could not
// check" are different facts and only the second is worth a plugin's attention.
type retiredCheck =
  | NotDeclared
  // Why the names could not be compared. A fatal rule that is invisible when it
  // does not run is the failure mode the transition check spends a counter to
  // avoid, so this is reported rather than skipped in silence.
  | Unchecked(string)
  | Checked(array<string>)

// The check the PPX cannot make, in the one place that can: the payload is a
// constructor reference the PPX only ever sees as a name, and whether that name
// is a case of the field's enum needs the schema.
//
// Two rules, and they are held to different standards on purpose.
//
// **A name the field's enum does not declare is unambiguously wrong** — no domain
// means it — and the symptom is a data-exposure bug: the retirement predicate
// compares every row against a state no row is ever in, so every row stays
// visible to every caller while the annotation sits on the schema looking like
// enforcement. That is returned as a failure for the caller to raise on.
//
// It is the same fault the PPX already refuses to compile when the enum is
// declared in the same file, and the PPX says so in its own message. This is the
// residue that a per-file pass cannot reach: field form, enum imported from
// elsewhere. Two rungs of one ladder — until this was promoted, which rung you
// landed on decided whether a data-exposure bug stopped the build, and the
// arbiter was where the enum happened to be declared.
//
// **A `value` on a field that is not the record's lifecycle stays a warning.**
// It would keep the read narrowing while silently losing the command filtering
// that motivates it — `@transition` is written in terms of the lifecycle field,
// so a retirement state anywhere else is a state no command can name. That is a
// modelling judgement rather than a wrong name, and judgement calls are what the
// withdrawn dead-end rule taught us not to hard-fail on.
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
          )}. A retirement state no command's @transition can name loses the command filtering the state form exists for.`,
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

// Raised together, after every view has been walked, so an author sees every bad
// name at once rather than the first one and then a rebuild.
//
// Retroactive in a way the transition check was not: `@transition` was new when
// its check landed, so nothing deployed could carry a stale name, while `@retired`
// has been shipping. A deployed plugin holding a misspelled retired value gets a
// red build on its next deploy — which is the point, and is why the examples were
// swept before this was promoted.
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

// The states a record's lifecycle field can hold. The same extraction
// `checkRetiredValue` does, keyed on the declared lifecycle field rather than the
// retired one — which is the field a command's `@transition` is written in terms
// of. `None` means the record declares no lifecycle at all; `Some([])` means it
// declares one whose shape carries no cases to compare against.
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

// The other check the PPX cannot make, and the reason `@transition` is worth
// more than a rename.
//
// A command declares the states it may run from and the state it lands in, but
// those states belong to ANOTHER component's lifecycle enum. The PPX only ever
// sees them as names — it strips the attribute before the typechecker, and a
// synthetic reference to the constructor does not survive ReScript's pre-PPX
// dependency walk. So a misspelled state compiles clean, ships, and produces a
// command that is legal in a state no row is ever in: a menu entry that never
// appears, with nothing anywhere saying why.
//
// Here both sides are in hand. This runs at plugin-structure assembly, which
// happens in the deploy program and at local-platform start — never inside a
// deployed Lambda, which reads a persisted structure rather than building one.
// So raising is a failed deploy, not a dead function.
//
// Two severities, and the split is deliberate:
//   - a state the linked views do not declare  → RAISE. The author named
//     something that does not exist.
//   - no resolvable linked view, or none declaring a lifecycle → warn. The
//     metadata gap is real but hard-failing on it would turn "this plugin's
//     views could not be resolved" into a deploy outage, and that population is
//     broad.
//
// Checked against the UNION of the linked views' lifecycles rather than a single
// view: a command whose slice feeds two views is not claiming which one, and
// failing on an ambiguity the author never expressed would be a false positive
// on correct code.
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
              `${w.name}.${cmd.name}: @transition names "${state}", which none of its ` ++
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
      `${pluginName}: ${unvalidated.contents->Int.toString} command(s) declare a @transition ` ++
      `but no linked view declares a lifecycle to check it against.`,
    )
  }

  if Array.length(failures) > 0 {
    JsError.throwWithMessage(
      `${pluginName}: @transition names states that do not exist.\n` ++
      failures->Array.join("\n"),
    )
  }
}

// Beyond "does this state exist" — does the declared graph make sense?
//
// A separate pass from the name check on purpose. That one asks whether a name
// is a case of an enum, which is a question about one annotation in isolation.
// These ask whether the annotations AGREE with each other across an entity, and
// a graph can be built entirely out of valid names and still be wrong: a state
// nothing reaches, or one nothing can leave that was never marked as an ending.
//
// Reported as warnings rather than raised. The name check fails a build because
// a state that does not exist is unambiguously a mistake — there is no domain in
// which it is what the author meant. These are weaker signals: a state with no
// way out may be a genuine dead end nobody has marked yet, or a legitimate
// terminal the model reaches by a route this metadata cannot see (an automation,
// an external system). Failing a deploy on a modelling smell would be the wrong
// trade, and a smell that stops a deploy gets silenced rather than fixed.
// Pure, and returns its findings rather than logging them, so the rule can be
// tested without reading a log. `checkLifecycleTopology` below is the thin part
// that reports them.
let lifecycleTopologyFindings = (
  ~writables: array<Reventless.Plugin.writableDef>,
  ~lifecycleStatesByView: dict<array<string>>,
): array<(string, string)> => {
  let findings = []
  lifecycleStatesByView
  ->Dict.toArray
  ->Array.forEach(((view, states)) => {
    // Every state some command declares a transition INTO. The question this
    // check asks is only about arrival, so it reads the target and never the
    // from-set — which is what lets a creating command (`@transition(() => X)`,
    // a target and no from-set, because it runs from no row) count towards
    // reachability the same way an edge out of another state does.
    let reachable = writables->Array.reduce([], (acc, w) =>
      w.linkedViews->Array.includes(view)
        ? Array.concat(acc, w.commands->Array.filterMap(cmd => cmd.targetState))
        : acc
    )
    if Array.length(reachable) > 0 {
      // Rows start in the first declared state — the same convention the
      // lifecycle diagram uses — so nothing pointing at it is expected rather
      // than suspicious.
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
        // NOT checked: a state with no way out.
        //
        // The obvious second rule — "a dead end that is not `@retired` is
        // suspicious" — was written, run against the shipped examples, and
        // removed, because it is wrong twice over.
        //
        // It fires on correct models: `Shipped` and `Refunded` are terminal in
        // the aggregates shop, as terminal states are in most lifecycles, and
        // there is nothing to fix about either.
        //
        // Worse, its suggested fix is harmful. `@retired` does not mean
        // "terminal" — it means WITHDRAWN FROM ORDINARY READS. Marking a shipped
        // order retired to silence a lint would hide every shipped order from
        // every caller who cannot widen their read. An ending and a withdrawal
        // are different facts, and nothing in the vocabulary currently
        // distinguishes an intentional terminal from an accidental one, so the
        // check cannot tell them apart and should not pretend to.
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

// NOT here: the event-consumption completeness check.
//
// The failure it would catch is real and has already happened: a command emitted
// an event, the slice that owned the opposite command folded it, and the view
// that renders the entity did not — so the row kept rendering the state it was
// in before, with every annotation in the plugin correct. That is a class of bug
// no declaration check can see, because nothing declared is wrong.
//
// It is not computable from this metadata, and the reason is worth recording so
// the attempt is not repeated. Two narrowings were needed and only one was
// available:
//
//   1. The event must belong to the view's own entity, not merely be something a
//      slice looked up. Available: require it to be PRODUCED by a writable
//      linked to the same view. Without this the check fires on ordinary DCB —
//      `AddProduct` folds `CategoryAdded` to check a category exists, and the
//      `Products` view is right to ignore it.
//
//   2. The slice must be known to fold the event. NOT available:
//      `consumedEventTypes` is built from `eventVariantNames`, which drops
//      payload-less variants — and a lifecycle-moving event is usually
//      payload-less in the slice that folds it. Measured on the shipped example:
//      both order slices publish `consumedEventTypes: ["Ordering.OrderPlaced"]`
//      and nothing else, though each folds three more.
//
// So the exact events the rule is about are the ones the metadata does not
// record. Making it work means publishing the payload-less consumed variants,
// which is a platform change with its own consequences, not a lint.

// Which rung of the ladder below produced the label. Published on `queryableDef`
// as `labelFieldSource`, because the four rungs are not equally believable and a
// consumer with a name rule of its own has to rank the declaration against it:
// rung 1 is the author saying which field names the record, rungs 2 and 3 are
// guesses this repo makes on their behalf, and rung 4 is the admission that
// there was nothing to guess from. Convention and position are both guesses and
// nothing here branches on the difference — but a conventional name is the one a
// client can independently arrive at, while a positional pick is a fact only
// this side knows.
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

// Resolves the field a state is named by, from a state schema.
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

// ── Per-variant event / error field extraction (Phase 6.3) ───────────────────
// Mirrors toCommandDef/extractCommandDefs for emitted events: name (TAG const),
// payload JSON Schema, and cross-entity references. Module-level rather than
// inside `make` because the synthetic Platform_Admin structure — hand-written,
// because its components never pass through `make` — has to derive its defs the
// same way, and a second copy of this walk would be free to drift from this one.

// A variant's declared cross-entity references. Shared by the command and event
// walks because the two ask the identical question of identical field dicts, and
// the question is `getFieldTarget` rather than `getTarget`: a reference declared
// on an `array<string>` field sits on the element schema. Collecting it in one
// place is what stops one walk from being taught that and the other not.
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
  | AnyOf({anyOf}) => anyOf->Array.filterMap(toEventDef)
  | _ => toEventDef(eventSchema)->Option.mapOr([], def => [def])
  }

// Declared errors walk identically to emitted events — an error variant is a
// variant, and the payload-less form (`| CategoryNotFound`) is the common case
// the bare-string branch above already handles. Reusing the walk rather than
// copying it keeps the two from drifting; only the def type differs, so that a
// consumer (and the SDL) can tell a refusal from a fact.
let extractErrorDefs = (errorSchema: S.t<unknown>): array<Reventless.Plugin.errorDef> =>
  extractEventDefs(errorSchema)->Array.map(({name, schema, references}) => (
    {name, schema, references}: Reventless.Plugin.errorDef
  ))

// The command walk, module-level for the same reason as the event walk above:
// the synthetic Platform_Admin structure cannot reach `make` — it has no
// `module(Aggregate.T)` to hand it — and hand-writing a second copy of this walk
// is what let its command metadata drift from the SDL generated off the same
// schema.

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

// A rule the server enforces, expressed as the keys a client checks against
// `identity.groups ++ config.accessTiers`. `AllowGroups` is satisfied by ANY of
// its groups (`Authorization.isAllowed` is `some`, not `every`), so the array is
// an any-of and a client must read it that way.
//
// `AllowAuthenticated` / `AllowAnonymous` ask for nothing a client can check —
// anyone holding a session already satisfies them — so they publish no keys
// rather than a key everyone holds.
//
// `DenyAll` also publishes none, deliberately. An unsatisfiable key would render
// as locked-with-upsell in a tiered shell: a surface advertised as purchasable
// that no purchase unlocks. A component nobody may call belongs in no menu, and
// that is an omission for the enumerating side to make, not a key to invent here.
let accessKeysFor = (rule: Reventless.Authorization.permission): option<array<string>> =>
  switch rule {
  | AllowGroups(groups) if groups->Array.length > 0 => Some(groups)
  | AllowGroups(_) | AllowAuthenticated | AllowAnonymous | DenyAll => None
  }

// Write each mutation argument's rendered GraphQL type onto the property it
// belongs to, so a consumer assembling its own mutation document declares the
// variable the server actually expects instead of guessing `String!`.
//
// Mutates the freshly derived schema in place — `deriveObjectSchema` has just
// built it and nothing else holds it yet. A property with no matching
// argument is left alone rather than annotated with a guess.
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
  v: S.t<unknown>,
): option<Reventless.Plugin.commandDef> => {
  // Build a commandDef for one variant. `properties` is the variant's field dict —
  // empty for a payload-less variant (e.g. `| Archive`), which compiles to a bare
  // `S.literal("Archive")` string rather than an `{TAG, ...}` object.
  let mkDef = (~variantName, ~properties) => {
    let (level, aggregateIdField) = commandLevelAndId(~isAggregate, ~variantName, properties)
    let references = extractReferences(properties)
    // Per-variant `allowedStates` lives on the *parent* command schema
    // (the PPX attaches a single dict<variantName, [|states|]> via
    // markAllowedStates). Look it up by variant name; back-compat
    // None when the variant lacks a @transition annotation.
    let allowedStates = ApiAllowedStatesHelpers.getAllowedStates(parentSchema, ~variantName)
    // The `@transition` target (the command's *to* status), read the same way
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
    // Evaluated against a synthetic value per constructor, the same shape the
    // resolver builds at call time: a payload-bearing variant compiles to
    // `{TAG, ...}`, a payload-less one to a bare string.
    let syntheticCommand: unknown =
      Reventless.DcbTag.isVariantPayloadBearing(parentSchema, variantName)
        ? {"TAG": variantName}->Obj.magic
        : variantName->Obj.magic
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
      // The derived schema, not sury's raw one: `S.toJSONSchema` carries the
      // shape and drops every `x-reventless-*` marker the PPX put on the
      // fields, so a command's `@storageRef`/`@semantic`/`@ref` reached the
      // wire on the read side and nowhere on the write side. A reader that
      // matches a field against its setter — or picks the upload endpoint of
      // the store a command argument declares — then has nothing to match on.
      // `MCP_SchemaGenerator` already derives these same variant schemas.
      //
      // Carries `x-reventless-graphql-type` per property — see
      // `annotateArgTypes`.
      schema: annotatedSchema->JSON.stringify,
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

// Strip named fields from a derived JSON schema's `properties` and `required`.
//
// The narrow companion to `@internal`, and the two are not alternatives. A field
// declared `@internal` is off the surface entirely and this never sees it. This
// is for a caller that publishes a NARROWED view of a schema whose fields are
// genuinely on the API — the admin's `apiSchemaFragment` / `structure`, which
// other callers query through dedicated resolver paths and only the generated
// list view must not name.
let encodeSchemaExcluding = (schema: S.t<unknown>, ~excludeFields: array<string>): string => {
  let derived = schema->SuryToJsonSchema.deriveObjectSchema
  if excludeFields->Array.length == 0 {
    derived->JSON.stringify
  } else {
    switch derived->JSON.Decode.object {
    | None => derived->JSON.stringify
    | Some(obj) =>
      switch obj->Dict.get("properties")->Option.flatMap(JSON.Decode.object) {
      | None => derived->JSON.stringify
      | Some(props) =>
        excludeFields->Array.forEach(f => props->Dict.delete(f))
        obj->Dict.set("properties", props->JSON.Encode.object)
        switch obj->Dict.get("required")->Option.flatMap(JSON.Decode.array) {
        | None => ()
        | Some(req) =>
          let filtered =
            req
            ->Array.filterMap(JSON.Decode.string)
            ->Array.filter(name => !(excludeFields->Array.includes(name)))
            ->Array.map(JSON.Encode.string)
            ->JSON.Encode.array
          obj->Dict.set("required", filtered)
        }
        obj->JSON.Encode.object->JSON.stringify
      }
    }
  }
}

/**
 A read model's published `queryableDef`, assembled from its **spec** rather than
 from a built component.

 `make` cannot serve the platform's own components: it takes
 `module(ReadModel.T)` values, and the platform has no built module to hand
 itself at structure-assembly time — the components it is describing are the ones
 being assembled. That is a real constraint and this routes around it rather than
 pretending it away, by taking the schemas the extractors actually need.

 Everything here is the same helper `make` calls on the same schema, so the
 platform's own view is described by the mechanism that describes everyone
 else's. The alternative — a hand-written record — is what let the admin's
 metadata drift from the SDL generated off the same spec, four times over.

 `queryField` and `singleQueryField` come from `Api_Naming`, which is the only
 place that decides how a name singularises. For the admin these are
 byte-identical to the names it used to hand-write; `singularize` already handled
 the plural-spec-name / singular-type shape that looked bespoke.
 */
let queryableDefFromSpec = (
  ~plugin: string,
  ~name: string,
  ~stateSchema: S.t<unknown>,
  ~authorization: Reventless.Authorization.permission,
  ~visibility: Reventless.Visibility.t=Public,
  ~consumedEventTypes: array<string>=[],
  ~linkedWriteSide: array<string>=[],
  // See `encodeSchemaExcluding`. Empty for every caller that has nothing to
  // narrow, which is the ordinary case.
  ~excludeFields: array<string>=[],
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
    schema: stateSchema->encodeSchemaExcluding(~excludeFields),
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
  // Component name → chapter (intra-plugin grouping band), captured at build time
  // from each component's source folder by the plugin generator. A component whose
  // spec name has no entry (or lives directly under a kind-folder) carries no chapter
  // and renders flat. Keyed by `Spec.name`, which equals the source filename stem for
  // every graph-node kind, so the generator can build this map from the discovered
  // file paths. See `Codegen.chapterOf` and docs/plans/done/deployed-chapter-grouping.md.
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
  // the key set is deduplicated.
  //
  // Each collected entry keeps its declaration site `(component, field)` as
  // provenance, and `requiredStores` is derived from the collected entries —
  // one walk, so the capability manifest's provenance and the deploy's key set
  // cannot come from different readings of the schemas.

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
        // The annotation as its author wrote it. `target.plugin` is `None`
        // exactly when the field left the store unqualified, so this is the
        // source text rather than a guess at it — and this is the only place
        // that distinction survives. Always `Some` here: the field is optional
        // on the type only so definitions stored before it existed still decode.
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

  // The (component, schema) sites the store walk reads. One list feeds both the
  // declared-store collection and the heuristic lint below, so a field is read
  // exactly once: either its declaration is collected, or its name is eligible
  // to warn — never a third reading that could disagree with both.
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

  // Sorted so the emitted manifest is deterministic; identical triples collapse
  // (one store named by a component's command field and again by its event
  // field under the same field name is one declaration site).
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
  // Internal ReadModels and StateViewSlices (marked `@@reventless.visibility(Internal)`)
  // are CARRIED in pluginStructure, tagged via `queryableDef.visibility` (`None` = Public,
  // `Some("Internal")` = Internal). Developer tools — the `reventless-gwt` / VSCode domain
  // graph and dead-code analysis — read them so an Internal view still shows up there. The
  // deployed AutoUI's consumers (Platform_ComponentDefinitionsApi menu/pages) re-filter on
  // the tag so the live UI keeps hiding them — see Visibility.res, which documents this contract.
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
      // The events this read model projects from, qualified to the plugin's event ids so
      // they match the producers' nodes in the graph. Was empty — which dropped projection
      // edges for any event reaching the read model via a DCB-log-sourced mapping (a classic
      // aggregate→view link is also drawn from the producer's linkedViews, deduped downstream).
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
  }
}
