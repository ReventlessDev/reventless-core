module type T = {
  module Source: ReventlessSpec.AggregateSpec.T
  module Target: ReventlessSpec.AggregateSpec.T

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => Js.Promise.t<Jest.assertion>) => unit

  let givenSourceEvents: list<Source.event> => list<Source.event>
  let givenTargetEvents: (
    list<(string, list<Target.event>)>,
    list<Source.event>,
  ) => (list<(string, list<Target.event>)>, list<Source.event>)

  let whenSourceCmd: (
    string,
    Source.command,
    (list<(string, list<Target.event>)>, list<Source.event>),
  ) => Js.Promise.t<Js.Dict.t<list<Target.event>>>

  let thenTargetEvents: (
    list<(string, list<Target.event>)>,
    Js.Promise.t<Js.Dict.t<list<Target.event>>>,
  ) => Js.Promise.t<Jest.assertion>

  let thenTargetEvent: (
    string,
    Target.event,
    Js.Promise.t<Js.Dict.t<list<Target.event>>>,
  ) => Js.Promise.t<Jest.assertion>

  let thenNoTargetEvent: Js.Promise.t<Js.Dict.t<list<Target.event>>> => Js.Promise.t<Jest.assertion>
  // let thenTargetEventWithError:
  //   (
  //     Target.Id.t,
  //     Target.event,
  //     Target.error,
  //     list((Target.Id.t, list(Target.event)))
  //   ) =>
  //   Jest.assertion;
  // let thenTargetEventsWithError:
  //   (
  //     list((Target.Id.t, list(Target.event))),
  //     Target.error,
  //     list((Target.Id.t, list(Target.event)))
  //   ) =>
  //   Jest.assertion;
  // let thenTargetError:
  //   (Target.error, list((Target.Id.t, list(Target.event)))) =>
  //   Jest.assertion;
}

module type Aggregate = {
  module Spec: ReventlessSpec.AggregateSpec.T
  module Behaviour: Reventless.Behaviour.T

  let apply': (Behaviour.state, Spec.event) => Behaviour.state
  let currentState: list<Spec.event> => Behaviour.state
  let errors: list<Spec.error>
  let errorHandler: Reventless.Message.errorHandler<Spec.error, Spec.command, Spec.event>
  let exec: (Reventless.Message.context, Spec.command, list<Spec.event>) => list<Spec.event>
}

