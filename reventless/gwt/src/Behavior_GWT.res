open ReventlessCore

// Plan 02 Phase 6b — unified Behavior GWT DSL covering both Aggregate and
// StateChangeSlice. Two entry points:
//
//   * [Make(Spec, Behavior)]              — StateChangeSlice form. [Spec] carries
//                                            [consumedEvent]; [Behavior.evolve]
//                                            consumes it. DCB append-condition
//                                            checks are wired in.
//   * [MakeFromAggregate(Spec, Behavior)] — Aggregate adapter. [Spec] is
//                                            [Reventless.Aggregate.Spec],
//                                            [Behavior] is [Reventless.Behavior.T].
//                                            No DCB semantics; the simpler
//                                            [AggregateT] surface is returned.
//
// Both produce the same [describe / test / givenEvents / whenCmd / then*]
// triple-A surface. Slice form additionally exposes
// [thenAppendsConditionedOn / thenAppendsConditionedOnExactly] for DCB
// optimistic-concurrency assertions.
//
// Aggregate users *cannot* use [Make] (their Spec doesn't carry [consumedEvent])
// and slice users *cannot* use [MakeFromAggregate] (their Spec/Behavior shape
// differs). Pick the matching entry point.

// ---------------------------------------------------------------------------
// Slice form — replaces the legacy `StateChangeSlice_GWT`.
// ---------------------------------------------------------------------------

module type BehaviorSpec = {
  let name: string

  @schema
  type consumedEvent

  @schema
  type command

  @schema
  type error

  @schema
  type event
}

module type Behavior = {
  module Spec: BehaviorSpec

  type state
  let initialState: state
  let evolve: (state, Spec.consumedEvent) => state
  let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>
}

module type T = {
  module Spec: BehaviorSpec

  let describe: (string, unit => unit) => unit
  let todo: string => unit
  let test: (string, unit => Outcome.outcome) => unit

  let givenEvents: array<Spec.consumedEvent> => array<Spec.consumedEvent>

  let whenCmd: (array<Spec.consumedEvent>, Spec.command) => array<Spec.event>

  let thenEvent: (array<Spec.event>, Spec.event) => Outcome.outcome
  let thenEvents: (array<Spec.event>, array<Spec.event>) => Outcome.outcome
  let thenNoEvent: array<Spec.event> => Outcome.outcome
  let thenEventWithError: (array<Spec.event>, Spec.event, Spec.error) => Outcome.outcome
  let thenEventsWithError: (array<Spec.event>, array<Spec.event>, Spec.error) => Outcome.outcome
  let thenError: (array<Spec.event>, Spec.error) => Outcome.outcome

  // DCB optimistic-concurrency assertions.
  let thenAppendsConditionedOn: (
    array<Spec.event>,
    Reventless.DcbTag.query,
  ) => Outcome.outcome
  let thenAppendsConditionedOnExactly: (
    array<Spec.event>,
    Reventless.DcbTag.appendCondition,
  ) => Outcome.outcome
}

// JSON encoder for [Reventless.DcbTag.appendCondition]. The framework
// doesn't ship a sury schema for it; encoding structurally keeps the
// Outcome algebra's JSON payload closed.
let encodeTag = (t: Reventless.DcbTag.tag): JSON.t => {
  let d = Dict.make()
  d->Dict.set("key", JSON.Encode.string(t.key))
  d->Dict.set("value", JSON.Encode.string(t.value))
  JSON.Encode.object(d)
}

let encodeQueryItem = (qi: Reventless.DcbTag.queryItem): JSON.t => {
  let d = Dict.make()
  switch qi.eventTypes {
  | Some(types) =>
    d->Dict.set("eventTypes", types->Array.map(JSON.Encode.string)->JSON.Encode.array)
  | None => ()
  }
  switch qi.tags {
  | Some(tags) => d->Dict.set("tags", tags->Array.map(encodeTag)->JSON.Encode.array)
  | None => ()
  }
  JSON.Encode.object(d)
}

