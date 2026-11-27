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

// Who acts in a flow: `Caller.owner(c1)`, `Caller.inRoles([…])`, `Caller.operator`.
module Caller = Decision_GWT.Caller

// What stands in for the outside services a way out reaches: `Fakes.make(…)`.
module Fakes = Capabilities_Fake

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
  // The id the event was recorded under, which every part that reacts to it is
  // given as its source id: an aggregate's id; a public event's, the one its
  // mapping published it with; a DCB event's, the value of its first indexed
  // tag, as the local runtime records it.
  id: string,
}

let sourceIdOf = (entry: logEntry) => entry.id

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
  // The ids `lastEvents` were recorded under, in order: what an extension point
  // mapping is given for each, as the runtime gives it.
  lastIds: array<string>,
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
  // Who takes the steps a person takes, from `asCaller` on; none is the
  // platform acting for itself.
  caller: option<Caller.t>,
  // The last command was refused before its decision ran: by its rule, or
  // because the caller does not own what it acts on.
  lastForbidden: bool,
  // What each reacting part has already reacted to, by part: an automation's
  // to-do items, an extension's entries of the record. A reaction reports what
  // is new since then.
  handled: dict<array<string>>,
  // The reacting parts the flow named, by key.
  named: array<string>,
  // What the last way out asked of the outside services it stands for.
  lastSent: array<Capabilities_Fake.call>,
  // The rows the last query returned, and what the last side effect did.
  lastRows: array<JSON.t>,
  lastCalls: array<JSON.t>,
}

// One command a reacting part sends, and the part it is meant for when it says.
type reaction = {target: option<string>, command: JSON.t}

// A part that reacts to the record: what it sends that it has not sent yet,
// and the flow with that marked as sent.
type reacting = {
  key: string,
  part: Outcome.part,
  react: flowState => promise<(flowState, array<reaction>)>,
}

// A part that decides: runs a sent command when it reads it, as the platform.
type deciding = {
  name: string,
  run: (flowState, JSON.t) => option<flowState>,
}

// A system's reacting and deciding parts, as its generated `Flow` module lists
// them.
type parts = {reacting: array<reacting>, deciding: array<deciding>}

let handledBy = (s: flowState, key) => s.handled->Dict.get(key)->Option.getOr([])

let markHandled = (s: flowState, key, ids: array<string>) => {
  let handled = s.handled->Dict.copy
  handled->Dict.set(key, s->handledBy(key)->Array.concat(ids))
  {...s, handled}
}

let markNamed = (s: flowState, key) =>
  s.named->Array.includes(key) ? s : {...s, named: s.named->Array.concat([key])}

type flow = promise<flowState>

let emptyState = {
  log: [],
  outcome: Outcome.pass,
  lastEvents: [],
  lastError: None,
  lastCommands: [],
  lastPublic: [],
  lastIds: [],
  lastRefusal: None,
  steps: 0,
  at: None,
  failedAt: None,
  now: 0.0,
  caller: None,
  lastForbidden: false,
  handled: Dict.make(),
  named: [],
  lastSent: [],
  lastRows: [],
  lastCalls: [],
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
      // Every event carries its kind tag, so a whole read finds it whoever wrote it.
      let tagMatch = switch qi.tags {
      | Some(tags) =>
        tags->Array.every(tag =>
          (tag.key == Reventless.DcbTag.kindTagKey && tag.value == entry.eventType) ||
            entry.tags->Array.some(et => et.key == tag.key && et.value == tag.value)
        )
      | None => true
      }
      typeMatch && tagMatch
    })
  }

// One event as an entry of the log, encoded and tagged, recorded at `at` under
// the id `~id`, or the aggregate's, or the value of its first tag `~tagKeys`
// indexes for its type (any tag when no keys are given).
let entryOf = (
  ev: 'e,
  schema: S.t<'e>,
  ~at: float,
  ~aggregateId=?,
  ~id=?,
  ~tagKeys: option<dict<array<string>>>=?,
): logEntry => {
  let json = ev->Message.encode(schema)
  let eventType = json->Reventless.Message.variantNameOfJson
  let tags = Reventless.DcbTag.extractTagsExpanded(schema, ev)
  let indexed = switch tagKeys->Option.flatMap(keys => keys->Dict.get(eventType)) {
  | Some(keys) => tags->Array.filter(t => keys->Array.includes(t.key))
  | None => tags
  }
  {
    eventType,
    tags,
    json,
    aggregateId,
    at,
    id: switch (id, aggregateId) {
    | (Some(id), _) | (None, Some(id)) => id
    | (None, None) => indexed->Array.get(0)->Option.mapOr("", t => t.value)
    },
  }
}

