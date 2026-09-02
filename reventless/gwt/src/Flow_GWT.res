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
// command step honours DCB tag filtering so downstream deciders never see
// phantom cross-entity events.
//
// The chain is built from per-step functors (one per slice), threaded with
// pipe-first so it reads top-to-bottom:
//
//   module Place = Flow_GWT.CommandStep(PlaceOrder, PlaceOrder_Behavior)
//   module Auto  = Flow_GWT.AutomationStep(AutoShipOrderSlice)
//   module Ship  = Flow_GWT.CommandStep(ShipOrder, ShipOrder_Behavior)
//   module View  = Flow_GWT.ViewStep(Orders, Orders_Projection)
//
//   start
//   ->Sync.givenEvents([CatalogProductSynced({...})])
//   ->Place.whenCommand(PlaceOrder({...}))->Place.thenEvents([OrderPlaced({...})])
//   ->Auto.whenReacts->Auto.thenIssuesCommand(ShipOrder({...}))
//   ->Ship.whenCommand(ShipOrder({...}))->Ship.thenEvents([OrderShipped({...})])
//   ->View.thenViewState("o1", {...})
//
// Cross-plugin flows (Phase 3) add two boundary steps — `ExtensionPointStep`
// and `ExtensionStep` — that continue a flow from one plugin into the next
// through the ExtensionPoint mapping / Extension delegate, exactly as the
// runtime routes it across the plugin boundary.
//
// See `docs/plans/done/gwt-flow-and-extension-test-kinds.md` Phases 2–3.

module EPMapping = ReventlessInfra.ExtensionPointMapping
module ExtMapping = ReventlessInfra.ExtensionMapping

// -- Shared log + flow state -------------------------------------------------

// One JSON-erased entry on the shared log: the variant name, the DCB tags
// extracted from the producing schema (so downstream tag filtering matches the
// runtime), the encoded event JSON, and — for events emitted by an aggregate
// step — the producing aggregate-ID. DCB step entries leave `aggregateId` as
// `None`; aggregate step entries set it to `Some(id)` so the matching
// `AggregateCommandStep` can rebuild per-aggregate history without DCB tag
// inference. Filtering by `aggregateId` and filtering by DCB tags are mutually
// exclusive: DCB queries look only at `eventType` + `tags`, and the aggregate
// decoder looks only at `aggregateId` + `eventType`.
type logEntry = {
  eventType: string,
  tags: array<Reventless.DcbTag.tag>,
  json: JSON.t,
  aggregateId: option<string>,
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
  // `AggregateCommandStep`. Aggregate-style EP mappings reference the source
  // aggregate-ID inside `mapOutgoingEvent` (e.g. the catalog Product EP uses
  // it as `productId`); the next `ExtensionPointStep` reads this field and
  // threads it through. DCB `CommandStep` events leave it `None` and the EP
  // step falls back to the synthetic `gwt-id` so the existing DCB Flow tests
  // are unchanged.
  lastAggregateId: option<string>,
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
}

// Entry point for a chain — an empty flow with no prior history.
let start: flow = Promise.resolve(emptyState)

