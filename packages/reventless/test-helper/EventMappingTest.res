module type T = {
  module Source: ReventlessSpec.Aggregate.Spec
  module Target: ReventlessSpec.Aggregate.Spec

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => Js.Promise.t<Jest.assertion>) => unit

  let givenSourceEvents: array<Source.event> => array<Source.event>
  let givenTargetEvents: (
    array<(string, array<Target.event>)>,
    array<Source.event>,
  ) => (array<(string, array<Target.event>)>, array<Source.event>)

  let whenSourceCmd: (
    string,
    Source.command,
    (array<(string, array<Target.event>)>, array<Source.event>),
  ) => Js.Promise.t<dict<array<Target.event>>>

  let thenTargetEvents: (
    array<(string, array<Target.event>)>,
    Js.Promise.t<dict<array<Target.event>>>,
  ) => Js.Promise.t<Jest.assertion>

  let thenTargetEvent: (
    string,
    Target.event,
    Js.Promise.t<dict<array<Target.event>>>,
  ) => Js.Promise.t<Jest.assertion>

  let thenNoTargetEvent: Js.Promise.t<dict<array<Target.event>>> => Js.Promise.t<Jest.assertion>
  // let thenTargetEventWithError:
  //   (
  //     Target.Id.t,
  //     Target.event,
  //     Target.error,
  //     array((Target.Id.t, array(Target.event)))
  //   ) =>
  //   Jest.assertion;
  // let thenTargetEventsWithError:
  //   (
  //     array((Target.Id.t, array(Target.event))),
  //     Target.error,
  //     array((Target.Id.t, array(Target.event)))
  //   ) =>
  //   Jest.assertion;
  // let thenTargetError:
  //   (Target.error, array((Target.Id.t, array(Target.event)))) =>
  //   Jest.assertion;
}

module type Aggregate = {
  module Spec: ReventlessSpec.Aggregate.Spec
  module Behaviour: Reventless.Behaviour.T

  let apply': (Behaviour.state, Spec.event) => Behaviour.state
  let currentState: array<Spec.event> => Behaviour.state
  let errors: array<Spec.error>
  let errorHandler: Reventless.Message.errorHandler<Spec.error, Spec.command, Spec.event>
  let exec: (Reventless.Message.context, Spec.command, array<Spec.event>) => array<Spec.event>
}