// Encode + tag a batch of typed events and append them to the log.
let appendEvents = (
  log: array<logEntry>,
  ~at: float,
  ~tagKeys=?,
  events: array<'e>,
  schema: S.t<'e>,
): array<logEntry> =>
  Array.concat(log, events->Array.map(ev => entryOf(ev, schema, ~at, ~tagKeys?)))

// Aggregate-style append: the producing aggregate's id is the entry's, and the
// authoritative filter for aggregate consumers.
let appendAggregateEvents = (
  log: array<logEntry>,
  ~id: string,
  ~at: float,
  events: array<'e>,
  schema: S.t<'e>,
): array<logEntry> =>
  Array.concat(log, events->Array.map(ev => entryOf(ev, schema, ~at, ~aggregateId=id)))

// The ids the last `n` entries were recorded under.
let lastIdsOf = (log: array<logEntry>, n) =>
  log->Array.slice(~start=log->Array.length - n)->Array.map(e => e.id)

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

// The groups whose members read every row and act for anyone, as a deployment
// names them. A flow's test gives them (`~elevated`); none by default.
let elevated: ref<array<string>> = ref([])

// This file's flows, by the title of their test, so that one can start after
// another.
let flows: dict<unit => flow> = Dict.make()

// The chain returns a `flow`; `test` awaits it and reports its outcome. Bodies
// read top-to-bottom and end on the last `then*`. `~tells` names what the flow
// tells, for a reader of its steps file; the flow itself does nothing with it.
let test = (
  name,
  ~tells as _: option<string>=?,
  ~elevated as groups: array<string>=[],
  ~timeout=?,
  body: unit => flow,
) => {
  flows->Dict.set(name, body)
  JestBind.testPromise(~slice="Flow", name, ~timeout?, async () => {
    elevated := groups
    let outcome = outcomeOf(await body())
    elevated := []
    outcome
  })
}

// In place of `start`: the record and the time where the flow titled `title`,
// in this file, ended. That flow must pass; if it fails, this one is not run,
// and says so rather than failing on what the other left undone.
let after = async (title: string): flowState => {
  let notRun = why => {...emptyState, outcome: Outcome.fail(Throw({error: why, stack: ""}))}
  switch flows->Dict.get(title) {
  | None => notRun(`after("${title}"): no flow of that title in this file`)
  | Some(body) =>
    let before = await body()
    switch outcomeOf(before) {
    | Error(_) => notRun(`not run: the flow it starts after, "${title}", failed`)
    | Ok() => {...emptyState, log: before.log, now: before.now, handled: before.handled}
    }
  }
}

