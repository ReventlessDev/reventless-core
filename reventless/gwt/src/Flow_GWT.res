open ReventlessCore

// Flow_GWT — cross-slice / end-to-end GWT.
//
// Threads ONE JSON-erased event log through a chain of slices, so a single
// declarative test verifies that the tiles of an Event Modeling board connect
// the way the diagram says: a command lands, an event is recorded, an
// automation reacts and issues the next command, a read model updates, an
// outbound effect fires. Where every other GWT kind verifies one tile in
// isolation, this one verifies the wiring between them.
//
// Slices are pure, so the flow runs with no bus, no scheduler and no timers:
// each step folds the slice's own `decide`/`evolve`/`collect`/`project` over
// the shared log. The log is JSON-erased (each step (de)serialises through its
// own spec's schema, exactly as the runtime routes a DCB event log), and each
// command step honors DCB tag filtering so downstream deciders never see
// phantom cross-entity events.
//
// The chain is built from one step per part, each a `…Step` functor applied to
// the part, threaded with pipe-first so it reads top-to-bottom. A plugin's
// generated `Flow` module (its tests/Flow.res) offers every part's step under
// the part's own name:
//
//   start
//   ->Flow.SyncCatalogProduct.givenEvents([CatalogProductSynced({...})])
//   ->Flow.PlaceOrder.whenCommand(PlaceOrder({...}))
//   ->Flow.PlaceOrder.thenEvents([OrderPlaced({...})])
//   ->Flow.AutoShipOrder.whenReacts
//   ->Flow.AutoShipOrder.thenIssuesCommand(ShipOrder({...}))
//   ->Flow.Orders.thenRow("o1", {...})
//
// A part no plugin generates a step for is set up by hand:
// `module Place = DecisionStep(PlaceOrder, PlaceOrder_Decision)`.
//
// Across plugins, `ExtensionPointStep` and `ExtensionStep` continue a flow from
// one plugin into the next through the extension point mapping and the
// extension, as the runtime routes it across the plugin boundary.
//
// Every step counts itself as the flow passes it, so a failure names its step:
// *step 6 of 8, ShipOrder.thenEvent*.

module EPMapping = ReventlessInfra.ExtensionPointMapping
module ExtMapping = ReventlessInfra.ExtensionMapping

// -- Shared log + flow state -------------------------------------------------

// One JSON-erased entry on the shared log: the variant name, the DCB tags
// extracted from the producing schema (so downstream tag filtering matches the
// runtime), the encoded event JSON, and — for events emitted by an aggregate
// step — the producing aggregate-ID. DCB step entries leave `aggregateId` as
// `None`; aggregate step entries set it to `Some(id)` so the matching
// `AggregateStep` can rebuild per-aggregate history without DCB tag
// inference. Filtering by `aggregateId` and filtering by DCB tags are mutually
// exclusive: DCB queries look only at `eventType` + `tags`, and the aggregate
// decoder looks only at `aggregateId` + `eventType`. `at` is when the event was
// recorded, in milliseconds since 1970: the flow's time at the step.
type logEntry = {
  eventType: string,
  tags: array<Reventless.DcbTag.tag>,
  json: JSON.t,
  aggregateId: option<string>,
  at: float,
}

// The flow state threaded through every step. `outcome` accumulates assertions
// (first failure wins); the `last*` fields carry the most recent `when*`
// result for the matching `then*` to read.
type flowState = {
  log: array<logEntry>,
  outcome: Outcome.outcome,
  lastEvents: array<JSON.t>, // encoded events from the last command step
  lastError: option<JSON.t>, // encoded error from the last command step
  lastCommands: array<JSON.t>, // encoded commands from the last automation / extension reaction
  lastPublic: array<JSON.t>, // encoded public EP events from the last ExtensionPoint step
  // The producing aggregate-ID for `lastEvents`, when the producer was an
  // `AggregateStep`. Aggregate-style EP mappings reference the source
  // aggregate-ID inside `mapOutgoingEvent` (e.g. the catalog Product EP uses
  // it as `productId`); the next `ExtensionPointStep` reads this field and
  // threads it through. DCB `DecisionStep` events leave it `None` and the EP
  // step falls back to the synthetic `gwt-id` so the existing DCB Flow tests
  // are unchanged.
  lastAggregateId: option<string>,
  // Why the last inbound step produced no commands, when it was refused.
  lastRefusal: option<string>,
  // How many steps the flow has passed, the one it is at, and the one its first
  // failure was found at.
  steps: int,
  at: option<Outcome.step>,
  failedAt: option<Outcome.step>,
  // The flow's time, in milliseconds since 1970. It starts at 0 and moves only
  // forward, when a step says when it happens.
  now: float,
}

type flow = promise<flowState>

let emptyState = {
  log: [],
  outcome: Outcome.pass,
  lastEvents: [],
  lastError: None,
  lastCommands: [],
  lastPublic: [],
  lastAggregateId: None,
  lastRefusal: None,
  steps: 0,
  at: None,
  failedAt: None,
  now: 0.0,
}

// Entry point for a chain — an empty flow with no prior history.
let start: flow = Promise.resolve(emptyState)

// First failure wins: once the flow has recorded a mismatch, later assertions
// keep it rather than overwrite with a (possibly spurious) downstream result.
let recordOutcome = (s: flowState, o: Outcome.outcome): flowState =>
  switch (s.outcome, o) {
  | (Error(_), _) | (Ok(), Ok()) => s
  | (Ok(), Error(_)) => {...s, outcome: o, failedAt: s.at}
  }

// An instant as the examples write one: no milliseconds when there are none.
let iso = (millis: float) => millis->Date.fromTime->Date.toISOString->String.replace(".000Z", "Z")

