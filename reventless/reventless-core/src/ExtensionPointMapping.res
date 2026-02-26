open ReventlessSpec.ExtensionPointMapping

// abstractCommandAction, abstractEventAction, and module type T are defined in
// ReventlessSpec.ExtensionPointMapping and brought into scope via `open` above.

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
    ->Array.map(({ReventlessSpec.CommandTopic.reference: reference, command: {Message.id: id, command, meta}}) =>
      mapIncomingEventImpl(id->ReventlessSpec.Id.String.toString, command, meta)->Array.map(x =>
        switch x {
        | PublishCommand(aggregateId, aggregateCmd) =>
          let commandStr = aggregateCmd->Message.encode(Aggregate.commandSchema)->JSON.stringify
          Console.log(
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
              commandJson: aggregateCmd->Message.encode(Aggregate.commandSchema),
            },
          )
        | Call(handler, directive) =>
          Console.log2(
            `ExtensionPointMapping incoming from ExtensionPoint ${extensionPointName}: Handling directive`,
            directive->Message.encode(Spec.directiveSchema)->JSON.stringify,
          )

          AbstractCall(
            reference,
            () => handler(createSchedule, deleteSchedule, queryEngine, directive),
          )
        }
      )
    )
    ->Array.flat

  let mapIncomingCommands = doMapIncomingCommands(MappingImpl.mapIncomingCommand, ...)

  let doMapOutgoingEvent = (
    mapOutgoingEventImpl,
    aggregateEventJson',
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) =>
    switch aggregateEventJson'->Message.decodeEvent'(Aggregate.Id.schema, Aggregate.eventSchema) {
    | {id, meta, event} =>
      mapOutgoingEventImpl(
        id->Aggregate.Id.toString,
        event,
        meta,
        queryEngine,
      )->Array.map(eventAction =>
        switch eventAction {
        | PublishEvent(id, event) =>
          let eventJson = event->Message.encode(Spec.eventSchema)
          Console.log(
            `ExtensionPointMapping: outgoing from Aggregate ${aggregateName} to ExtensionPoint ${extensionPointName}: Publishing event: ${eventJson->JSON.stringify} id: ${id}`,
          )
          let meta = {
            ...meta,
            service: Spec.name,
            msgId: Message.uuid(),
          }
          let eventJson' = Message.composeEventJson'(id, meta, eventJson)
          AbstractPublishEvent(id, meta, eventJson')
        | PublishEventAsync(promise) =>
          let toEvent' = async promise => {
            let (id, event) = await promise
            let eventJson = event->Message.encode(Spec.eventSchema)
            Console.log(
              `ExtensionPointMapping: async outgoing from Aggregate ${aggregateName} to ExtensionPoint ${extensionPointName}: Publishing event: ${eventJson->JSON.stringify} id: ${id}`,
            )
            let eventJson' = Message.composeEventJson'(id, meta, eventJson) // TODO: check if meta is correct
            (id, meta, eventJson')
          }
          AbstractPublishEventAsync(promise->toEvent')
        | Call(handler, directive) =>
          Console.log2(
            `ExtensionPointMapping: outgoing from Aggregate ${aggregateName}: Handling directive`,
            directive->Message.encode(Spec.directiveSchema)->JSON.stringify,
          )

          AbstractCall(() => handler(createSchedule, deleteSchedule, queryEngine, directive))
        }
      )
    | exception err =>
      Console.log2("ExtensionPointMapping.mapOutgoing: Error: Decode failure: ", err)
      []
    }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