module MakeAggregate = (
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
) => {
  module Spec = Spec
  module Behaviour = Behaviour

  let apply' = (state, event) => Behaviour.apply(state, event)

  let currentState = events =>
    events
    ->Array.sliceToEnd(~start=1)
    ->Array.reduce(Behaviour.init(events->Array.getUnsafe(0)), apply')

  let errors = ref([])

  let errorHandler: Message.errorHandler<Spec.error, Spec.command, Spec.event> = (error, _, _) => {
    errors := Array.concat(errors.contents, [error])
    []
  }

  let exec = (context, command, history): array<Spec.event> => {
    errors := []
    switch history {
    | [] => Behaviour.create(command, context, errorHandler)
    | history =>
      try Behaviour.execute(
        history->currentState,
        command,
        TestFixtures.context,
        errorHandler,
      ) catch {
      | Reventless.Message.InvalidEvent(_) => []
      }
    }
  }
}

module Make = (
  Source: ReventlessSpec.Aggregate.Spec,
  SourceBehaviour: Behaviour.T with module Spec = Source,
  Target: ReventlessSpec.Aggregate.Spec,
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

  let queryEngine: ReventlessSpec.QueryEngine.operations = {
    scan: (~readModelName as _, ~filterConfigs as _, ~limit as _) => []->Js.Promise.resolve,
    query: (
      ~readModelName as _: string,
      ~key as _: option<string>=?,
      ~id as _: ReventlessSpec.QueryEngine.value,
      ~subIdConfig as _: option<ReventlessSpec.QueryEngine.SubId.config>=?,
      ~filterConfigs as _: option<array<ReventlessSpec.QueryEngine.Filter.config>>=?,
      ~ascending as _: option<bool>=?,
      ~limit as _: option<int>=?,
    ) => []->Js.Promise.resolve,
  }

  let givenSourceEvents = sourceHistory => sourceHistory
  let givenTargetEvents = (targetHistory, sourceHistory) => (targetHistory, sourceHistory)

  /*
   TODO: The following functions were unused and are due to be deleted:
     let logSourceEvents = events =>
       events->Array.forEachWithIndex((event, idx) => {
         let eventStr = event->Source.event_encode;
         Js.log({j|Source event[$idx]: $eventStr|j});
       });
     let logTargetCommands = commands => {
       commands->Array.forEachWithIndex(((id, command), idx) => {
         let commandStr = command->Target.command_encode;
         Js.log({j|Target command[$idx]: $commandStr id:$id|j});
       });
       commands;
     };
     let logTargetEvents = events =>
       events->Array.forEachWithIndex((event, idx) => {
         let eventStr = event->Target.event_encode;
         Js.log({j|  new Target event[$idx]: $eventStr|j});
       });
     let logTargetEventsDict = (events, prefix) =>
       events
       ->Js.Dict.entries
       ->Array.forEachWithIndex(((id, events), idx1) =>
           events->Array.forEachWithIndex((event, idx2) => {
             let eventStr = event->Target.event_encode;
             Js.log({j|$prefix Target event[$idx1,$idx2]: $eventStr id:$id|j});
           })
         );
 */

  let whenSourceCmd = async (sourceId, cmd, (targetHistory, sourceHistory)) => {
    let sourceEvents = SourceAggregate.exec(
      {...TestFixtures.context, id: sourceId},
      cmd,
      sourceHistory,
    )
    // sourceEvents->logSourceEvents;
    let targetActions =
      sourceEvents
      ->Array.map(sourceEvent =>
        EventMapping.map(sourceId->Source.Id.makeFromString, sourceEvent, queryEngine)
      )
      ->Array.flat
    let targetHistories = targetHistory->Js.Dict.fromArray
    let commands =
      (await targetActions
      ->Array.map(async action =>
        switch action {
        | Publish(id, command) => [(id, command)]
        | PublishDelayed(id, command, _) => [(id, command)]
        | PublishAsync(p) => await p
        | _ => []
        }
      )
      ->Js.Promise.all)
      ->Array.flat
    //  ->logTargetCommands
    //  newEvents->logTargetEvents;
    commands->Array.reduce(Js.Dict.empty(), (targetEvents, (id, command)) => {
      let id = id->Target.Id.toString
      let targetHistory =
        targetHistories
        ->Js.Dict.get(id)
        ->Option.getOr([])
        ->Array.concat(targetEvents->Js.Dict.get(id)->Option.getOr([]))
      let newEvents = TargetAggregate.exec({...TestFixtures.context, id}, command, targetHistory)
      targetEvents->Js.Dict.set(
        id,
        targetEvents->Js.Dict.get(id)->Option.getOr([])->Array.concat(newEvents),
      )
      targetEvents
    })
  }

  open Jest.Expect

  let thenTargetEvents = async (expectedTargetEvents, targetEvents) => {
    expect((
      SourceAggregate.errors.contents->Array.length,
      TargetAggregate.errors.contents->Array.length,
      await targetEvents,
    ))->toEqual((0, 0, expectedTargetEvents->Js.Dict.fromArray))
  }
  //  events->logTargetEventsDict("");

  let thenTargetEvent = async (id, expectedTargetEvent, targetEvents) => {
    let events = (await targetEvents)->Js.Dict.entries
    expect((
      SourceAggregate.errors.contents->Array.length,
      TargetAggregate.errors.contents->Array.length,
      events->Array.length,
      events->Array.get(0),
    ))->toEqual((0, 0, 1, Some((id, [expectedTargetEvent]))))
  }

  let thenNoTargetEvent = targetEvents => thenTargetEvents([], targetEvents)
}
