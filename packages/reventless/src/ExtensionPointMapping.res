open ReventlessSpec.ExtensionPointMapping

/* these actions are internal to the Mapping Functor */
type abstractCommandAction =
  | AbstractPublishCommand(Aggregate.name, string, Message.commandJson)
  | AbstractCall(string, unit => Js.Promise.t<unit>)

type abstractEventAction<'extensionPointEvent> =
  | AbstractPublishEvent(string, Message.meta, Js.Json.t)
  | AbstractPublishEventAsync(Js.Promise.t<(string, Message.meta, Js.Json.t)>)
  | AbstractCall(unit => Js.Promise.t<unit>)

module type T = {
  module ExtensionPoint: Spec

  let aggregateName: string

  let mapIncomingCommands: (
    array<
      CommandTopic.topicItem<Message.command'<ReventlessSpec.Id.String.t, ExtensionPoint.command>>,
    >,
    ReventlessSpec.Schedule.create,
    ReventlessSpec.Schedule.delete,
    ReventlessSpec.QueryEngine.operations,
  ) => array<abstractCommandAction>

  let mapOutgoingEvent: option<
    (
      Js.Json.t,
      ReventlessSpec.Schedule.create,
      ReventlessSpec.Schedule.delete,
      ReventlessSpec.QueryEngine.operations,
    ) => array<abstractEventAction<ExtensionPoint.event>>,
  >
}

module Make = (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec): (
  T with module ExtensionPoint := Spec
) => {
  module Aggregate = MappingImpl.Aggregate
  let aggregateName = Aggregate.name
  let extensionPointName = Spec.name

  let doMapIncomingCommands = (
    mapIncomingEventImpl,
    topicItems,
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) =>
    topicItems
    ->Belt.Array.map(({
      CommandTopic.reference: reference,
      command: {Message.id: id, command, meta},
    }) =>
      mapIncomingEventImpl(
        id->ReventlessSpec.Id.String.toString,
        command,
        meta,
      )->Belt.Array.map(x =>
        switch x {
        | PublishCommand(aggregateId, aggregateCmd) =>
          let commandStr = aggregateCmd->Aggregate.command_encode->Js.Json.stringify
          Js.log(
            `ExtensionPointMapping incoming from ExtensionPoint ${extensionPointName} to Aggregate ${aggregateName}: Publishing command: ${commandStr} id: ${aggregateId}`,
          )

          AbstractPublishCommand(
            aggregateName,
            reference,
            {
              id: aggregateId,
              meta: {
                ...meta,
                service: Aggregate.name,
                msgId: Message.uuid(),
              },
              commandJson: aggregateCmd->Aggregate.command_encode,
              delay: None,
            },
          )
        | Call(handler, callCommand) =>
          Js.log2(
            `ExtensionPointMapping incoming from ExtensionPoint ${extensionPointName}: Handling call command`,
            callCommand->Spec.callCommand_encode->Js.Json.stringify,
          )

          AbstractCall(
            reference,
            () => handler(createSchedule, deleteSchedule, queryEngine, callCommand),
          )
        }
      )
    )
    ->Belt.Array.concatMany

  let mapIncomingCommands = doMapIncomingCommands(MappingImpl.mapIncomingCommand, ...)

  let doMapOutgoingEvent = (
    mapOutgoingEventImpl,
    aggregateEvent'Json,
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) =>
    switch Message.event'_decode(
      Aggregate.Id.t_decode,
      Aggregate.event_decode,
      aggregateEvent'Json,
    ) {
    | Ok({id, meta, event}) =>
      mapOutgoingEventImpl(id->Aggregate.Id.toString, event, meta, queryEngine)->Belt.Array.map(x =>
        switch x {
        | PublishEvent(id, event) =>
          let eventJson = event->Spec.event_encode
          Js.log(
            `ExtensionPointMapping: outgoing from Aggregate ${aggregateName} to ExtensionPoint ${extensionPointName}: Publishing event: ${eventJson->Js.Json.stringify} id: ${id}`,
          )
          let meta = {
            ...meta,
            service: Spec.name,
            msgId: Message.uuid(),
          }
          AbstractPublishEvent(id, meta, eventJson)
        | PublishEventAsync(promise) =>
          let toEvent' = async promise => {
            let (id, event) = await promise
            let eventJson = event->Spec.event_encode
            Js.log(
              `ExtensionPointMapping: async outgoing from Aggregate ${aggregateName} to ExtensionPoint ${extensionPointName}: Publishing event: ${eventJson->Js.Json.stringify} id: ${id}`,
            )
            (id, meta, eventJson)
          }
          AbstractPublishEventAsync(promise->toEvent')
        | Call(handler, msg) =>
          Js.log2(
            `ExtensionPointMapping: outgoing from Aggregate ${aggregateName}: Handling call command`,
            msg->Spec.callCommand_encode->Js.Json.stringify,
          )

          AbstractCall(() => handler(createSchedule, deleteSchedule, queryEngine, msg))
        }
      )
    | Error(err) =>
      Js.log2("ExtensionPointMapping.mapOutgoing: Error: Decode failure: ", err)
      []
    }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Belt.Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