// Every step counts itself as the flow passes it, so a failure can say where. A
// step that says when it happens (`~at`, an ISO instant) moves the flow's time
// there; one that says nothing happens at the time of the step before it.
let enter = async (flowP: flow, ~verb, ~part=?, ~at=?) => {
  let s = await flowP
  let number = s.steps + 1
  let s = {...s, steps: number, at: Some({Outcome.number, total: 0, verb, ?part})}
  switch at {
  | None => s
  | Some(text) =>
    let millis = Date.fromString(text)->Date.getTime
    if Float.isNaN(millis) {
      s->recordOutcome(Outcome.fail(Throw({error: `~at="${text}" is not an instant`, stack: ""})))
    } else if millis < s.now {
      s->recordOutcome(
        Outcome.fail(
          Throw({
            error: `~at="${text}" is before the flow's time, ${iso(
                s.now,
              )}: time only moves forward`,
            stack: "",
          }),
        ),
      )
    } else {
      {...s, now: millis}
    }
  }
}

// Mirror the in-memory DCB event log's `matchesQuery`: an empty query matches
// everything; otherwise an entry matches if ANY clause matches (its event type
// is in the clause's `eventTypes` AND it carries every tag the clause lists).
let entryMatchesQuery = (entry: logEntry, query: Reventless.DcbTag.query) =>
  if query->Array.length == 0 {
    true
  } else {
    query->Array.some(qi => {
      let typeMatch = switch qi.eventTypes {
      | Some(types) => types->Array.includes(entry.eventType)
      | None => true
      }
      let tagMatch = switch qi.tags {
      | Some(tags) =>
        tags->Array.every(tag =>
          entry.tags->Array.some(et => et.key == tag.key && et.value == tag.value)
        )
      | None => true
      }
      typeMatch && tagMatch
    })
  }

// Encode + tag a batch of typed events and append them to the log.
let appendEvents = (log: array<logEntry>, ~at: float, events: array<'e>, schema: S.t<'e>): array<
  logEntry,
> =>
  Array.concat(
    log,
    events->Array.map(ev => {
      let json = ev->Message.encode(schema)
      {
        eventType: json->Reventless.Message.variantNameOfJson,
        tags: Reventless.DcbTag.extractTagsExpanded(schema, ev),
        json,
        aggregateId: None,
        at,
      }
    }),
  )

// Aggregate-style append: encode + tag with the producing aggregate-ID so
// `decodeAggregateMatching` can rebuild that aggregate's history later. DCB
// tags are intentionally still extracted (cheap and lets a downstream DCB
// step pick the events up if any are tagged), but the `aggregateId` is the
// authoritative filter for aggregate consumers.
let appendAggregateEvents = (
  log: array<logEntry>,
  ~id: string,
  ~at: float,
  events: array<'e>,
  schema: S.t<'e>,
): array<logEntry> =>
  Array.concat(
    log,
    events->Array.map(ev => {
      let json = ev->Message.encode(schema)
      {
        eventType: json->Reventless.Message.variantNameOfJson,
        tags: Reventless.DcbTag.extractTagsExpanded(schema, ev),
        json,
        aggregateId: Some(id),
        at,
      }
    }),
  )

// Decode the log entries a consumer cares about. `query` filters by event type
// and DCB tags (use `[]` to take all of the consumer's event types); the
// decoder drops entries whose type the consumer does not declare.
let decodeMatching = (
  log: array<logEntry>,
  decoder: Reventless.DcbDecode.makeDecoderResult<'c>,
  query: Reventless.DcbTag.query,
): array<'c> =>
  log->Array.filterMap(entry =>
    if entry->entryMatchesQuery(query) {
      let data = switch entry.json {
      | Object(d) => d
      | _ => Dict.make()
      }
      decoder.decode(~eventType=entry.eventType, ~data)
    } else {
      None
    }
  )

// Aggregate-style decode: filter the log to entries this aggregate-step
// emitted for `id`, then decode them with the aggregate's event schema. No
// DCB tag inference — partitioning is by `aggregateId` only, matching the
// way `Reventless.Aggregate` folds events at runtime.
let decodeAggregateMatching = (
  log: array<logEntry>,
  ~id: string,
  decoder: Reventless.DcbDecode.makeDecoderResult<'c>,
): array<'c> =>
  log->Array.filterMap(entry =>
    switch entry.aggregateId {
    | Some(eid) if eid == id =>
      let data = switch entry.json {
      | Object(d) => d
      | _ => Dict.make()
      }
      decoder.decode(~eventType=entry.eventType, ~data)
    | _ => None
    }
  )

// -- Top-level test registration ---------------------------------------------

let describe = JestBind.describe

// A finished flow's outcome. A failure carries the step it was found at, among
// all the steps the flow passed.
let outcomeOf = (s: flowState): Outcome.outcome =>
  switch (s.outcome, s.failedAt) {
  | (Error(m), Some(step)) => Error(m->Outcome.atStep({...step, total: s.steps}))
  | (outcome, _) => outcome
  }

// The chain returns a `flow`; `test` awaits it and reports its outcome. Bodies
// read top-to-bottom and end on the last `then*`. `~tells` names what the flow
// tells, for a reader of its steps file; the flow itself does nothing with it.
let test = (name, ~tells as _: option<string>=?, ~timeout=?, body: unit => flow) =>
  JestBind.testPromise(~slice="Flow", name, ~timeout?, async () => outcomeOf(await body()))

// -- Boundary scope ----------------------------------------------------------

