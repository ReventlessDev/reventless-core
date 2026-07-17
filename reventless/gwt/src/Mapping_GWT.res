open ReventlessCore

// Stage 5 — cross-pattern mapping GWT.
//
// Generalises `EventMapping_GWT` so both the source and target of a mapping
// can be an Aggregate (Behavior) or a StateChangeSlice. Covers all four
// producer/consumer combinations: Aggr→Aggr, Aggr→DCB, DCB→Aggr, DCB→DCB.
// See `docs/analysis/event-source-connection-matrix.md` for the full matrix
// and `docs/plans/reventless-gwt.md` Stage 5 for the migration plan.
//
// The unified `GwtSource`/`GwtTarget` module type is intentionally wider than
// either `Aggregate.Spec` or the `StateChangeSlice.SliceSpec`: it names every
// field both kinds need (`name`, `Id`, `state`, `command`, `event`, `error`,
// `decide`, `evolve`) and adds `consumedEvent` — the type `evolve` folds over.
// Aggregates satisfy this with `consumedEvent = event`; DCB slices supply a
// distinct cross-entity event type.

// -- Unified Source / Target / Mapping module types ---------------------------

module type GwtSource = {
  let name: string
  module Id: Reventless.Id.T

  type state
  let initialState: state

  @schema
  type consumedEvent
  let evolve: (state, consumedEvent) => state

  @schema
  type command

  @schema
  type event

  @schema
  type error

  let decide: (state, command) => result<array<event>, error>
}

module type GwtTarget = GwtSource

module type Mapping = {
  module Source: GwtSource
  module Target: GwtTarget

  let map: (
    Source.Id.t,
    Source.event,
    Reventless.QueryEngine.operations,
  ) => array<Reventless.EventMapping.action<Target.Id.t, Target.command>>
}

// -- Adapter functors --------------------------------------------------------

// Adapter: any `Aggregate.Spec` + matching `Behavior.T` becomes a `GwtSource`.
// Aggregates evolve their own events, so `consumedEvent = event`.
module FromBehavior = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: Behavior.T with module Spec = Spec,
) => {
  let name = Spec.name
  module Id = Spec.Id
  type state = Behavior.state
  let initialState = Behavior.initialState

  type consumedEvent = Spec.event
  let consumedEventSchema = Spec.eventSchema
  let evolve = Behavior.evolve

  type command = Spec.command
  let commandSchema = Spec.commandSchema

  type event = Spec.event
  let eventSchema = Spec.eventSchema

  type error = Spec.error
  let errorSchema = Spec.errorSchema

  let decide = Behavior.decide
}

// Adapter: a StateChangeSlice spec becomes a `GwtSource`/`GwtTarget`. DCB
// entity identifiers are tag values — plain strings — so the adapter uses
// `Id.StringPure`.
module type FromSliceSpec = {
  let name: string

  type state
  let initialState: state

  @schema
  type consumedEvent
  let evolve: (state, consumedEvent) => state

  @schema
  type command

  @schema
  type error

  @schema
  type event

  let decide: (state, command) => result<array<event>, error>
}

module FromStateChangeSlice = (Spec: FromSliceSpec) => {
  let name = Spec.name
  module Id = Reventless.Id.StringPure
  type state = Spec.state
  let initialState = Spec.initialState

  type consumedEvent = Spec.consumedEvent
  let consumedEventSchema = Spec.consumedEventSchema
  let evolve = Spec.evolve

  type command = Spec.command
  let commandSchema = Spec.commandSchema

  type event = Spec.event
  let eventSchema = Spec.eventSchema

  type error = Spec.error
  let errorSchema = Spec.errorSchema

  let decide = Spec.decide
}

// -- Mapping_GWT.T + Make ----------------------------------------------------

module type T = {
  module Source: GwtSource
  module Target: GwtTarget

  // A scenario carries the source history plus the target per-id history
  // through the pipe chain. Pipe-first (`->`) places it as the first arg of
  // every subsequent combinator, so the chain reads top-to-bottom.
  type scenario = (
    array<Source.consumedEvent>,
    array<(string, array<Target.consumedEvent>)>,
  )

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit

  let givenSourceEvents: array<Source.consumedEvent> => scenario
  let andTargetEvents: (scenario, array<(string, array<Target.consumedEvent>)>) => scenario

  let whenSourceCmd: (scenario, string, Source.command) => promise<dict<array<Target.event>>>

  let thenTargetEvents: (
    promise<dict<array<Target.event>>>,
    array<(string, array<Target.event>)>,
  ) => promise<Outcome.outcome>

  let thenTargetEvent: (
    promise<dict<array<Target.event>>>,
    string,
    Target.event,
  ) => promise<Outcome.outcome>

  let thenNoTargetEvent: promise<dict<array<Target.event>>> => promise<Outcome.outcome>

  let thenSourceError: (
    promise<dict<array<Target.event>>>,
    Source.error,
  ) => promise<Outcome.outcome>