let encodeQuery = (q: Reventless.DcbTag.query): JSON.t =>
  q->Array.map(encodeQueryItem)->JSON.Encode.array

let encodeAppendCondition = (c: Reventless.DcbTag.appendCondition): JSON.t => {
  let d = Dict.make()
  d->Dict.set("query", encodeQuery(c.query))
  switch c.after {
  | Some(pos) => d->Dict.set("after", JSON.Encode.string(pos))
  | None => ()
  }
  JSON.Encode.object(d)
}

// ---------------------------------------------------------------------------
// Shared assertion core for both Behavior GWT flavours.
//
// `Make` (slice/DCB) and `MakeFromAggregate` encode produced events / errors
// identically and compare them against the expectation the same way — only the
// DCB append-condition footgun that `Make` layers on top, and the `thenCompare*`
// custom-equality arms the aggregate flavour adds, differ. Factoring the
// comparison core out (mirroring `Delegate_GWT`'s `Make`) keeps the two from
// silently drifting. The `errors` ref is owned here and set by each outer
// functor's `exec`.
// ---------------------------------------------------------------------------
module type CoreSpec = {
  @schema
  type event
  @schema
  type error
}

module AssertionCore = (Spec: CoreSpec) => {
  let errors: ref<array<Spec.error>> = ref([])

  let encEvent = (e: Spec.event) => e->Message.encode(Spec.eventSchema)
  let encEvents = evs => evs->Array.map(encEvent)
  let encError = (err: Spec.error) => err->Message.encode(Spec.errorSchema)

  let unexpectedError = (events: array<Spec.event>): Outcome.outcome => {
    let actual = errors.contents->Array.get(0)->Option.map(encError)
    Outcome.fail(
      ErrorMismatch({
        expected: JSON.Encode.null,
        actual,
        actualEvents: events->encEvents,
      }),
    )
  }

  // Events are compared by their **encoded (wire) form**, not by ReScript
  // structural equality. For an event-sourced system the serialized event *is*
  // its identity: two events that reverse-convert to the same JSON are the same
  // event. Raw `==` is stricter than that — it distinguishes an optional field
  // that is present-but-`undefined` (what a decider's `deliveryWindow: ?x`
  // passthrough emits when `x` is `None`) from one whose key is absent (what a
  // test literal that omits the field produces), even though sury drops a `None`
  // optional either way and both hit the log identically. Comparing on `encEvents`
  // unifies that spurious difference, so an optional event field can be omitted in
  // the expectation instead of spelled out as `?None`. It is a strictly weaker
  // equality: equal values still encode equally, so nothing that passed can start
  // failing — it only stops the wire-invisible key asymmetry from failing a test.
  let compareEvents = (events, expectedEvents) =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if events->encEvents == expectedEvents->encEvents {
      Outcome.pass
    } else {
      Outcome.fail(
        EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
      )
    }

  let compareEventsWith = (events, expectedEvents, cmp) =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if (
      events->Array.length == expectedEvents->Array.length &&
        Array.zip(events, expectedEvents)->Array.every(((e1, e2)) => cmp(e1, e2))
    ) {
      Outcome.pass
    } else {
      Outcome.fail(
        EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
      )
    }

  let compareNoEvent = events =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if events->Array.length == 0 {
      Outcome.pass
    } else {
      Outcome.fail(NoEventExpected({actual: events->encEvents}))
    }

  let matchesError = (
    events: array<Spec.event>,
    expectedEvents: array<Spec.event>,
    expectedError: Spec.error,
  ): Outcome.outcome => {
    let expectedErrorJson = encError(expectedError)
    switch errors.contents->Array.get(0) {
    | None =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedErrorJson,
          actual: None,
          actualEvents: events->encEvents,
        }),
      )
    | Some(actual) if actual != expectedError =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedErrorJson,
          actual: Some(encError(actual)),
          actualEvents: events->encEvents,
        }),
      )
    | Some(_) =>
      // Encoded comparison, for the same reason as `compareEvents` above.
      if events->encEvents == expectedEvents->encEvents {
        Outcome.pass
      } else {
        Outcome.fail(
          EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
        )
      }
    }
  }
}