// Assert that a DCB consistency boundary derives its tag scope.
//
// Every other step here tests slices; this one tests the set of them, and it is
// in the flow DSL because a flow is the only test kind that already reasons
// about more than one slice at a time. The rest of the harness derives scope
// per slice (`DcbScopeInference.crossPartitionForSlice`), which cannot fail the
// way a boundary fails: a single slice always resolves, so the all-or-nothing
// fallback in `deriveEffectiveScope` — one unresolvable slice discarding the
// derived scope for every slice beside it — has no per-slice symptom at all. The
// slices keep passing their own tests and the platform rejects valid commands.
//
// Takes the generated `<Plugin>.Plugin.dcbSliceSchemas`, so it asserts over the
// boundary as deployed rather than over the steps a given flow happens to name.
let thenBoundaryScopeResolves = async (
  flowP: flow,
  ~name: string,
  slices: array<Reventless.DcbTag.sliceSchemas>,
) => {
  let s = await flowP->enter(~verb="thenBoundaryScopeResolves")
  let scope = Reventless.DcbTag.deriveEffectiveScope(slices)
  // Deploy and boot derive the storage partition from the same slices and refuse
  // the boundary when it fails, so the test fails with their reasons.
  let partitionReasons = {
    let shapes = slices->Array.map(Reventless.DcbTag.sliceShape)
    let hints = Reventless.DcbValidation.validatePartitionHintsVsInference(~shapes)
    let arms = Reventless.DcbValidation.validateCrossPartitionArms(
      ~shapes,
      ~inferred=Reventless.DcbScopeInference.infer(shapes),
    )
    let contradictions =
      hints.contradictions
      ->Array.concat(arms.contradictions)
      ->Array.map(e => `${e.sliceName}: ${e.message}`)
    switch Reventless.DcbTag.deriveBoundaryPartition(slices) {
    | _ => contradictions
    | exception JsExn(err) =>
      contradictions->Array.concat([
        JsExn.message(err)->Option.getOr("partition derivation failed"),
      ])
    }
  }
  // Beyond that, an ambiguity that costs nothing is not a failure: a boundary whose
  // fallback carries every derived key reads exactly as the derivation would. What
  // fails is losing a key, because that is the case where the runtime answers wrongly.
  let outcome = if partitionReasons->Array.length > 0 {
    Outcome.fail(PartitionUnresolved({boundary: name, reasons: partitionReasons}))
  } else if scope.droppedCrossPartitionTagKeys->Array.length > 0 {
    Outcome.fail(
      ScopeDegraded({
        boundary: name,
        dropped: scope.droppedCrossPartitionTagKeys,
        ambiguities: scope.ambiguities->Array.map(((slice, reason)) => `${slice}: ${reason}`),
      }),
    )
  } else {
    Outcome.pass
  }
  s->recordOutcome(outcome)
}

// -- What a decision returned ------------------------------------------------

let eventsWere = (s: flowState, expectedJson: array<JSON.t>) =>
  s->recordOutcome(
    switch s.lastError {
    | Some(err) =>
      Outcome.fail(
        ErrorMismatch({expected: JSON.Encode.null, actual: Some(err), actualEvents: s.lastEvents}),
      )
    | None =>
      s.lastEvents == expectedJson
        ? Outcome.pass
        : Outcome.fail(EventsMismatch({expected: expectedJson, actual: s.lastEvents}))
    },
  )

let errorWas = (s: flowState, expJson: JSON.t) =>
  s->recordOutcome(
    switch s.lastError {
    | None =>
      Outcome.fail(ErrorMismatch({expected: expJson, actual: None, actualEvents: s.lastEvents}))
    | Some(actual) =>
      actual == expJson
        ? Outcome.pass
        : Outcome.fail(
            ErrorMismatch({expected: expJson, actual: Some(actual), actualEvents: s.lastEvents}),
          )
    },
  )

let noEventWas = (s: flowState) =>
  s->recordOutcome(
    switch s.lastError {
    | Some(err) =>
      Outcome.fail(
        ErrorMismatch({expected: JSON.Encode.null, actual: Some(err), actualEvents: s.lastEvents}),
      )
    | None =>
      s.lastEvents->Array.length == 0
        ? Outcome.pass
        : Outcome.fail(NoEventExpected({actual: s.lastEvents}))
    },
  )

// The decision did not refuse; its events are not compared. For a flow written
// with no author present, whose worked-out values nobody has confirmed yet.
let acceptedWas = (s: flowState) =>
  s->recordOutcome(
    switch s.lastError {
    | Some(err) =>
      Outcome.fail(
        ErrorMismatch({expected: JSON.Encode.null, actual: Some(err), actualEvents: s.lastEvents}),
      )
    | None => Outcome.pass
    },
  )

// -- What the step before sent -----------------------------------------------

