open ReventlessCore

module type T = {
  module Source: Reventless.Aggregate.Spec
  module Target: Reventless.Aggregate.Spec

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit

  let givenSourceEvents: array<Source.event> => array<Source.event>
  let givenTargetEvents: (
    array<(string, array<Target.event>)>,
    array<Source.event>,
  ) => (array<(string, array<Target.event>)>, array<Source.event>)

  let whenSourceCmd: (
    string,
    Source.command,
    (array<(string, array<Target.event>)>, array<Source.event>),
  ) => promise<dict<array<Target.event>>>

  let thenTargetEvents: (
    array<(string, array<Target.event>)>,
    promise<dict<array<Target.event>>>,
  ) => promise<Outcome.outcome>

  let thenTargetEvent: (
    string,
    Target.event,
    promise<dict<array<Target.event>>>,
  ) => promise<Outcome.outcome>

  let thenNoTargetEvent: promise<dict<array<Target.event>>> => promise<Outcome.outcome>
}

module type Aggregate = {
  module Spec: Reventless.Aggregate.Spec
  module Behavior: ReventlessCore.Behavior.T

  let currentState: array<Spec.event> => Behavior.state
  let errors: ref<array<Spec.error>>
  let exec: (Spec.command, array<Spec.event>) => array<Spec.event>
}

module MakeAggregate = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
) => {
  module Spec = Spec
  module Behavior = Behavior

  let currentState = events =>
    events->Array.reduce(Behavior.initialState, Behavior.evolve)

  let errors = ref([])

  let exec = (command, history): array<Spec.event> => {
    errors := []
    let state = currentState(history)
    switch Behavior.decide(state, command) {
    | Ok(events) => events
    | Error(error) =>
      errors := [error]
      []
    }
  }
}

module Make = (
  Source: Reventless.Aggregate.Spec,
  SourceBehavior: Behavior.T with module Spec = Source,
  Target: Reventless.Aggregate.Spec,
  TargetBehavior: Behavior.T with module Spec = Target,
  EventMapping: Reventless.EventMapping.T
    with module Source = Source
    and module Target := Target,
): (T with module Source = Source and module Target = Target) => {
  module Source = Source
  module Target = Target

  module SourceAggregate = MakeAggregate(Source, SourceBehavior)
  module TargetAggregate = MakeAggregate(Target, TargetBehavior)

  let describe = JestBind.describe
  let test = JestBind.testPromise

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

  let givenSourceEvents = sourceHistory => sourceHistory
  let givenTargetEvents = (targetHistory, sourceHistory) => (targetHistory, sourceHistory)

  let whenSourceCmd = async (sourceId, cmd, (targetHistory, sourceHistory)) => {
    let sourceEvents = SourceAggregate.exec(cmd, sourceHistory)
    let targetActions =
      sourceEvents
      ->Array.map(sourceEvent =>
        EventMapping.map(sourceId->Source.Id.makeFromString, sourceEvent, queryEngine)
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
      let id = id->Target.Id.toString
      let targetHistory =
        targetHistories
        ->Dict.get(id)
        ->Option.getOr([])
        ->Array.concat(targetEvents->Dict.get(id)->Option.getOr([]))
      let newEvents = TargetAggregate.exec(command, targetHistory)
      targetEvents->Dict.set(
        id,
        targetEvents->Dict.get(id)->Option.getOr([])->Array.concat(newEvents),
      )
      targetEvents
    })
  }

  let encTargetEvent = (e: Target.event) => e->Message.encode(Target.eventSchema)
  let encTargetEvents = evs => evs->Array.map(encTargetEvent)
  let encSourceError = (err: Source.error) => err->Message.encode(Source.errorSchema)
  let encTargetError = (err: Target.error) => err->Message.encode(Target.errorSchema)

  // Render the dict as a sorted array of (id, [encoded events...]) pairs,
  // then wrap in a JSON array of `[id, events...]` rows so the Outcome payload
  // preserves the source id.
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

  let unexpectedSideError = (actualDict: dict<array<Target.event>>): Outcome.outcome => {
    let actualEvents = encDict(actualDict)
    switch SourceAggregate.errors.contents->Array.get(0) {
    | Some(srcErr) =>
      Outcome.fail(
        ErrorMismatch({
          expected: JSON.Encode.null,
          actual: Some(encSourceError(srcErr)),
          actualEvents,
        }),
      )
    | None =>
      switch TargetAggregate.errors.contents->Array.get(0) {
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

  let thenTargetEvents = async (expectedTargetEvents, targetEvents) => {
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

  let thenTargetEvent = async (id, expectedTargetEvent, targetEvents) => {
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

  let thenNoTargetEvent = targetEvents => thenTargetEvents([], targetEvents)
}