module Make = (
  Spec: BehaviorSpec,
  Behavior: Behavior with module Spec := Spec,
): (T with module Spec = Spec) => {
  module Spec = Spec


  let describe = JestBind.describe
  let todo = JestBind.todo
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  let currentState = consumed =>
    consumed->Array.reduce(Behavior.initialState, Behavior.evolve)

  module Core = AssertionCore(Spec)
  let errors = Core.errors

  // DCB append-condition derived inside [whenCmd]; [None] until first call.
  let derivedCondition: ref<option<Reventless.DcbTag.appendCondition>> = ref(None)

  // Implicit pending failure raised when the derived query carries zero tags
  // across every clause AND the slice consumes at least one event type — a
  // strong signal that a [@s.matches(DcbTag.string)] annotation is missing
  // from the command schema. Regular [then*] combinators surface it before
  // their own checks; [thenAppends*] bypass it.
  let appendConditionFailure: ref<option<Outcome.mismatch>> = ref(None)

  let consumedEventTypes =
    Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema).eventTypes

  // Scope derived from this slice's schemas, mirroring the StateChangeSlice runtime.
  let scopeShape = Reventless.DcbTag.sliceShapeFromSchemas(
    ~name="",
    ~commandSchema=Spec.commandSchema,
    ~consumedEventSchema=Spec.consumedEventSchema,
    ~eventSchema=Spec.eventSchema,
  )
  // Cross-partition tag keys fan a foreign-entity reference into its own single-tag
  // clause instead of being AND-ed with the partition. Unioned: any explicit
  // `@crossPartition` annotation (capacity / escape-hatch reads) plus the per-slice
  // inference (a foreign consumed key that is not this slice's partition), so a slice
  // with *no* annotation still reads correctly.
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
  // Per-event indexed-tag map so a foreign reference key on this slice's *own*
  // emitted event (payload, not a read key) is narrowed out of a cross-partition
  // clause — the same dead-clause removal the runtime threads.
  let tagKeysByEventType =
    Reventless.DcbScopeInference.infer([scopeShape]).tagKeysByEventType

  // Reachability guard inputs. The event types this slice *emits* are its own
  // history — read with composite AND clauses, which is fine. A *foreign* event
  // type (consumed from a sibling slice) is a cross-entity read: if the command
  // filters it by a tag key that appears in the decision query, yet the event
  // cannot satisfy any whole clause, it can never reach `decide` — the classic
  // "forgot @crossPartition on a cross-entity reference" bug (the key is AND-ed
  // with the partition instead of fanning into its own clause). Tag keys the
  // event carries but the command does NOT query are payload, not read keys, so
  // they are ignored (e.g. CancelOrder reads OrderPlaced by orderId and merely
  // carries its productIds over to the cancel event). Flow_GWT catches this
  // because it threads a real tagged log; this lets the per-slice GWT catch it
  // too, rather than folding an unreachable event straight through.
  let emittedEventTypes =
    Reventless.DcbDecode.makeDecoder(Spec.eventSchema).eventTypes
  let consumedTagKeysByType =
    Reventless.DcbTag.extractTagKeysByEventType(Spec.consumedEventSchema)

  let queryTagKeys = (query: Reventless.DcbTag.query): array<string> =>
    query->Array.flatMap(qi => qi.tags->Option.mapOr([], tags => tags->Array.map(t => t.key)))

  // True when some clause's tags are all carried by `declaredKeys` (so an event
  // declaring exactly those keys would match it). An empty query selects all.
  let selectableBy = (query: Reventless.DcbTag.query, declaredKeys: array<string>): bool =>
    query->Array.length == 0 ||
      query->Array.some(qi =>
        switch qi.tags {
        | None | Some([]) => true
        | Some(tags) => tags->Array.every(t => declaredKeys->Array.includes(t.key))
        }
      )

  // Foreign consumed event types the command filters by a query key yet cannot
  // select. Returns (eventType, offendingKey).
  let unreachableForeignReads = (query: Reventless.DcbTag.query): array<(string, string)> => {
    let qKeys = queryTagKeys(query)
    consumedTagKeysByType
    ->Dict.toArray
    ->Array.filterMap(((evType, keys)) =>
      switch keys->Array.find(k => qKeys->Array.includes(k)) {
      | Some(key) if !(emittedEventTypes->Array.includes(evType)) && !selectableBy(query, keys) =>
        Some((evType, key))
      | _ => None
      }
    )
  }

  let queryTagsTotal = (q: Reventless.DcbTag.query): int =>
    q->Array.reduce(0, (acc, qi) =>
      acc + qi.tags->Option.mapOr(0, t => t->Array.length)
    )

  let exec = (history, command): array<Spec.event> => {
    errors := []
    appendConditionFailure := None

    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=consumedEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command,
      ~tagKeysByEventType,
      ~crossPartitionTagKeys,
    )
    let condition: Reventless.DcbTag.appendCondition = {query: query}
    derivedCondition := Some(condition)

    if consumedEventTypes->Array.length > 0 && queryTagsTotal(query) == 0 {
      appendConditionFailure :=
        Some(
          Outcome.AppendConditionMismatch({
            expected: JSON.Encode.string(
              "a non-empty tag set derived from @s.matches(DcbTag.string) fields on the command",
            ),
            actual: encodeAppendCondition(condition),
          }),
        )
    } else {
      // Surfaced through the same pending-failure channel as the zero-tags
      // footgun above (regular `then*` combinators check it first).
      switch unreachableForeignReads(query)->Array.get(0) {
      | Some((evType, key)) =>
        appendConditionFailure :=
          Some(
            Outcome.AppendConditionMismatch({
              expected: JSON.Encode.string(
                `a decision-query clause that selects '${evType}' on tag '${key}' alone — this is a cross-entity read, so mark '${key}' @crossPartition (or model it as a tagged array) and it will fan into its own clause; otherwise the decision model can never see '${evType}'`,
              ),
              actual: encodeAppendCondition(condition),
            }),
          )
      | None => ()
      }
    }

    let state = currentState(history)
    switch Behavior.decide(state, command) {
    | Ok(events) => events
    | Error(error) =>
      errors := [error]
      []
    }
  }

  let givenEvents = consumed => consumed
  let whenCmd = (history, cmd) => history->exec(cmd)

  let checkAppendCondition = (): option<Outcome.outcome> =>
    appendConditionFailure.contents->Option.map(m => Outcome.fail(m))

  // The append-condition footgun is surfaced before the shared comparison core
  // runs; `thenAppends*` below bypass it deliberately.
  let thenEvents = (events, expectedEvents) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.compareEvents(events, expectedEvents)
    }

  let thenEvent = (events, expectedEvent) => thenEvents(events, [expectedEvent])

  let thenNoEvent = events =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.compareNoEvent(events)
    }

  let thenError = (events, expectedError) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.matchesError(events, [], expectedError)
    }

  let thenEventWithError = (events, expectedEvent, expectedError) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.matchesError(events, [expectedEvent], expectedError)
    }

  let thenEventsWithError = (events, expectedEvents, expectedError) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => Core.matchesError(events, expectedEvents, expectedError)
    }

  let thenAppendsConditionedOn = (_events, expectedQuery: Reventless.DcbTag.query) =>
    switch derivedCondition.contents {
    | None =>
      Outcome.fail(
        Throw({
          error: "thenAppendsConditionedOn: whenCmd must be called before this assertion",
          stack: "",
        }),
      )
    | Some(cond) =>
      if cond.query == expectedQuery {
        Outcome.pass
      } else {
        Outcome.fail(
          AppendConditionMismatch({
            expected: encodeAppendCondition({query: expectedQuery}),
            actual: encodeAppendCondition(cond),
          }),
        )
      }
    }

  let thenAppendsConditionedOnExactly = (
    _events,
    expectedCondition: Reventless.DcbTag.appendCondition,
  ) =>
    switch derivedCondition.contents {
    | None =>
      Outcome.fail(
        Throw({
          error: "thenAppendsConditionedOnExactly: whenCmd must be called before this assertion",
          stack: "",
        }),
      )
    | Some(cond) =>
      if cond == expectedCondition {
        Outcome.pass
      } else {
        Outcome.fail(
          AppendConditionMismatch({
            expected: encodeAppendCondition(expectedCondition),
            actual: encodeAppendCondition(cond),
          }),
        )
      }
    }
}