// The commands the step before sent, read by the decision that runs them: all of
// them, or the one `~only` names (the first is 1). Read strictly, so a command
// the decision cannot read fails here rather than being filled in.
let issued = (s: flowState, ~only=?, ~name, schema: S.t<'c>): result<array<'c>, string> => {
  let sent = s.lastCommands
  let picked = switch only {
  | None => Ok(sent)
  | Some(n) =>
    switch sent->Array.get(n - 1) {
    | Some(c) => Ok([c])
    | None =>
      Error(
        `~only=${n->Int.toString}, but ${sent->Array.length->Int.toString} command(s) were sent`,
      )
    }
  }
  picked->Result.flatMap(sent =>
    sent->Array.length == 0
      ? Error("the step before sent no command")
      : sent->Array.reduce(Ok([]), (acc, json) =>
          acc->Result.flatMap(
            commands =>
              switch json->Reventless.Util_Sury.fromJson(schema) {
              | command => Ok(commands->Array.concat([command]))
              | exception S.Exn(e) =>
                Error(`${name} cannot read ${JSON.stringify(json)}: ${e.message}`)
              | exception _ => Error(`${name} cannot read ${JSON.stringify(json)}`)
              },
          )
        )
  )
}

// Run the sent commands in order. The step's events are all of theirs; the
// first refusal ends it.
let runIssued = (s: flowState, commands: result<array<'c>, string>, decideOne) =>
  switch commands {
  | Error(reason) =>
    {...s, lastEvents: [], lastError: None}->recordOutcome(
      Outcome.fail(
        TranslateError({expected: "a command the decision reads", actual: Some(reason)}),
      ),
    )
  | Ok(commands) =>
    commands->Array.reduce({...s, lastEvents: [], lastError: None}, (acc, command) =>
      switch acc.lastError {
      | Some(_) => acc
      | None =>
        let next = acc->decideOne(command)
        {...next, lastEvents: acc.lastEvents->Array.concat(next.lastEvents)}
      }
    )
  }

// -- DecisionStep: a StateChangeSlice / Aggregate decider ---------------------

module DecisionStep = (
  Spec: Decision_GWT.DecisionSpec,
  Decision: Decision_GWT.Decision with module Spec := Spec,
) => {
  let part: Outcome.part = {kind: Decision, name: Spec.name}
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
  let consumedEventTypes = consumedDecoder.eventTypes

  // Seed prior history with events this slice can emit.
  let givenEvents = async (flowP: flow, ~at=?, events: array<Spec.event>) => {
    let s = await flowP->enter(~verb="givenEvents", ~part, ~at?)
    {...s, log: s.log->appendEvents(~at=s.now, events, Spec.eventSchema)}
  }

  // Filter the log by the command's DCB tags, fold `evolve`, run `decide`, and
  // append the emitted events back onto the shared log.
  // Scope derived from this slice's schemas, mirroring the StateChangeSlice runtime:
  // cross-partition keys (explicit @crossPartition ∪ per-slice inference) fan a
  // foreign reference into its own clause, and the per-event indexed-tag map narrows
  // a foreign reference on this slice's own emitted event out of that clause (so the
  // real tagged log here does not return sibling entities).
  let scopeShape = Reventless.DcbTag.sliceShapeFromSchemas(
    ~name="",
    ~commandSchema=Spec.commandSchema,
    ~consumedEventSchema=Spec.consumedEventSchema,
    ~eventSchema=Spec.eventSchema,
  )
  let crossPartitionTagKeys = {
    let set = Set.make()
    Reventless.DcbTag.extractCrossPartitionTagKeys(Spec.eventSchema)->Array.forEach(k =>
      set->Set.add(k)
    )
    Reventless.DcbScopeInference.crossPartitionForSlice(scopeShape)->Array.forEach(k =>
      set->Set.add(k)
    )
    Array.fromIterator(set->Set.values)->Array.toSorted((a, b) => String.compare(a, b))
  }
  let tagKeysByEventType = Reventless.DcbScopeInference.infer([scopeShape]).tagKeysByEventType
  // Command keys this slice does not decide by stay out of the query (rule 4),
  // judged against the partition the slice resolves to on its own.
  let payloadTagKeys = scopeShape->Reventless.DcbTag.commandPayloadTagKeys(
    ~partitionTag=Reventless.DcbScopeInference.resolvePartitions([scopeShape]).partitionBySlice
    ->Dict.get("")
    ->Option.map(key => Reventless.DcbTag.Simple({key: key})),
    ~crossPartitionTagKeys,
  )

  let decideOne = (s: flowState, command: Spec.command) => {
    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=consumedEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command,
      ~tagKeysByEventType,
      ~crossPartitionTagKeys,
      ~payloadTagKeys,
    )
    let history = decodeMatching(s.log, consumedDecoder, query)
    let state = history->Array.reduce(Decision.initialState, Decision.evolve)
    switch Decision.decide(state, command) {
    | Ok(events) => {
        ...s,
        log: s.log->appendEvents(~at=s.now, events, Spec.eventSchema),
        lastEvents: events->Array.map(e => e->Message.encode(Spec.eventSchema)),
        lastError: None,
        lastAggregateId: None,
      }
    | Error(error) => {
        ...s,
        lastEvents: [],
        lastError: Some(error->Message.encode(Spec.errorSchema)),
        lastAggregateId: None,
      }
    }
  }

  let whenCommand = async (flowP: flow, ~at=?, command: Spec.command) =>
    (await flowP->enter(~verb="whenCommand", ~part, ~at?))->decideOne(command)

  // Runs the commands the step before sent, as this decision reads them.
  let whenIssued = async (flowP: flow, ~only=?, ~at=?) => {
    let s = await flowP->enter(~verb="whenIssued", ~part, ~at?)
    s->runIssued(s->issued(~only?, ~name=Spec.name, Spec.commandSchema), decideOne)
  }

  let thenEvents = async (flowP: flow, expected: array<Spec.event>) =>
    (await flowP->enter(~verb="thenEvents", ~part))->eventsWere(
      expected->Array.map(e => e->Message.encode(Spec.eventSchema)),
    )

  let thenEvent = async (flowP: flow, event: Spec.event) =>
    (await flowP->enter(~verb="thenEvent", ~part))->eventsWere([
      event->Message.encode(Spec.eventSchema),
    ])

  let thenError = async (flowP: flow, expected: Spec.error) =>
    (await flowP->enter(~verb="thenError", ~part))->errorWas(
      expected->Message.encode(Spec.errorSchema),
    )

  let thenNoEvent = async (flowP: flow) =>
    (await flowP->enter(~verb="thenNoEvent", ~part))->noEventWas

  let thenAccepted = async (flowP: flow) =>
    (await flowP->enter(~verb="thenAccepted", ~part))->acceptedWas
}

// -- AggregateStep: an Aggregate decider partitioned by aggregate-ID --
//
// Mirror of `DecisionStep` for `Reventless.Decision.T` (the aggregate-flavor
// decision). Differences from the slice form:
//   * No `consumedEvent` distinction — aggregates fold their own `event`
//     stream; the decoder uses `Spec.eventSchema`.
//   * No DCB tag inference — `~id` partitions the history. `givenEvents` and
//     `whenCommand` both take `~id`, and the emitted events are stamped with
//     the same `id` on the shared log so a subsequent step can read them
//     back.
//
// Sequencing two aggregate steps for the same `~id` rebuilds the running
// state across the chain; sequencing them for different `~id` keeps their
// histories isolated (a `Place` on `o2` does not see the events of `o1`).

module AggregateStep = (
  Spec: Decision_GWT.AggregateDeciderSpec,
  Decision: Reventless.Decision.T with module Spec = Spec,
) => {
  let part: Outcome.part = {kind: Aggregate, name: Spec.name}
  let aggregateDecoder = Reventless.DcbDecode.makeDecoder(Spec.eventSchema)

  // Seed `id`'s history before the first `whenCommand`. Useful when a flow
  // starts mid-stream (e.g. the order is already Placed when the test begins).
  let givenEvents = async (flowP: flow, ~id: string, ~at=?, events: array<Spec.event>) => {
    let s = await flowP->enter(~verb="givenEvents", ~part, ~at?)
    {...s, log: s.log->appendAggregateEvents(~id, ~at=s.now, events, Spec.eventSchema)}
  }

  // Rebuild `id`'s state from the log, run `decide`, then either append the
  // emitted events (still tagged with `~id`) or remember the error for the
  // next `thenError`.
  let decideOne = (s: flowState, ~id: string, command: Spec.command) => {
    let history = decodeAggregateMatching(s.log, ~id, aggregateDecoder)
    let state = history->Array.reduce(Decision.initialState, Decision.evolve)
    switch Decision.decide(state, command) {
    | Ok(events) => {
        ...s,
        log: s.log->appendAggregateEvents(~id, ~at=s.now, events, Spec.eventSchema),
        lastEvents: events->Array.map(e => e->Message.encode(Spec.eventSchema)),
        lastError: None,
        lastAggregateId: Some(id),
      }
    | Error(error) => {
        ...s,
        lastEvents: [],
        lastError: Some(error->Message.encode(Spec.errorSchema)),
        lastAggregateId: Some(id),
      }
    }
  }

  let whenCommand = async (flowP: flow, ~id: string, ~at=?, command: Spec.command) =>
    (await flowP->enter(~verb="whenCommand", ~part, ~at?))->decideOne(~id, command)

  // Runs the commands the step before sent, as this aggregate reads them.
  let whenIssued = async (flowP: flow, ~id: string, ~only=?, ~at=?) => {
    let s = await flowP->enter(~verb="whenIssued", ~part, ~at?)
    s->runIssued(s->issued(~only?, ~name=Spec.name, Spec.commandSchema), (s, c) =>
      s->decideOne(~id, c)
    )
  }

  let thenEvents = async (flowP: flow, expected: array<Spec.event>) =>
    (await flowP->enter(~verb="thenEvents", ~part))->eventsWere(
      expected->Array.map(e => e->Message.encode(Spec.eventSchema)),
    )

  let thenEvent = async (flowP: flow, event: Spec.event) =>
    (await flowP->enter(~verb="thenEvent", ~part))->eventsWere([
      event->Message.encode(Spec.eventSchema),
    ])

  let thenNoEvent = async (flowP: flow) =>
    (await flowP->enter(~verb="thenNoEvent", ~part))->noEventWas

  let thenAccepted = async (flowP: flow) =>
    (await flowP->enter(~verb="thenAccepted", ~part))->acceptedWas

  let thenError = async (flowP: flow, expected: Spec.error) =>
    (await flowP->enter(~verb="thenError", ~part))->errorWas(
      expected->Message.encode(Spec.errorSchema),
    )
}

// -- ViewStep: a StateViewSlice / projection over the log --------------------

// The view step's former verbs, kept only so that a flow using one fails to
// build with a message naming the new verb.
type renamedToThenRow
type renamedToThenRows

module ViewStep = (
  Spec: Projection_GWT.Spec,
  Projection: Projection_GWT.Projection with module Spec := Spec,
) => {
  module P = Projection_GWT.Make(Spec, Projection)
  let part: Outcome.part = {kind: View, name: Spec.name}
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

  let encState = (st: Spec.state) => st->Message.encode(Spec.stateSchema)

  // Fold the projection over every consumed event in the log: the row(s) for `id`.
  // Each event projected at the time it was recorded.
  let rowsOf = async (s: flowState, id) => {
    let events =
      s.log->Array.flatMap(entry =>
        decodeMatching([entry], consumedDecoder, [])->Array.map(e => (e, iso(entry.at)))
      )
    let store = await P.givenEventsAt(events)
    store->Dict.get(id)->Option.getOr([])
  }

  let compared = (s: flowState, id, ~expected: array<JSON.t>, ~actual: array<JSON.t>) =>
    s->recordOutcome(
      actual == expected
        ? Outcome.pass
        : Outcome.fail(
            StateMismatch({
              key: id,
              expected: Some(JSON.Encode.array(expected)),
              actual: Some(JSON.Encode.array(actual)),
              fold: Project,
            }),
          ),
    )

  let rowsAre = async (s: flowState, id, expected: array<Spec.state>) =>
    s->compared(
      id,
      ~expected=expected->Array.map(encState),
      ~actual=(await s->rowsOf(id))->Array.map(encState),
    )

  let thenRows = async (flowP: flow, id, expected: array<Spec.state>) =>
    await (await flowP->enter(~verb="thenRows", ~part))->rowsAre(id, expected)
  let thenRow = async (flowP: flow, id, row: Spec.state) =>
    await (await flowP->enter(~verb="thenRow", ~part))->rowsAre(id, [row])

  let thenNoRow = async (flowP: flow, id) =>
    await (await flowP->enter(~verb="thenNoRow", ~part))->rowsAre(id, [])

  // Some fields of the row: `pick` takes them from the row as built, and they
  // are compared with `expected`. A field `pick` leaves out is built and not
  // compared; the view's own test states the whole row.
  let thenRowShows = async (flowP: flow, id, pick: Spec.state => 'shown, expected: 'shown) => {
    let s = await flowP->enter(~verb="thenRowShows", ~part)
    let shown = (await s->rowsOf(id))->Array.map(pick)
    // What `pick` returns has no schema; it is shown as the value it is.
    let asJson = (v: 'shown): JSON.t => Obj.magic(v)
    shown == [expected]
      ? s->recordOutcome(Outcome.pass)
      : s->compared(id, ~expected=[asJson(expected)], ~actual=shown->Array.map(asJson))
  }

  @deprecated("Renamed thenRow.")
  let thenViewState = (_: renamedToThenRow, _: renamedToThenRow, _: renamedToThenRow) => ()
  @deprecated("Renamed thenRows.")
  let thenViewStates = (_: renamedToThenRows, _: renamedToThenRows, _: renamedToThenRows) => ()
}

// -- Automation, way out, way in ---------------------------------------------
//
// Each takes the slice as written: its `Spec` and its body. The log keeps no
// source name, so every mapping is offered every entry; the source id is the
// producing aggregate's, or "" for a DCB event, which names its own subject.

let sourceIdOf = (entry: logEntry) => entry.aggregateId->Option.getOr("")

let encodedCommandsMatch = (s: flowState, expJson: array<JSON.t>) => {
  let o = switch s.lastRefusal {
  | Some(reason) => Outcome.fail(TranslateError({expected: "(commands)", actual: Some(reason)}))
  | None =>
    s.lastCommands == expJson
      ? Outcome.pass
      : Outcome.fail(EventsMismatch({expected: expJson, actual: s.lastCommands}))
  }
  s->recordOutcome(o)
}

module AutomationStep = (
  Spec: Reventless.AutomationSlice.Spec,
  Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
) => {
  module A = Automation_GWT.FromSlice(Spec, Automation)
  let part: Outcome.part = {kind: Automation, name: Spec.name}

  // Each entry routed as the runtime delivers it, recorded at its own time.
  let routedLog = (s: flowState) =>
    s.log->Array.map(entry => (
      entry,
      A.Route.dispatches->Array.filterMap(d =>
        d.handle(
          entry.json,
          ~sourceId=entry->sourceIdOf,
          A.testContext->A.withRecordedAt(Some(entry.at)),
        )
      ),
    ))

  let sent = (s: flowState, commands: array<(string, Spec.command)>) => {
    ...s,
    lastCommands: commands->Array.map(((_id, cmd)) => cmd->Message.encode(Spec.commandSchema)),
    lastRefusal: None,
  }

  // The automation sweeps the record at the flow's time.
  let whenReacts = async (flowP: flow, ~at=?) => {
    let s = await flowP->enter(~verb="whenReacts", ~part, ~at?)
    let routed = s->routedLog->Array.flatMap(((_, routed)) => routed)
    s->sent(A.sweep(routed, ~now=s.now).commands)
  }

  // The flow's time moves to `until`, and every schedule that comes due on the
  // way fires in turn: the declared one, and those the record's events set. The
  // commands the firings make are what the step sent.
  let whenTimePasses = async (flowP: flow, ~until) => {
    let from = (await flowP).now
    let s = await flowP->enter(~verb="whenTimePasses", ~part, ~at=until)
    switch s.outcome {
    | Error(_) => s
    | Ok() =>
      let log = s->routedLog
      let rows = A.declaredRows(~now=0.0)
      log->Array.forEach(((entry, routed)) =>
        routed->Array.forEach(r =>
          r.rescheduled->Array.forEach(
            change =>
              rows
              ->AutomationSlice_Schedules.apply(change, ~setBy="flow", ~recordedAt=entry.at)
              ->ignore,
          )
        )
      )
      let firings =
        rows
        ->Dict.valuesToArray
        ->Array.flatMap(row =>
          switch row->AutomationSlice_Schedules.timeOf {
          | None => []
          | Some(time) =>
            let rec due = (after, acc, tries) =>
              switch time->ScheduleTime.nextFiring(~after) {
              | Some(next) if next <= s.now && tries < 1000 =>
                due(next, acc->Array.concat([(row.key, next)]), tries + 1)
              | _ => acc
              }
            due(from, [], 0)
          }
        )
        ->Array.toSorted(((_, a), (_, b)) => Float.compare(a, b))
      let ticks =
        A.routeEach(
          firings->Array.map(((key, at)) => A.tick(~key, at)),
          A.testContext,
        )->Array.flatMap(((_, routed)) => routed)
      let fromLog = log->Array.flatMap(((_, routed)) => routed)
      let before = A.sweep(fromLog, ~now=s.now).commands
      let after = A.sweep(fromLog->Array.concat(ticks), ~now=s.now).commands
      s->sent(after->Array.filter(c => !(before->Array.some(b => b == c))))
    }
  }

  let issued = async (flowP: flow, ~verb, expected: array<Spec.command>) =>
    (await flowP->enter(~verb, ~part))->encodedCommandsMatch(
      expected->Array.map(c => c->Message.encode(Spec.commandSchema)),
    )
  let thenIssuesCommands = (flowP, expected) => issued(flowP, ~verb="thenIssuesCommands", expected)
  let thenIssuesCommand = (flowP, command) => issued(flowP, ~verb="thenIssuesCommand", [command])
  let thenIssuesNoCommand = flowP => issued(flowP, ~verb="thenIssuesNoCommand", [])
}

module OutboundStep = (
  Spec: Reventless.OutboundTranslationSlice.Spec,
  Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
) => {
  let part: Outcome.part = {kind: Outbound, name: Spec.name}
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

  let encItems = (arr: array<(string, Spec.outboundItem)>) =>
    arr->Array.map(((id, item)) => (id, item->Message.encode(Spec.outboundItemSchema)))

  // Asserts what `collect` queues; `translate` is the slice test's to run.
  let outbound = async (flowP: flow, ~verb, expected: array<(string, Spec.outboundItem)>) => {
    let s = await flowP->enter(~verb, ~part)
    let collected =
      s.log->Array.flatMap(entry =>
        decodeMatching([entry], consumedDecoder, [])->Array.flatMap(e =>
          Translation.collect(e, ~sourceId=entry->sourceIdOf)
        )
      )
    let actual = encItems(collected)
    let expectedJson = encItems(expected)
    let o =
      actual == expectedJson
        ? Outcome.pass
        : Outcome.fail(TodoMismatch({expected: expectedJson, actual}))
    s->recordOutcome(o)
  }

  let thenOutbound = (flowP, expected) => outbound(flowP, ~verb="thenOutbound", expected)
  let thenOutboundNothing = flowP => outbound(flowP, ~verb="thenOutboundNothing", [])
}

module InboundStep = (
  Spec: Reventless.InboundTranslationSlice.Spec,
  Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
) => {
  module I = InboundTranslation_GWT.FromSlice(Spec, Translation)
  let part: Outcome.part = {kind: Inbound, name: Spec.name}

  // Received input becomes the flow's next commands, as an automation's do.
  let whenReceived = async (flowP: flow, ~at=?, json: JSON.t, ~fakes=?) => {
    let s = await flowP->enter(~verb="whenReceived", ~part, ~at?)
    switch (await I.whenReceived(json, ~fakes?)).outcome {
    | Translated(pairs) => {
        ...s,
        lastCommands: pairs->Array.map(((_id, cmd)) => cmd->Message.encode(Spec.commandSchema)),
        lastRefusal: None,
      }
    | NotUnderstood(msg) => {...s, lastCommands: [], lastRefusal: Some(`not understood: ${msg}`)}
    | InputRefused(msg) => {...s, lastCommands: [], lastRefusal: Some(`input refused: ${msg}`)}
    }
  }

  let issued = async (flowP: flow, ~verb, expected: array<Spec.command>) =>
    (await flowP->enter(~verb, ~part))->encodedCommandsMatch(
      expected->Array.map(c => c->Message.encode(Spec.commandSchema)),
    )
  let thenIssuesCommands = (flowP, expected) => issued(flowP, ~verb="thenIssuesCommands", expected)
  let thenIssuesCommand = (flowP, command) => issued(flowP, ~verb="thenIssuesCommand", [command])
  let thenIssuesNoCommand = flowP => issued(flowP, ~verb="thenIssuesNoCommand", [])
}

// -- Across plugins ----------------------------------------------------------

// An extension point is named under its system (`Catalog.Products`); its part
// is the last segment, as the steps file names it.
let portName = (name: string) => name->String.split(".")->Array.at(-1)->Option.getOr(name)

// Order-independent comparison for published actions — fan-out order is
// non-deterministic, so compare sorted by stringified JSON.
let sortJson = (arr: array<JSON.t>) =>
  arr->Array.toSorted((a, b) => String.compare(JSON.stringify(a), JSON.stringify(b)))

// ExtensionPointStep: runs an EP mapping's `mapOutgoingEvent` over the events
// the last command step produced, turning internal events into the public
// extension-point events the next plugin subscribes to (handles one-to-many
// fan-out). The public events are appended to the shared log and remembered
// for `thenPublicEvent(s)` / the following `ExtensionStep`.
module ExtensionPointStep = (M: EPMapping.Mapping) => {
  let part: Outcome.part = {kind: ExtensionPoint, name: portName(M.ExtensionPoint.name)}
  let delegateDecoder = Reventless.DcbDecode.makeDecoder(M.Delegate.eventSchema)

  // Aggregate-style EP mappings address the source aggregate's identity via
  // the first arg (e.g. catalog Product → ProductBecameAvailable uses it as
  // `productId`). DCB upstreams don't set `lastAggregateId` and fall back to
  // the synthetic `gwt-id` so existing DCB Flow tests keep their behavior.
  let runMapping = async (sourceId: string, events: array<M.Delegate.event>): array<
    M.ExtensionPoint.event,
  > =>
    switch M.mapOutgoingEvent {
    | None => []
    | Some(f) =>
      let actions =
        events
        ->Array.map(ev => f(sourceId, ev, StubRuntime.meta, StubRuntime.queryEngine))
        ->Array.flat
      let nested = await actions
      ->Array.map(async action =>
        switch action {
        | EPMapping.PublishEvent(_id, e) => [e]
        | EPMapping.PublishEventAsync(p) =>
          let (_id, e) = await p
          [e]
        | EPMapping.HandleDirective(_, _) => []
        }
      )
      ->Promise.all
      nested->Array.flat
    }

  let whenPublished = async (flowP: flow, ~at=?) => {
    let s = await flowP->enter(~verb="whenPublished", ~part, ~at?)
    let delegateEvents = s.lastEvents->Array.filterMap(json => {
      let data = switch json {
      | Object(d) => d
      | _ => Dict.make()
      }
      delegateDecoder.decode(~eventType=json->Reventless.Message.variantNameOfJson, ~data)
    })
    let sourceId = s.lastAggregateId->Option.getOr("gwt-id")
    let publicEvents = await runMapping(sourceId, delegateEvents)
    {
      ...s,
      log: s.log->appendEvents(~at=s.now, publicEvents, M.ExtensionPoint.eventSchema),
      lastPublic: publicEvents->Array.map(e => e->Message.encode(M.ExtensionPoint.eventSchema)),
    }
  }

  let published = async (flowP: flow, ~verb, expected: array<M.ExtensionPoint.event>) => {
    let s = await flowP->enter(~verb, ~part)
    let expJson = expected->Array.map(e => e->Message.encode(M.ExtensionPoint.eventSchema))
    let o =
      sortJson(s.lastPublic) == sortJson(expJson)
        ? Outcome.pass
        : Outcome.fail(PublishedActionsMismatch({expected: expJson, actual: s.lastPublic}))
    s->recordOutcome(o)
  }

  let thenPublicEvents = (flowP, expected) => published(flowP, ~verb="thenPublicEvents", expected)
  let thenPublicEvent = (flowP, event) => published(flowP, ~verb="thenPublicEvent", [event])
}

// ExtensionStep: runs an Extension delegate's `mapIncomingEvent` over the public
// EP events the last ExtensionPoint step produced, surfacing the commands the
// extension issues onto its own plugin's slices. The next `DecisionStep` then
// executes the asserted command.
module ExtensionStep = (M: ExtMapping.Mapping) => {
  let part: Outcome.part = {kind: Extension, name: portName(M.ExtensionPoint.name)}
  let epDecoder = Reventless.DcbDecode.makeDecoder(M.ExtensionPoint.eventSchema)
  let encCmd = (c: M.Delegate.command) => c->Message.encode(M.Delegate.commandSchema)

  let whenReacts = async (flowP: flow, ~at=?) => {
    let s = await flowP->enter(~verb="whenReacts", ~part, ~at?)
    let epEvents = s.lastPublic->Array.filterMap(json => {
      let data = switch json {
      | Object(d) => d
      | _ => Dict.make()
      }
      epDecoder.decode(~eventType=json->Reventless.Message.variantNameOfJson, ~data)
    })
    let actions =
      epEvents
      ->Array.map(ev =>
        M.mapIncomingEvent(
          "gwt-id",
          ev,
          StubRuntime.meta,
          StubRuntime.pluginDefinition,
          StubRuntime.queryEngine,
        )
      )
      ->Array.flat
    let nested = await actions
    ->Array.map(async action =>
      switch action {
      | ExtMapping.PublishStateChangeSliceCommand(cmd) => [encCmd(cmd)]
      | ExtMapping.PublishStateChangeSliceCommandAsync(p) =>
        let cmd = await p
        [encCmd(cmd)]
      | ExtMapping.PublishStateChangeSliceCommandsAsync(p) => (await p)->Array.map(encCmd)
      | ExtMapping.PublishAggregateCommand(_id, cmd) => [encCmd(cmd)]
      | ExtMapping.PublishAggregateCommandAsync(p) =>
        let (_id, cmd) = await p
        [encCmd(cmd)]
      | ExtMapping.PublishAggregateCommandsAsync(p) =>
        (await p)->Array.map(((_id, cmd)) => encCmd(cmd))
      | ExtMapping.PublishExtensionPointCommand(_, _)
      | ExtMapping.ForwardCommand(_)
      | ExtMapping.HandleDirective(_, _) => []
      }
    )
    ->Promise.all
    {...s, lastCommands: nested->Array.flat}
  }

  let issued = async (flowP: flow, ~verb, expected: array<M.Delegate.command>) => {
    let s = await flowP->enter(~verb, ~part)
    let expJson = expected->Array.map(encCmd)
    let o =
      sortJson(s.lastCommands) == sortJson(expJson)
        ? Outcome.pass
        : Outcome.fail(PublishedActionsMismatch({expected: expJson, actual: s.lastCommands}))
    s->recordOutcome(o)
  }

  let thenIssuesCommands = (flowP, expected) => issued(flowP, ~verb="thenIssuesCommands", expected)
  let thenIssuesCommand = (flowP, command) => issued(flowP, ~verb="thenIssuesCommand", [command])
  let thenIssuesNoCommand = flowP => issued(flowP, ~verb="thenIssuesNoCommand", [])
}

// -- Old names ---------------------------------------------------------------
//
// Each old step name stays for one release so that a flow using it fails to
// build with a message naming the new step. None of them runs.

type renamedToDecisionStep
type renamedToAggregateStep
type renamedToAutomationStep
type renamedToOutboundStep
type renamedToInboundStep

module type RenamedToDecisionStep = {
  type renamedToDecisionStep = renamedToDecisionStep
}
module type RenamedToAggregateStep = {
  type renamedToAggregateStep = renamedToAggregateStep
}
module type RenamedToAutomationStep = {
  type renamedToAutomationStep = renamedToAutomationStep
}
module type RenamedToOutboundStep = {
  type renamedToOutboundStep = renamedToOutboundStep
}
module type RenamedToInboundStep = {
  type renamedToInboundStep = renamedToInboundStep
}

@deprecated("Renamed DecisionStep.")
module CommandStep = (_: RenamedToDecisionStep, _: RenamedToDecisionStep) => {}
@deprecated("Renamed AggregateStep.")
module AggregateCommandStep = (_: RenamedToAggregateStep, _: RenamedToAggregateStep) => {}
@deprecated("Renamed AutomationStep.")
module AutomationSlice = (_: RenamedToAutomationStep, _: RenamedToAutomationStep) => {}
@deprecated("Renamed OutboundStep.")
module OutboundSlice = (_: RenamedToOutboundStep, _: RenamedToOutboundStep) => {}
@deprecated("Renamed InboundStep.")
module InboundSlice = (_: RenamedToInboundStep, _: RenamedToInboundStep) => {}
