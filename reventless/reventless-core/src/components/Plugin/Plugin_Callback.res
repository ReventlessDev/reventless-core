type jsonEventsHandler = (JSON.t, Reventless.Plugin.pluginDefinition) => promise<unit>
type jsonEventsHandlersByService = dict<array<jsonEventsHandler>>

module type Spec = {
  let pluginDefinition: Reventless.Plugin.pluginDefinition
  let incomingConnectExtensionEventHandlers: jsonEventsHandlersByService
  let outgoingExtensionPointEventHandlers: jsonEventsHandlersByService
  let outgoingExtensionEventHandlers: jsonEventsHandlersByService
  let incomingExtensionEventHandlers: jsonEventsHandlersByService
}

module type T = {
  let handleJsonEvents: EventCollector.jsonEventsHandler
}

module Make = (Spec: Spec): T => {
  let handleEvent = async (eventJson', jsonEventsHandlersByService) =>
    await eventJson'
    ->Message.serviceNameOfMsg
    ->Option.flatMap(serviceName => jsonEventsHandlersByService->Dict.get(serviceName))
    ->Option.mapOr(Promise.resolve(), async jsonEventsHandlers => {
      await jsonEventsHandlers
      ->Array.map(jsonEventsHandler => jsonEventsHandler(eventJson', Spec.pluginDefinition))
      ->Promise.all
      ->Util.Promise.toUnit
    })

  let detectUnhandledEvent = eventJson' =>
    eventJson'
    ->Message.serviceNameOfMsg
    ->Option.mapOr((), serviceName =>
      switch (
        Spec.outgoingExtensionPointEventHandlers->Dict.get(serviceName),
        Spec.outgoingExtensionEventHandlers->Dict.get(serviceName),
        Spec.incomingExtensionEventHandlers->Dict.get(serviceName),
      ) {
      | (None, None, None) => Console.log("No mapping matches service name")
      | _ => ()
      }
    )

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(eventJson' =>
      Effect.promise(async () => {
        let id = Spec.pluginDefinition.id
        eventJson'->Logger.logJsonEvent(`Plugin ${id} handleJsonEvents: incoming event:`)
        detectUnhandledEvent(eventJson')
        switch await eventJson'->handleEvent(Spec.incomingConnectExtensionEventHandlers) {
        | _ =>
          let _ = await [
            eventJson'->handleEvent(Spec.outgoingExtensionPointEventHandlers),
            eventJson'->handleEvent(Spec.outgoingExtensionEventHandlers),
            eventJson'->handleEvent(Spec.incomingExtensionEventHandlers),
          ]->Promise.all
        }
      })
    )
    ->Stream.runDrain
}