// ---------------------------------------------------------------------------
// Aggregate adapter — preserves the legacy Aggregate-flavor surface.
// ---------------------------------------------------------------------------

// Minimal aggregate spec the DSL requires. Declared inline (rather than
// aliasing `Reventless.Behavior.T`'s inner Spec) because that inner Spec
// only carries the three @schema types — no `name` — and ReScript's
// `with module Spec = X` can only equate the inner Spec to a concrete
// module, not constrain it to a module type that adds `name`.
module type AggregateSpec = {
  let name: string
  @schema
  type command
  @schema
  type event
  @schema
  type error
}

module type AggregateT = {
  module Spec: AggregateSpec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Outcome.outcome) => unit

  let givenEvents: array<Spec.event> => array<Spec.event>

  let whenCmd: (array<Spec.event>, Spec.command) => array<Spec.event>

  let thenEvent: (array<Spec.event>, Spec.event) => Outcome.outcome
  let thenCompareEvent: (
    array<Spec.event>,
    Spec.event,
    (Spec.event, Spec.event) => bool,
  ) => Outcome.outcome
  let thenNoEvent: array<Spec.event> => Outcome.outcome
  let thenEventWithError: (array<Spec.event>, Spec.event, Spec.error) => Outcome.outcome
  let thenEvents: (array<Spec.event>, array<Spec.event>) => Outcome.outcome
  let thenCompareEvents: (
    array<Spec.event>,
    array<Spec.event>,
    (Spec.event, Spec.event) => bool,
  ) => Outcome.outcome
  let thenEventsWithError: (array<Spec.event>, array<Spec.event>, Spec.error) => Outcome.outcome
  let thenError: (array<Spec.event>, Spec.error) => Outcome.outcome
}