module MakeAggregate = (
  Spec: ReventlessSpec.AggregateSpec.T,
  Behaviour: Behaviour.T with module Spec := Spec,
) => {
  module Spec = Spec
  module Behaviour = Behaviour

  let apply' = (state, event) => Behaviour.apply(. state, event)

  let currentState = events => {
    open Belt.List
    events->tailExn->reduce(Behaviour.init(. events->headExn), apply')
  }

  let errors = ref(list{})

  let errorHandler: Message.errorHandler<Spec.error, Spec.command, Spec.event> = (error, _, _) => {
    errors := Belt.List.concat(errors.contents, list{error})
    list{}
  }

  let exec = (context, command, history): list<Spec.event> => {
    errors := list{}
    switch history {
    | list{} => Behaviour.create(. command, context, errorHandler)
    | history =>
      try Behaviour.execute(.
        history->currentState,
        command,
        TestFixtures.context,
        errorHandler,
      ) catch {
      | Reventless.Message.InvalidEvent(_) => list{}
      }
    }
  }
}

module Make = (
  Source: ReventlessSpec.AggregateSpec.T,
  SourceBehaviour: Behaviour.T with module Spec = Source,
  Target: ReventlessSpec.AggregateSpec.T,
  TargetBehaviour: Behaviour.T with module Spec = Target,
  EventMapping: ReventlessSpec.EventMapping.T
    with module Source = Source
    and module Target := Target,
): (T with module Source = Source and module Target = Target) => {
  module Source = Source
  module Target = Target

  module SourceAggregate = MakeAggregate(Source, SourceBehaviour)
  module TargetAggregate = MakeAggregate(Target, TargetBehaviour)

  let describe = Jest.describe
  let test = Jest.testPromise

  let queryEngine: ReventlessSpec.QueryEngine.t = {
    scan: (~viewName as _, ~filterConfigs as _, ~limit as _) => []->Js.Promise.resolve,
    query: (
      ~viewName as _: string,
      ~key as _: option<string>=?,
      ~id as _: ReventlessSpec.QueryEngine.value,
      ~filterConfigs as _: option<list<ReventlessSpec.QueryEngine.filterConfig>>=?,
      ~ascending as _: option<bool>=?,
      ~limit as _: option<int>=?,
      _: unit,
    ) => []->Js.Promise.resolve,
  }

  let givenSourceEvents = sourceHistory => sourceHistory
  let givenTargetEvents = (targetHistory, sourceHistory) => (targetHistory, sourceHistory)

  /*
   TODO: The following functions were unused and are due to be deleted:
     let logSourceEvents = events =>
       events->Belt.List.forEachWithIndex((idx, event) => {
         let eventStr = event->Source.event_encode;
         Js.log({j|Source event[$idx]: $eventStr|j});
       });
     let logTargetCommands = commands => {
       commands->Belt.Array.forEachWithIndex((idx, (id, command)) => {
         let commandStr = command->Target.command_encode;
         Js.log({j|Target command[$idx]: $commandStr id:$id|j});
       });
       commands;
     };
     let logTargetEvents = events =>
       events->Belt.List.forEachWithIndex((idx, event) => {
         let eventStr = event->Target.event_encode;
         Js.log({j|  new Target event[$idx]: $eventStr|j});
       });
     let logTargetEventsDict = (events, prefix) =>
       events
       ->Js.Dict.entries
       ->Belt.Array.forEachWithIndex((idx1, (id, events)) =>
           events->Belt.List.forEachWithIndex((idx2, event) => {
             let eventStr = event->Target.event_encode;
             Js.log({j|$prefix Target event[$idx1,$idx2]: $eventStr id:$id|j});
           })
         );
 */

  let whenSourceCmd = (sourceId, cmd, (targetHistory, sourceHistory)) => {
    let sourceEvents = SourceAggregate.exec(
      {...TestFixtures.context, id: sourceId},
      cmd,
      sourceHistory,
    )
    // sourceEvents->logSourceEvents;
    let targetActions =
      sourceEvents
      ->Belt.List.map(sourceEvent =>
        EventMapping.map(.
          sourceId->Source.Id.makeFromString,
          sourceEvent,
          queryEngine,
        )->Belt.List.fromArray
      )
      ->Belt.List.flatten
      ->Belt.List.toArray
    let targetHistories = targetHistory->Js.Dict.fromList
    targetActions
    ->Belt.Array.map(x =>
      switch x {
      | Publish(id, command) => [(id, command)]->Js.Promise.resolve
      | PublishDelayed(id, command, _) => [(id, command)]->Js.Promise.resolve
      | PublishAsync(p) => p
      | _ => []->Js.Promise.resolve
      }
    )
    ->Js.Promise.all
    //  ->logTargetCommands
    //  newEvents->logTargetEvents;
    ->Js.Promise.then_(commands =>
      commands
      ->Belt.Array.concatMany
      ->Belt.Array.reduce(Js.Dict.empty(), (targetEvents, (id, command)) => {
        let id = id->Target.Id.toString
        let targetHistory =
          targetHistories
          ->Js.Dict.get(id)
          ->Belt.Option.getWithDefault(list{})
          ->Belt.List.concat(targetEvents->Js.Dict.get(id)->Belt.Option.getWithDefault(list{}))
        let newEvents = TargetAggregate.exec({...TestFixtures.context, id}, command, targetHistory)
        targetEvents->Js.Dict.set(
          id,
          targetEvents
          ->Js.Dict.get(id)
          ->Belt.Option.getWithDefault(list{})
          ->Belt.List.concat(newEvents),
        )
        targetEvents
      })
      ->Js.Promise.resolve
    , _)
  }

  open Jest.Expect

  let thenTargetEvents = (expectedTargetEvents, targetEvents) =>
    targetEvents->Js.Promise.then_(
      events => {
        let assertion =
          expect((
            SourceAggregate.errors.contents->Belt.List.length,
            TargetAggregate.errors.contents->Belt.List.length,
            events,
          ))->toEqual((0, 0, expectedTargetEvents->Js.Dict.fromList))
        assertion->Js.Promise.resolve
      },
      //  events->logTargetEventsDict("");

      _,
    )

  let thenTargetEvent = (id, expectedTargetEvent, targetEvents) =>
    targetEvents->Js.Promise.then_(eventsDict => {
      let events = eventsDict->Js.Dict.entries
      expect((
        SourceAggregate.errors.contents->Belt.List.length,
        TargetAggregate.errors.contents->Belt.List.length,
        events->Belt.Array.length,
        events->Belt.Array.get(0),
      ))
      ->toEqual((0, 0, 1, Some((id, list{expectedTargetEvent}))))
      ->Js.Promise.resolve
    }, _)

  let thenNoTargetEvent = thenTargetEvents(list{})
  // let thenEventWithError = (expectedEvent, expectedError, events) =>
  //   expect((
  //     events->Belt.List.length,
  //     events->Belt.List.head,
  //     (errors^)->Belt.List.length,
  //     (errors^)->Belt.List.head,
  //   ))
  //   |> toEqual((1, Some(expectedEvent), 1, Some(expectedError)));
  // let thenEventsWithError = (expectedEvents, expectedError, events) =>
  //   expect((events, (errors^)->Belt.List.length, (errors^)->Belt.List.head))
  //   |> toEqual((expectedEvents, 1, Some(expectedError)));
  // let thenError = (expectedError, events) => {
  //   expect((events, (errors^)->Belt.List.length, (errors^)->Belt.List.head))
  //   |> toEqual(([], 1, Some(expectedError)));
  // };
}
