type eventHandler = (JSON.t, Reventless.Plugin.pluginDefinition) => promise<unit>
type eventHandlersByService = dict<array<eventHandler>>

module type Spec = {
  let pluginDefinition: Reventless.Plugin.pluginDefinition
  let incomingConnectExtensionEventHandlers: eventHandlersByService
  let outgoingExtensionPointEventHandlers: eventHandlersByService
  let outgoingExtensionEventHandlers: eventHandlersByService
  let incomingExtensionEventHandlers: eventHandlersByService
}

module type T = {
  let handleJsonEvents: array<JSON.t> => promise<unit>
}

module Make = (Spec: Spec): T => {
  let handleEvent = async (eventJson', eventHandlersByService) =>
    await eventJson'
    ->Message.serviceNameOfMsg
    ->Option.flatMap(serviceName => eventHandlersByService->Dict.get(serviceName))
    ->Option.mapOr(Promise.resolve(), async eventHandlers => {
      await eventHandlers
      ->Array.map(eventHandler => eventHandler(eventJson', Spec.pluginDefinition))
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

  let handleJsonEvents = eventsJson => {
    let id = Spec.pluginDefinition.id
    let count = eventsJson->Array.length
    eventsJson
    ->Array.mapWithIndex(async (eventJson', idx) => {
      let idx = idx + 1
      eventJson'->Logger.logJsonEvent(
        `Plugin ${id} handleJsonEvents: incoming event ${idx->Int.toString}/${count->Int.toString}:`,
      )
      detectUnhandledEvent(eventJson')
      switch await eventJson'->handleEvent(Spec.incomingConnectExtensionEventHandlers) {
      | _ =>
        [
          eventJson'->handleEvent(Spec.outgoingExtensionPointEventHandlers),
          eventJson'->handleEvent(Spec.outgoingExtensionEventHandlers),
          eventJson'->handleEvent(Spec.incomingExtensionEventHandlers),
        ]->Promise.all
      }
    })
    ->Promise.all
    ->Util.Promise.toUnit
  }
}