module MakeFromAggregate = (
  Spec: AggregateSpec,
  Behavior: Behavior.T with module Spec = Spec,
): (AggregateT with module Spec = Spec) => {
  module Spec = Spec


  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  let currentState = events =>
    events->Array.reduce(Behavior.initialState, Behavior.evolve)

  module Core = AssertionCore(Spec)
  let errors = Core.errors

  let exec = (history, command): array<Spec.event> => {
    errors := []
    let state = currentState(history)
    switch Behavior.decide(state, command) {
    | Ok(events) => events
    | Error(error) =>
      errors := [error]
      []
    }
  }

  let givenEvents = events => events
  let whenCmd = (history, cmd) => history->exec(cmd)

  // The aggregate flavour has no append-condition footgun, so the shared core's
  // comparisons are exposed directly; only `thenCompare*` (custom equality) is
  // specific to this surface.
  let thenEvents = Core.compareEvents
  let thenCompareEvents = Core.compareEventsWith
  let thenEvent = (events, expectedEvent) => thenEvents(events, [expectedEvent])
  let thenCompareEvent = (events, expectedEvent, cmp) =>
    thenCompareEvents(events, [expectedEvent], cmp)
  let thenNoEvent = Core.compareNoEvent

  let thenError = (events, expectedError) => Core.matchesError(events, [], expectedError)

  let thenEventWithError = (events, expectedEvent, expectedError) =>
    Core.matchesError(events, [expectedEvent], expectedError)

  let thenEventsWithError = (events, expectedEvents, expectedError) =>
    Core.matchesError(events, expectedEvents, expectedError)
}