// First failure wins: once the flow has recorded a mismatch, later assertions
// keep it rather than overwrite with a (possibly spurious) downstream result.
let recordOutcome = (s: flowState, o: Outcome.outcome): flowState =>
  switch s.outcome {
  | Error(_) => s
  | Ok() => {...s, outcome: o}
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
let appendEvents = (log: array<logEntry>, events: array<'e>, schema: S.t<'e>): array<logEntry> =>
  Array.concat(
    log,
    events->Array.map(ev => {
      let json = ev->Message.encode(schema)
      {
        eventType: json->Reventless.Message.variantNameOfJson,
        tags: Reventless.DcbTag.extractTagsExpanded(schema, ev),
        json,
        aggregateId: None,
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

// The chain returns a `flow`; `test` awaits it and reports the accumulated
// outcome. Bodies read top-to-bottom and end on the last `then*`.
let test = (name, ~timeout=?, body: unit => flow) =>
  JestBind.testPromise(~slice="Flow", name, ~timeout?, async () => {
    let s = await body()
    s.outcome
  })

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
  let s = await flowP
  let scope = Reventless.DcbTag.deriveEffectiveScope(slices)
  // An ambiguity that costs nothing is not a failure: a boundary whose fallback
  // carries every derived key reads exactly as the derivation would. What fails
  // is losing a key, because that is the case where the runtime answers wrongly.
  let outcome = if scope.droppedCrossPartitionTagKeys->Array.length > 0 {
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

// -- CommandStep: a StateChangeSlice / Aggregate decider ---------------------

module CommandStep = (
  Spec: Behavior_GWT.BehaviorSpec,
  Behavior: Behavior_GWT.Behavior with module Spec := Spec,
) => {
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
  let consumedEventTypes = consumedDecoder.eventTypes

  // Seed prior history with events this slice can emit.
  let givenEvents = async (flowP: flow, events: array<Spec.event>) => {
    let s = await flowP
    {...s, log: s.log->appendEvents(events, Spec.eventSchema)}
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
  let tagKeysByEventType =
    Reventless.DcbScopeInference.infer([scopeShape]).tagKeysByEventType

  let whenCommand = async (flowP: flow, command: Spec.command) => {
    let s = await flowP
    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=consumedEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command,
      ~tagKeysByEventType,
      ~crossPartitionTagKeys,
    )
    let history = decodeMatching(s.log, consumedDecoder, query)
    let state = history->Array.reduce(Behavior.initialState, Behavior.evolve)
    switch Behavior.decide(state, command) {
    | Ok(events) => {
        ...s,
        log: s.log->appendEvents(events, Spec.eventSchema),
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

  let thenEvents = async (flowP: flow, expected: array<Spec.event>) => {
    let s = await flowP
    let expectedJson = expected->Array.map(e => e->Message.encode(Spec.eventSchema))
    let o = switch s.lastError {
    | Some(err) =>
      Outcome.fail(
        ErrorMismatch({expected: JSON.Encode.null, actual: Some(err), actualEvents: s.lastEvents}),
      )
    | None =>
      s.lastEvents == expectedJson
        ? Outcome.pass
        : Outcome.fail(EventsMismatch({expected: expectedJson, actual: s.lastEvents}))
    }
    s->recordOutcome(o)
  }

  let thenEvent = (flowP, event) => thenEvents(flowP, [event])

  let thenError = async (flowP: flow, expected: Spec.error) => {
    let s = await flowP
    let expJson = expected->Message.encode(Spec.errorSchema)
    let o = switch s.lastError {
    | None =>
      Outcome.fail(ErrorMismatch({expected: expJson, actual: None, actualEvents: s.lastEvents}))
    | Some(actual) =>
      actual == expJson
        ? Outcome.pass
        : Outcome.fail(
            ErrorMismatch({expected: expJson, actual: Some(actual), actualEvents: s.lastEvents}),
          )
    }
    s->recordOutcome(o)
  }
}

// -- AggregateCommandStep: an Aggregate decider partitioned by aggregate-ID --
//
// Mirror of `CommandStep` for `Reventless.Behavior.T` (the aggregate-flavor
// behavior). Differences from the slice form:
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

module AggregateCommandStep = (
  Spec: Behavior_GWT.AggregateSpec,
  Behavior: Reventless.Behavior.T with module Spec = Spec,
) => {
  let aggregateDecoder = Reventless.DcbDecode.makeDecoder(Spec.eventSchema)

  // Seed `id`'s history before the first `whenCommand`. Useful when a flow
  // starts mid-stream (e.g. the order is already Placed when the test begins).
  let givenEvents = async (flowP: flow, ~id: string, events: array<Spec.event>) => {
    let s = await flowP
    {...s, log: s.log->appendAggregateEvents(~id, events, Spec.eventSchema)}
  }

  // Rebuild `id`'s state from the log, run `decide`, then either append the
  // emitted events (still tagged with `~id`) or remember the error for the
  // next `thenError`.
  let whenCommand = async (flowP: flow, ~id: string, command: Spec.command) => {
    let s = await flowP
    let history = decodeAggregateMatching(s.log, ~id, aggregateDecoder)
    let state = history->Array.reduce(Behavior.initialState, Behavior.evolve)
    switch Behavior.decide(state, command) {
    | Ok(events) => {
        ...s,
        log: s.log->appendAggregateEvents(~id, events, Spec.eventSchema),
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

  let thenEvents = async (flowP: flow, expected: array<Spec.event>) => {
    let s = await flowP
    let expectedJson = expected->Array.map(e => e->Message.encode(Spec.eventSchema))
    let o = switch s.lastError {
    | Some(err) =>
      Outcome.fail(
        ErrorMismatch({expected: JSON.Encode.null, actual: Some(err), actualEvents: s.lastEvents}),
      )
    | None =>
      s.lastEvents == expectedJson
        ? Outcome.pass
        : Outcome.fail(EventsMismatch({expected: expectedJson, actual: s.lastEvents}))
    }
    s->recordOutcome(o)
  }

  let thenEvent = (flowP, event) => thenEvents(flowP, [event])

  let thenNoEvent = async (flowP: flow) => {
    let s = await flowP
    let o = switch s.lastError {
    | Some(err) =>
      Outcome.fail(
        ErrorMismatch({expected: JSON.Encode.null, actual: Some(err), actualEvents: s.lastEvents}),
      )
    | None =>
      s.lastEvents->Array.length == 0
        ? Outcome.pass
        : Outcome.fail(NoEventExpected({actual: s.lastEvents}))
    }
    s->recordOutcome(o)
  }

  let thenError = async (flowP: flow, expected: Spec.error) => {
    let s = await flowP
    let expJson = expected->Message.encode(Spec.errorSchema)
    let o = switch s.lastError {
    | None =>
      Outcome.fail(ErrorMismatch({expected: expJson, actual: None, actualEvents: s.lastEvents}))
    | Some(actual) =>
      actual == expJson
        ? Outcome.pass
        : Outcome.fail(
            ErrorMismatch({expected: expJson, actual: Some(actual), actualEvents: s.lastEvents}),
          )
    }
    s->recordOutcome(o)
  }
}

// -- AutomationStep: a policy that reacts to log events and issues a command --

module AutomationStep = (Spec: Automation_GWT.SliceSpec) => {
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

  // Sweep the log: collect todos, drop the ones resolved within the same
  // stream, process the remainder into commands.
  let whenReacts = async (flowP: flow) => {
    let s = await flowP
    let events = decodeMatching(s.log, consumedDecoder, [])
    let collected = events->Array.map(e => e->Spec.collect)->Array.flat
    let resolvedIds = events->Array.filterMap(e => e->Spec.resolve)
    let pending = collected->Array.filter(((id, _)) => !(resolvedIds->Array.includes(id)))
    let commands = pending->Array.filterMap(((id, todo)) => Spec.process(id, todo))
    {...s, lastCommands: commands->Array.map(((_id, cmd)) => cmd->Message.encode(Spec.commandSchema))}
  }

  let thenIssuesCommands = async (flowP: flow, expected: array<Spec.command>) => {
    let s = await flowP
    let expJson = expected->Array.map(c => c->Message.encode(Spec.commandSchema))
    let o =
      s.lastCommands == expJson
        ? Outcome.pass
        : Outcome.fail(EventsMismatch({expected: expJson, actual: s.lastCommands}))
    s->recordOutcome(o)
  }

  let thenIssuesCommand = (flowP, command) => thenIssuesCommands(flowP, [command])
  let thenIssuesNoCommand = flowP => thenIssuesCommands(flowP, [])
}

// -- ViewStep: a StateViewSlice / projection over the log --------------------

module ViewStep = (
  Spec: Projection_GWT.Spec,
  Projection: Projection_GWT.Projection with module Spec := Spec,
) => {
  module P = Projection_GWT.Make(Spec, Projection)
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

  let encState = (st: Spec.state) => st->Message.encode(Spec.stateSchema)

  // Fold the projection over every consumed event in the log and assert the
  // row(s) for `id`.
  let thenViewStates = async (flowP: flow, id, expected: array<Spec.state>) => {
    let s = await flowP
    let events = decodeMatching(s.log, consumedDecoder, [])
    let store = await P.givenEvents(events)
    let actual = store->Dict.get(id)->Option.getOr([])->Array.map(encState)
    let expectedJson = expected->Array.map(encState)
    let o =
      actual == expectedJson
        ? Outcome.pass
        : Outcome.fail(
            StateMismatch({
              key: id,
              expected: Some(JSON.Encode.array(expectedJson)),
              actual: Some(JSON.Encode.array(actual)),
            }),
          )
    s->recordOutcome(o)
  }

  let thenViewState = (flowP, id, state) => thenViewStates(flowP, id, [state])
}

// -- OutboundStep: an OutboundTranslationSlice's `collect` over the log -------

module OutboundStep = (Spec: OutboundTranslation_GWT.SliceSpec) => {
  let consumedDecoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

  let encItems = (arr: array<(string, Spec.outboundItem)>) =>
    arr->Array.map(((id, item)) => (id, item->Message.encode(Spec.outboundItemSchema)))

  // Assert the outbound effects the slice would fire — the `collect` result.
  // (The async `translate` leg hits an external service, so it is exercised
  // only by the dedicated `OutboundTranslation_GWT`, not the flow.)
  let thenOutbound = async (flowP: flow, expected: array<(string, Spec.outboundItem)>) => {
    let s = await flowP
    let events = decodeMatching(s.log, consumedDecoder, [])
    // The flow log carries decoded events, not their envelopes, so there is no
    // entity id to thread here. A collect that keys off `~sourceId` (an
    // aggregate source) should be exercised by the dedicated
    // `OutboundTranslation_GWT`, which can supply one.
    let collected = events->Array.map(e => e->Spec.collect(~sourceId=""))->Array.flat
    let actual = encItems(collected)
    let expectedJson = encItems(expected)
    let o =
      actual == expectedJson
        ? Outcome.pass
        : Outcome.fail(TodoMismatch({expected: expectedJson, actual}))
    s->recordOutcome(o)
  }

  let thenOutboundNothing = flowP => thenOutbound(flowP, [])
}

// -- Cross-plugin boundary steps (Phase 3) -----------------------------------

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
  let delegateDecoder = Reventless.DcbDecode.makeDecoder(M.Delegate.eventSchema)

  // Aggregate-style EP mappings address the source aggregate's identity via
  // the first arg (e.g. catalog Product → ProductBecameAvailable uses it as
  // `productId`). DCB upstreams don't set `lastAggregateId` and fall back to
  // the synthetic `gwt-id` so existing DCB Flow tests keep their behaviour.
  let runMapping = async (
    sourceId: string,
    events: array<M.Delegate.event>,
  ): array<M.ExtensionPoint.event> =>
    switch M.mapOutgoingEvent {
    | None => []
    | Some(f) =>
      let actions =
        events
        ->Array.map(ev => f(sourceId, ev, StubRuntime.meta, StubRuntime.queryEngine))
        ->Array.flat
      let nested =
        await actions
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

  let whenPublishedThrough = async (flowP: flow) => {
    let s = await flowP
    let delegateEvents =
      s.lastEvents->Array.filterMap(json => {
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
      log: s.log->appendEvents(publicEvents, M.ExtensionPoint.eventSchema),
      lastPublic: publicEvents->Array.map(e => e->Message.encode(M.ExtensionPoint.eventSchema)),
    }
  }

  let thenPublicEvents = async (flowP: flow, expected: array<M.ExtensionPoint.event>) => {
    let s = await flowP
    let expJson = expected->Array.map(e => e->Message.encode(M.ExtensionPoint.eventSchema))
    let o =
      sortJson(s.lastPublic) == sortJson(expJson)
        ? Outcome.pass
        : Outcome.fail(PublishedActionsMismatch({expected: expJson, actual: s.lastPublic}))
    s->recordOutcome(o)
  }

  let thenPublicEvent = (flowP, event) => thenPublicEvents(flowP, [event])
}

// ExtensionStep: runs an Extension delegate's `mapIncomingEvent` over the public
// EP events the last ExtensionPoint step produced, surfacing the commands the
// extension issues onto its own plugin's slices. The next `CommandStep` then
// executes the asserted command.
module ExtensionStep = (M: ExtMapping.Mapping) => {
  let epDecoder = Reventless.DcbDecode.makeDecoder(M.ExtensionPoint.eventSchema)
  let encCmd = (c: M.Delegate.command) => c->Message.encode(M.Delegate.commandSchema)

  let whenExtensionReacts = async (flowP: flow) => {
    let s = await flowP
    let epEvents =
      s.lastPublic->Array.filterMap(json => {
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
    let nested =
      await actions
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

  let thenIssuesCommands = async (flowP: flow, expected: array<M.Delegate.command>) => {
    let s = await flowP
    let expJson = expected->Array.map(encCmd)
    let o =
      sortJson(s.lastCommands) == sortJson(expJson)
        ? Outcome.pass
        : Outcome.fail(PublishedActionsMismatch({expected: expJson, actual: s.lastCommands}))
    s->recordOutcome(o)
  }

  let thenIssuesCommand = (flowP, command) => thenIssuesCommands(flowP, [command])
  let thenIssuesNoCommand = flowP => thenIssuesCommands(flowP, [])
}