// Who takes the steps a person takes from here on: commands are checked against
// their rule and the owners their history records, and a view shows only the
// rows this caller may read. What an automation or an extension sends is still
// run by the platform.
let asCaller = async (flowP: flow, who: Caller.t) => {
  ...await flowP->enter(~verb="asCaller"),
  caller: Some(who),
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

let forbiddenCode = Reventless.CommandOutcome.code(Forbidden)

let forbidden = (s: flowState, refusal: option<JSON.t>) => {
  ...s,
  lastEvents: [],
  lastError: refusal,
  lastForbidden: true,
}

let forbiddenWas = (s: flowState) =>
  s->recordOutcome(
    s.lastForbidden
      ? Outcome.pass
      : Outcome.fail(
          ErrorMismatch({
            expected: JSON.Encode.object(
              Dict.fromArray([("errorCode", JSON.Encode.string(forbiddenCode))]),
            ),
            actual: s.lastError,
            actualEvents: s.lastEvents,
          }),
        ),
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

  let historyFor = (s: flowState, command: Spec.command) =>
    decodeMatching(
      s.log,
      consumedDecoder,
      Reventless.DcbTag.buildQueryFromCommand(
        ~eventTypes=consumedEventTypes,
        ~schema=Spec.commandSchema,
        ~value=command,
        ~tagKeysByEventType,
        ~crossPartitionTagKeys,
        ~payloadTagKeys,
        ~wholeEventTypes=Reventless.DcbTag.wholeEventTypesOfSchema(Spec.consumedEventSchema),
      ),
    )

  module Guard = Decision_GWT.Acting({
    let name = Spec.name
    type history = Spec.consumedEvent
    let historySchema = Spec.consumedEventSchema
    type command = Spec.command
    let commandSchema = Spec.commandSchema
    type role = Spec.role
    let authorizationOf = Spec.authorizationOf
    let ownedById = false
  })

  let decideOne = (s: flowState, command: Spec.command) => {
    let history = s->historyFor(command)
    let state = history->Array.reduce(Decision.initialState, Decision.evolve)
    switch Decision.decide(state, command) {
    | Ok(events) =>
      let log =
        s.log->appendEvents(~at=s.now, ~tagKeys=tagKeysByEventType, events, Spec.eventSchema)
      {
        ...s,
        log,
        lastEvents: events->Array.map(e => e->Message.encode(Spec.eventSchema)),
        lastError: None,
        lastIds: log->lastIdsOf(events->Array.length),
        lastForbidden: false,
      }
    | Error(error) => {
        ...s,
        lastEvents: [],
        lastError: Some(error->Message.encode(Spec.errorSchema)),
        lastIds: [],
        lastForbidden: false,
      }
    }
  }

  // A person's command: refused before its decision runs, as the platform
  // refuses it, when the caller may not issue it.
  let whenCommand = async (flowP: flow, ~at=?, command: Spec.command) => {
    let s = await flowP->enter(~verb="whenCommand", ~part, ~at?)
    switch s.caller {
    | None => s->decideOne(command)
    | Some(who) =>
      Guard.asCaller(
        [],
        {...who, claim: who->Caller.claimWith(~elevated=elevated.contents)},
      )->ignore
      Guard.refuses(s->historyFor(command), command)
        ? s->forbidden(Guard.refusal.contents->Option.map(Guard.encRefusal))
        : s->decideOne(command)
    }
  }

  // Runs the commands the step before sent, as this decision reads them.
  let whenIssued = async (flowP: flow, ~only=?, ~at=?) => {
    let s = await flowP->enter(~verb="whenIssued", ~part, ~at?)
    s->runIssued(s->issued(~only?, ~name=Spec.name, Spec.commandSchema), decideOne)
  }

  let deciding: deciding = {
    name: Spec.name,
    run: (s, json) =>
      switch json->Reventless.Util_Sury.fromJson(Spec.commandSchema) {
      | command => Some(s->decideOne(command))
      | exception _ => None
      },
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

  let thenForbidden = async (flowP: flow) =>
    (await flowP->enter(~verb="thenForbidden", ~part))->forbiddenWas
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
  module Guard = Decision_GWT.Acting({
    let name = Spec.name
    type history = Spec.event
    let historySchema = Spec.eventSchema
    type command = Spec.command
    let commandSchema = Spec.commandSchema
    type role = Spec.role
    let authorizationOf = Spec.authorizationOf
    let ownedById = false
  })

  let decideOne = (s: flowState, ~id: string, command: Spec.command) => {
    let history = decodeAggregateMatching(s.log, ~id, aggregateDecoder)
    let state = history->Array.reduce(Decision.initialState, Decision.evolve)
    switch Decision.decide(state, command) {
    | Ok(events) => {
        ...s,
        log: s.log->appendAggregateEvents(~id, ~at=s.now, events, Spec.eventSchema),
        lastEvents: events->Array.map(e => e->Message.encode(Spec.eventSchema)),
        lastError: None,
        lastIds: events->Array.map(_ => id),
        lastForbidden: false,
      }
    | Error(error) => {
        ...s,
        lastEvents: [],
        lastError: Some(error->Message.encode(Spec.errorSchema)),
        lastIds: [],
        lastForbidden: false,
      }
    }
  }

  let whenCommand = async (flowP: flow, ~id: string, ~at=?, command: Spec.command) => {
    let s = await flowP->enter(~verb="whenCommand", ~part, ~at?)
    switch s.caller {
    | None => s->decideOne(~id, command)
    | Some(who) =>
      Guard.asCaller(
        [],
        {...who, claim: who->Caller.claimWith(~elevated=elevated.contents)},
      )->ignore
      Guard.refuses(decodeAggregateMatching(s.log, ~id, aggregateDecoder), command)
        ? s->forbidden(Guard.refusal.contents->Option.map(Guard.encRefusal))
        : s->decideOne(~id, command)
    }
  }

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

  let thenForbidden = async (flowP: flow) =>
    (await flowP->enter(~verb="thenForbidden", ~part))->forbiddenWas

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
    let rows = store->Dict.get(id)->Option.getOr([])
    switch s.caller {
    | None => rows
    | Some(who) => rows->P.readableBy(who, ~elevated=elevated.contents)
    }
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

// -- QueryStep: a query over a view ------------------------------------------

// A view's spec as a query reads it: its rows and the indexes they are queried by.
module type QueryableView = {
  include Projection_GWT.Spec
  let config: Reventless.ReadModel.config
}

module QueryStep = (
  Spec: QueryableView,
  Projection: Projection_GWT.Projection with module Spec := Spec,
) => {
  module P = Projection_GWT.Make(Spec, Projection)
  module Q = Query_GWT.Make({
    let name = Spec.name
    type state = Spec.state
    let stateSchema = Spec.stateSchema
    let config = Spec.config
    let subIdConfig = Spec.subIdConfig
    type role = Spec.role
    let authorization = Spec.authorization
  })
  let part: Outcome.part = {kind: Query, name: Spec.name}
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
  let encState = (st: Spec.state) => st->Message.encode(Spec.stateSchema)

  // Every row of the view, built from the record at the times of its events, and
  // read as the flow's caller.
  let rowsOf = async (s: flowState) => {
    let store = await P.givenEventsAt(
      s.log->Array.flatMap(entry =>
        decodeMatching([entry], consumedDecoder, [])->Array.map(e => (e, iso(entry.at)))
      ),
    )
    store
    ->Dict.toArray
    ->Array.flatMap(((id, rows)) => {
      let rows = switch s.caller {
      | None => rows
      | Some(who) => rows->P.readableBy(who, ~elevated=elevated.contents)
      }
      rows->Array.map(row => (id, row))
    })
  }

  // A query as the view's doors answer it: by a field, through the index that
  // covers it, filtered and limited. An index the view lacks fails the step.
  let whenQueried = async (flowP: flow, args: Query_GWT.queryArgs<Spec.state>) => {
    let s = await flowP->enter(~verb="whenQueried", ~part)
    switch (await s->rowsOf)->Q.givenStore->Q.whenQuery(args) {
    | Ok(rows) => {...s, lastRows: rows->Array.map(encState)}
    | Error(mismatch) => {...s, lastRows: []}->recordOutcome(Error(mismatch))
    }
  }

  let listed = (s: flowState, expected: array<JSON.t>) =>
    s->recordOutcome(
      s.lastRows == expected
        ? Outcome.pass
        : Outcome.fail(QueryRowsMismatch({expected, actual: s.lastRows})),
    )

  let thenListed = async (flowP: flow, expected: array<Spec.state>) =>
    (await flowP->enter(~verb="thenListed", ~part))->listed(expected->Array.map(encState))

  let thenCounted = async (flowP: flow, count: int) => {
    let s = await flowP->enter(~verb="thenCounted", ~part)
    s->recordOutcome(
      s.lastRows->Array.length == count
        ? Outcome.pass
        : Outcome.fail(
            StateMismatch({
              key: "count",
              expected: Some(JSON.Encode.int(count)),
              actual: Some(JSON.Encode.int(s.lastRows->Array.length)),
            }),
          ),
    )
  }
}

// -- SideEffectStep: an aggregate's side effect over the record --------------

module SideEffectStep = (SE: Reventless.SideEffect.T) => {
  // A side effect has no name of its own; its file's is the one it is known by.
  let name =
    SE.moduleUrl
    ->String.split("/")
    ->Array.at(-1)
    ->Option.flatMap(file => file->String.split(".")->Array.get(0))
    ->Option.getOr("SideEffect")
  let part: Outcome.part = {kind: SideEffect, name}
  let decoder = Reventless.DcbDecode.makeDecoder(SE.Source.eventSchema)
  let key = "sideEffect:" ++ name

  // The side effect runs for each of its source's events on the record it has
  // not run for yet, with the id the event was recorded under and the flow's
  // time. What it did is what its mock recorded meanwhile.
  let whenRuns = async (flowP: flow, mock: SideEffect_GWT.mock<'call>) => {
    let s = await flowP->enter(~verb="whenRuns", ~part)
    let handled = s->handledBy(key)
    let fresh =
      s.log
      ->Array.mapWithIndex((entry, i) => (Int.toString(i), entry))
      ->Array.filterMap(((i, entry)) =>
        handled->Array.includes(i)
          ? None
          : decodeMatching([entry], decoder, [])->Array.get(0)->Option.map(ev => (i, entry, ev))
      )
    let before = mock.snapshot()->Array.length
    let rec run = async i =>
      switch fresh->Array.get(i) {
      | None => ()
      | Some((_, entry, event)) =>
        await SE.execute(
          SE.Source.Id.makeFromString(entry->sourceIdOf),
          {...StubRuntime.meta, time: iso(entry.at)},
          event,
          SideEffect_GWT.stubQueryEngine,
        )
        await run(i + 1)
      }
    await run(0)
    {
      ...s->markHandled(key, fresh->Array.map(((i, _, _)) => i)),
      lastCalls: mock.snapshot()->Array.slice(~start=before)->Array.map(mock.encode),
    }
  }

  // What the side effect did, by the mock's own record of it.
  let thenDid = async (flowP: flow, mock: SideEffect_GWT.mock<'call>, expected: array<'call>) => {
    let s = await flowP->enter(~verb="thenDid", ~part)
    let expectedJson = expected->Array.map(mock.encode)
    s->recordOutcome(
      s.lastCalls == expectedJson
        ? Outcome.pass
        : Outcome.fail(EventsMismatch({expected: expectedJson, actual: s.lastCalls})),
    )
  }

  let thenDidNothing = async (flowP: flow) => {
    let s = await flowP->enter(~verb="thenDidNothing", ~part)
    s->recordOutcome(
      s.lastCalls == [] ? Outcome.pass : Outcome.fail(NoEventExpected({actual: s.lastCalls})),
    )
  }
}

// -- Automation, way out, way in ---------------------------------------------
//
// Each takes the slice as written: its `Spec` and its body. The log keeps no
// source name, so every mapping is offered every entry; the source id is the id
// the entry was recorded under.

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

  let key = "automation:" ++ Spec.name

  // The schedules due between `from` and the flow's time, as ticks: the
  // declared one, and those the record's events set.
  let dueTicks = (s: flowState, log, ~from) => {
    let rows = A.declaredRows(~now=0.0)
    log->Array.forEach(((
      entry: logEntry,
      routed: array<AutomationSlice_Route.routed<Spec.todoItem>>,
    )) =>
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
    A.routeEach(
      firings->Array.map(((key, at)) => A.tick(~key, at)),
      A.testContext,
    )->Array.flatMap(((_, routed)) => routed)
  }

  // A sweep of the record at the flow's time, and of the ticks given: the
  // to-do items it has not acted on yet, now marked as acted on.
  let reactWith = (s: flowState, ~ticks=[]) => {
    let fromLog = s->routedLog->Array.flatMap(((_, routed)) => routed)
    let handled = s->handledBy(key)
    let commands =
      A.sweep(fromLog->Array.concat(ticks), ~now=s.now).commands->Array.filter(((id, _)) =>
        !(handled->Array.includes(id))
      )
    (s->markHandled(key, commands->Array.map(((id, _)) => id)), commands)
  }

  let sent = (s: flowState, commands: array<(string, Spec.command)>) => {
    ...s,
    lastCommands: commands->Array.map(((_id, cmd)) => cmd->Message.encode(Spec.commandSchema)),
    lastRefusal: None,
  }

  // The automation sweeps the record at the flow's time and sends what is new
  // since its last step.
  let whenReacts = async (flowP: flow, ~at=?) => {
    let s = await flowP->enter(~verb="whenReacts", ~part, ~at?)
    let (s, commands) = s->markNamed(key)->reactWith
    s->sent(commands)
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
      let (s, commands) = s->markNamed(key)->reactWith(~ticks=s->dueTicks(s->routedLog, ~from))
      s->sent(commands)
    }
  }

  let reacting: reacting = {
    key,
    part,
    react: async s => {
      let (s, commands) = s->reactWith
      (
        s,
        commands->Array.map(((_, cmd)) => {
          target: Some(Spec.targetName),
          command: cmd->Message.encode(Spec.commandSchema),
        }),
      )
    },
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

  // What `collect` queues over the record, each entry with the id it was
  // recorded under.
  let collected = (s: flowState) =>
    s.log->Array.flatMap(entry =>
      decodeMatching([entry], consumedDecoder, [])->Array.flatMap(e =>
        Translation.collect(e, ~sourceId=entry->sourceIdOf)
      )
    )

  let outbound = async (flowP: flow, ~verb, expected: array<(string, Spec.outboundItem)>) => {
    let s = await flowP->enter(~verb, ~part)
    let actual = encItems(s->collected)
    let expectedJson = encItems(expected)
    let o =
      actual == expectedJson
        ? Outcome.pass
        : Outcome.fail(TodoMismatch({expected: expectedJson, actual}))
    s->recordOutcome(o)
  }

  let key = "outbound:" ++ Spec.name

  // The way out sends what it queued and has not sent yet: its own `translate`,
  // against fakes that stand in for the outside services (`Capabilities_Fake`).
  // What the answers become are the step's sent commands, for `whenIssued`; a
  // translate that fails is what `thenIssues…` reports.
  let whenSent = async (flowP: flow, ~fakes=Capabilities_Fake.make(), ~at=?) => {
    let s = await flowP->enter(~verb="whenSent", ~part, ~at?)
    let handled = s->handledBy(key)
    let items = s->collected->Array.filter(((id, _)) => !(handled->Array.includes(id)))
    let rec send = async (i, commands, refusal) =>
      switch (items->Array.get(i), refusal) {
      | (None, _) | (_, Some(_)) => (commands, refusal)
      | (Some((id, item)), None) =>
        switch await Translation.translate(id, item, ~capabilities=fakes.capabilities) {
        | Ok(Some((_, command))) => await send(i + 1, commands->Array.concat([command]), None)
        | Ok(None) => await send(i + 1, commands, None)
        | Error(reason) => (commands, Some(`translate failed: ${reason}`))
        | exception JsExn(e) => (
            commands,
            Some(`translate threw: ${e->JsExn.message->Option.getOr("an exception")}`),
          )
        }
      }
    let (commands, refusal) = await send(0, [], None)
    {
      ...s->markHandled(key, items->Array.map(((id, _)) => id)),
      lastCommands: commands->Array.map(c => c->Message.encode(Spec.inboundCommandSchema)),
      lastRefusal: refusal,
      lastSent: fakes.calls(),
    }
  }

  // What the way out asked of the outside services, in order.
  let thenSent = async (flowP: flow, expected: array<Capabilities_Fake.call>) => {
    let s = await flowP->enter(~verb="thenSent", ~part)
    s->recordOutcome(
      s.lastSent == expected
        ? Outcome.pass
        : Outcome.fail(
            EventsMismatch({
              expected: expected->Array.map(Capabilities_Fake.toJson),
              actual: s.lastSent->Array.map(Capabilities_Fake.toJson),
            }),
          ),
    )
  }

  let issued = async (flowP: flow, ~verb, expected: array<Spec.inboundCommand>) =>
    (await flowP->enter(~verb, ~part))->encodedCommandsMatch(
      expected->Array.map(c => c->Message.encode(Spec.inboundCommandSchema)),
    )
  let thenIssuesCommands = (flowP, expected) => issued(flowP, ~verb="thenIssuesCommands", expected)
  let thenIssuesCommand = (flowP, command) => issued(flowP, ~verb="thenIssuesCommand", [command])
  let thenIssuesNoCommand = flowP => issued(flowP, ~verb="thenIssuesNoCommand", [])

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

  // Each event the step before recorded, mapped with the id it was recorded
  // under, as the runtime gives it; each public event appended with the id the
  // mapping published it with.
  let runMapping = async (events: array<(string, M.Delegate.event)>): array<(
    string,
    M.ExtensionPoint.event,
  )> =>
    switch M.mapOutgoingEvent {
    | None => []
    | Some(f) =>
      let actions =
        events
        ->Array.map(((sourceId, ev)) => f(sourceId, ev, StubRuntime.meta, StubRuntime.queryEngine))
        ->Array.flat
      let nested = await actions
      ->Array.map(async action =>
        switch action {
        | EPMapping.PublishEvent(id, e) => [(id, e)]
        | EPMapping.PublishEventAsync(p) => [await p]
        | EPMapping.HandleDirective(_, _) => []
        }
      )
      ->Promise.all
      nested->Array.flat
    }

  let whenPublished = async (flowP: flow, ~at=?) => {
    let s = await flowP->enter(~verb="whenPublished", ~part, ~at?)
    let delegateEvents =
      s.lastEvents
      ->Array.mapWithIndex((json, i) => (s.lastIds->Array.get(i)->Option.getOr(""), json))
      ->Array.filterMap(((id, json)) => {
        let data = switch json {
        | Object(d) => d
        | _ => Dict.make()
        }
        delegateDecoder.decode(
          ~eventType=json->Reventless.Message.variantNameOfJson,
          ~data,
        )->Option.map(ev => (id, ev))
      })
    let publicEvents = await runMapping(delegateEvents)
    {
      ...s,
      log: s.log->Array.concat(
        publicEvents->Array.map(((id, e)) =>
          entryOf(e, M.ExtensionPoint.eventSchema, ~at=s.now, ~id)
        ),
      ),
      lastPublic: publicEvents->Array.map(((_, e)) =>
        e->Message.encode(M.ExtensionPoint.eventSchema)
      ),
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

  let key = "extension:" ++ part.name

  // The extension point's events on the record it has not reacted to yet, and
  // the commands it sends for them; the events now marked as reacted to.
  let reactWith = async (s: flowState) => {
    let handled = s->handledBy(key)
    let fresh =
      s.log
      ->Array.mapWithIndex((entry, i) => (Int.toString(i), entry))
      ->Array.filterMap(((i, entry)) =>
        handled->Array.includes(i)
          ? None
          : decodeMatching([entry], epDecoder, [])
            ->Array.get(0)
            ->Option.map(ev => (i, entry.id, ev))
      )
    let actions =
      fresh
      ->Array.map(((_, sourceId, ev)) =>
        M.mapIncomingEvent(
          sourceId,
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
    (s->markHandled(key, fresh->Array.map(((i, _, _)) => i)), nested->Array.flat)
  }

  // The extension reacts to the extension point's events it has not reacted to.
  let whenReacts = async (flowP: flow, ~at=?) => {
    let s = await flowP->enter(~verb="whenReacts", ~part, ~at?)
    let (s, commands) = await s->markNamed(key)->reactWith
    {...s, lastCommands: commands}
  }

  let reacting: reacting = {
    key,
    part,
    react: async s => {
      let (s, commands) = await s->reactWith
      (s, commands->Array.map(command => {target: Some(M.Delegate.name), command}))
    },
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

// -- What else reacts --------------------------------------------------------

// Each reacting part of `systems` over the flow, in turn: the flow after them,
// and what each sent.
let reactAll = async (s: flowState, reacting: array<reacting>) => {
  let rec go = async (s, i, sent) =>
    switch reacting->Array.get(i) {
    | None => (s, sent)
    | Some(r) =>
      let (s, reactions) = await r.react(s)
      await go(s, i + 1, sent->Array.concat(reactions->Array.map(x => (r, x))))
    }
  await go(s, 0, [])
}

// Every reacting part of the systems given that the flow did not name, run over
// the record: one that would send a command fails the flow, and is named.
let thenNothingElseReacts = async (flowP: flow, systems: array<parts>) => {
  let s = await flowP->enter(~verb="thenNothingElseReacts")
  let unnamed =
    systems->Array.flatMap(p => p.reacting)->Array.filter(r => !(s.named->Array.includes(r.key)))
  let (_, sent) = await s->reactAll(unnamed)
  // The failure points at the first part that would send.
  let s = switch sent[0] {
  | Some((r, _)) => {...s, at: s.at->Option.map(step => {...step, part: r.part})}
  | None => s
  }
  s->recordOutcome(
    switch sent {
    | [] => Outcome.pass
    | sent =>
      Outcome.fail(
        PublishedActionsMismatch({
          expected: [],
          actual: sent->Array.map(((r, {command})) =>
            JSON.Encode.object(
              Dict.fromArray([("reacts", JSON.Encode.string(r.part.name)), ("sends", command)]),
            )
          ),
        }),
      )
    },
  )
}

// How many rounds of reacting and deciding a flow settles within.
let settleBound = 20

// The app does the rest: the systems' reacting parts react, the commands they
// send are decided by the part that reads them (the one they are meant for
// first), and again, until nothing is sent. A flow still sending after
// `settleBound` rounds fails: it loops. The step's events are all of theirs.
let whenSettled = async (flowP: flow, systems: array<parts>) => {
  let s = await flowP->enter(~verb="whenSettled")
  let reacting = systems->Array.flatMap(p => p.reacting)
  let deciding = systems->Array.flatMap(p => p.deciding)
  let decide = (s, {target, command}: reaction) =>
    switch target
    ->Option.flatMap(t => deciding->Array.find(d => d.name == t))
    ->Option.flatMap(d => d.run(s, command)) {
    | Some(s) => Some(s)
    | None => deciding->Array.findMap(d => d.run(s, command))
    }
  let rec round = async (s: flowState, n, events, commands) => {
    let (s, sent) = await s->reactAll(reacting)
    let s = reacting->Array.reduce(s, (s, r) => s->markNamed(r.key))
    switch sent {
    | [] => {...s, lastEvents: events, lastCommands: commands}
    | _ if n >= settleBound =>
      s->recordOutcome(
        Outcome.fail(
          Throw({
            error: `the flow does not settle: still sending after ${settleBound->Int.toString} rounds`,
            stack: "",
          }),
        ),
      )
    | sent =>
      let (s, events, unread) = sent->Array.reduce((s, events, None), (
        (s, events, unread),
        (_, reaction),
      ) =>
        switch unread {
        | Some(_) => (s, events, unread)
        | None =>
          switch s->decide(reaction) {
          | Some(next) => (next, events->Array.concat(next.lastEvents), None)
          | None => (s, events, Some(reaction.command))
          }
        }
      )
      switch unread {
      | Some(command) =>
        s->recordOutcome(
          Outcome.fail(
            TranslateError({
              expected: "a decision of the systems given that reads the command",
              actual: Some(`no decision reads ${JSON.stringify(command)}`),
            }),
          ),
        )
      | None =>
        await round(
          s,
          n + 1,
          events,
          commands->Array.concat(sent->Array.map(((_, {command})) => command)),
        )
      }
    }
  }
  await round({...s, lastEvents: [], lastError: None}, 0, [], [])
}

// -- Old names ---------------------------------------------------------------
//
// Each old step name stays for one release so that a flow using it fails to
// build with a message naming the new step. None of them runs.

type renamedToDecisionStep
type movedToGeneratedBoundaryTest
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

// A system's boundary is checked by the test `generate-plugin` writes for it
// (`Boundary_GWT`), not in a flow.
@deprecated("Moved: generate-plugin writes each system's boundary test (Boundary_GWT).")
let thenBoundaryScopeResolves = (
  _: movedToGeneratedBoundaryTest,
  ~name as _: movedToGeneratedBoundaryTest,
  _: movedToGeneratedBoundaryTest,
) => ()