  let thenTargetError: (
    promise<dict<array<Target.event>>>,
    Target.error,
  ) => promise<Outcome.outcome>

  let thenTargetEventsWithError: (
    promise<dict<array<Target.event>>>,
    array<(string, array<Target.event>)>,
    Target.error,
  ) => promise<Outcome.outcome>
}

module Make = (M: Mapping): (T with module Source = M.Source and module Target = M.Target) => {
  module Source = M.Source
  module Target = M.Target

  type scenario = (
    array<Source.consumedEvent>,
    array<(string, array<Target.consumedEvent>)>,
  )

  S.enableJson()

  let describe = JestBind.describe
  let sliceName = `${Source.name}→${Target.name}`
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=sliceName, name, ~timeout?, body)

  // QueryEngine stub — `EventMapping.map` can accept a QueryEngine for async
  // lookups. The GWT runs pure; we hand it an empty stub so anything that
  // actually needs a database resolves to empty results.
  let queryEngine: Reventless.QueryEngine.operations = {
    scan: (~readModelName as _, ~filterConfigs as _, ~limit as _) => []->Promise.resolve,
    query: (
      ~readModelName as _: string,
      ~key as _: option<string>=?,
      ~id as _: Reventless.QueryEngine.value,
      ~subIdConfig as _: option<Reventless.QueryEngine.SubId.config>=?,
      ~filterConfigs as _: option<array<Reventless.QueryEngine.Filter.config>>=?,
      ~ascending as _: option<bool>=?,
      ~limit as _: option<int>=?,
    ) => []->Promise.resolve,
  }

  let sourceErrors = ref([])
  let targetErrors = ref([])

  let execSource = (history: array<Source.consumedEvent>, cmd: Source.command): array<
    Source.event,
  > => {
    sourceErrors := []
    let state = history->Array.reduce(Source.initialState, Source.evolve)
    switch Source.decide(state, cmd) {
    | Ok(events) => events
    | Error(e) =>
      sourceErrors := [e]
      []
    }
  }

  let execTarget = (history: array<Target.consumedEvent>, cmd: Target.command): array<
    Target.event,
  > => {
    let state = history->Array.reduce(Target.initialState, Target.evolve)
    switch Target.decide(state, cmd) {
    | Ok(events) => events
    | Error(e) =>
      targetErrors := [e]
      []
    }
  }

  let givenSourceEvents = (sourceHistory): scenario => (sourceHistory, [])
  let andTargetEvents = ((sourceHistory, _), targetHistory): scenario => (
    sourceHistory,
    targetHistory,
  )

  // Execute the mapping: source command → source events → mapping actions →
  // target commands → target decide → target events grouped by target id.
  let whenSourceCmd = async ((sourceHistory, targetHistory): scenario, sourceId, cmd) => {
    targetErrors := []
    let sourceEvents = execSource(sourceHistory, cmd)
    let targetActions =
      sourceEvents
      ->Array.map(sourceEvent =>
        M.map(sourceId->Source.Id.makeFromString, sourceEvent, queryEngine)
      )
      ->Array.flat
    let targetHistories = targetHistory->Dict.fromArray
    let commands = (
      await targetActions
      ->Array.map(async action =>
        switch action {
        | Publish(id, command) => [(id, command)]
        | PublishDelayed(id, command, _) => [(id, command)]
        | PublishAsync(p) => await p
        | _ => []
        }
      )
      ->Promise.all
    )->Array.flat
    commands->Array.reduce(Dict.make(), (targetEvents, (id, command)) => {
      let idStr = id->Target.Id.toString
      let hist = targetHistories->Dict.get(idStr)->Option.getOr([])
      let newEvents = execTarget(hist, command)
      targetEvents->Dict.set(
        idStr,
        targetEvents->Dict.get(idStr)->Option.getOr([])->Array.concat(newEvents),
      )
      targetEvents
    })
  }

  // -- Encoders ------------------------------------------------------------

  let encTargetEvent = (e: Target.event) => e->Message.encode(Target.eventSchema)
  let encTargetEvents = evs => evs->Array.map(encTargetEvent)
  let encSourceError = (err: Source.error) => err->Message.encode(Source.errorSchema)
  let encTargetError = (err: Target.error) => err->Message.encode(Target.errorSchema)

  let encDict = (d: dict<array<Target.event>>): array<JSON.t> =>
    d
    ->Dict.toArray
    ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    ->Array.map(((id, events)) => {
      let obj = Dict.make()
      obj->Dict.set("id", JSON.Encode.string(id))
      obj->Dict.set("events", JSON.Encode.array(events->encTargetEvents))
      JSON.Encode.object(obj)
    })

  let encExpected = (pairs: array<(string, array<Target.event>)>): array<JSON.t> =>
    pairs
    ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    ->Array.map(((id, events)) => {
      let obj = Dict.make()
      obj->Dict.set("id", JSON.Encode.string(id))
      obj->Dict.set("events", JSON.Encode.array(events->encTargetEvents))
      JSON.Encode.object(obj)
    })

  // Surface a source/target error not expected by the current assertion.
  let unexpectedSideError = (actualDict: dict<array<Target.event>>): Outcome.outcome => {
    let actualEvents = encDict(actualDict)
    switch sourceErrors.contents->Array.get(0) {
    | Some(srcErr) =>
      Outcome.fail(
        ErrorMismatch({
          expected: JSON.Encode.null,
          actual: Some(encSourceError(srcErr)),
          actualEvents,
        }),
      )
    | None =>
      switch targetErrors.contents->Array.get(0) {
      | Some(tgtErr) =>
        Outcome.fail(
          ErrorMismatch({
            expected: JSON.Encode.null,
            actual: Some(encTargetError(tgtErr)),
            actualEvents,
          }),
        )
      | None => Outcome.pass
      }
    }
  }

  let dictPairsEq = (a: dict<array<Target.event>>, b: dict<array<Target.event>>) => {
    let ka = a->Dict.keysToArray->Array.toSorted(String.compare)
    let kb = b->Dict.keysToArray->Array.toSorted(String.compare)
    ka == kb &&
      ka->Array.every(k => {
        let av = a->Dict.get(k)->Option.getOr([])
        let bv = b->Dict.get(k)->Option.getOr([])
        av == bv
      })
  }

  // -- Then combinators ----------------------------------------------------

  let thenTargetEvents = async (targetEvents, expectedTargetEvents) => {
    let actualDict = await targetEvents
    switch unexpectedSideError(actualDict) {
    | Error(_) as out => out
    | Ok() =>
      let expectedDict = expectedTargetEvents->Dict.fromArray
      if dictPairsEq(actualDict, expectedDict) {
        Outcome.pass
      } else {
        Outcome.fail(
          EventsMismatch({
            expected: encExpected(expectedTargetEvents),
            actual: encDict(actualDict),
          }),
        )
      }
    }
  }

  let thenTargetEvent = async (targetEvents, id, expectedTargetEvent) => {
    let actualDict = await targetEvents
    switch unexpectedSideError(actualDict) {
    | Error(_) as out => out
    | Ok() =>
      let pairs = actualDict->Dict.toArray
      let ok =
        pairs->Array.length == 1 &&
          switch pairs->Array.get(0) {
          | Some((actualId, [actualEvent])) =>
            actualId == id && actualEvent == expectedTargetEvent
          | _ => false
          }
      if ok {
        Outcome.pass
      } else {
        Outcome.fail(
          EventsMismatch({
            expected: encExpected([(id, [expectedTargetEvent])]),
            actual: encDict(actualDict),
          }),
        )
      }
    }
  }

  let thenNoTargetEvent = targetEvents => thenTargetEvents(targetEvents, [])

  let thenSourceError = async (targetEvents, expectedError) => {
    let actualDict = await targetEvents
    let actualEvents = encDict(actualDict)
    let expectedJson = encSourceError(expectedError)
    switch sourceErrors.contents->Array.get(0) {
    | None =>
      Outcome.fail(
        ErrorMismatch({expected: expectedJson, actual: None, actualEvents}),
      )
    | Some(actual) if actual != expectedError =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedJson,
          actual: Some(encSourceError(actual)),
          actualEvents,
        }),
      )
    | Some(_) => Outcome.pass
    }
  }

  let thenTargetError = async (targetEvents, expectedError) => {
    let actualDict = await targetEvents
    let actualEvents = encDict(actualDict)
    let expectedJson = encTargetError(expectedError)
    switch targetErrors.contents->Array.get(0) {
    | None =>
      Outcome.fail(
        ErrorMismatch({expected: expectedJson, actual: None, actualEvents}),
      )
    | Some(actual) if actual != expectedError =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedJson,
          actual: Some(encTargetError(actual)),
          actualEvents,
        }),
      )
    | Some(_) => Outcome.pass
    }
  }

  let thenTargetEventsWithError = async (targetEvents, expectedTargetEvents, expectedError) => {
    let actualDict = await targetEvents
    let actualEvents = encDict(actualDict)
    let expectedErrorJson = encTargetError(expectedError)
    switch targetErrors.contents->Array.get(0) {
    | None =>
      Outcome.fail(
        ErrorMismatch({expected: expectedErrorJson, actual: None, actualEvents}),
      )
    | Some(actual) if actual != expectedError =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedErrorJson,
          actual: Some(encTargetError(actual)),
          actualEvents,
        }),
      )
    | Some(_) =>
      let expectedDict = expectedTargetEvents->Dict.fromArray
      if dictPairsEq(actualDict, expectedDict) {
        Outcome.pass
      } else {
        Outcome.fail(
          EventsMismatch({
            expected: encExpected(expectedTargetEvents),
            actual: actualEvents,
          }),
        )
      }
    }
  }
}
