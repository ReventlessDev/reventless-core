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
  let handleEventEffect = (eventJson', jsonEventsHandlersByService) =>
    eventJson'
    ->Message.serviceNameOfMsg
    ->Option.flatMap(serviceName => jsonEventsHandlersByService->Dict.get(serviceName))
    ->Option.mapOr(Effect.succeed(), jsonEventsHandlers =>
      Effect.all(
        jsonEventsHandlers->Array.map(jsonEventsHandler =>
          Effect.promise(() => jsonEventsHandler(eventJson', Spec.pluginDefinition))
        ),
        {"concurrency": "unbounded"},
      )->Effect.map(_ => ())
    )

  let detectUnhandledEventEffect = eventJson' =>
    eventJson'
    ->Message.serviceNameOfMsg
    ->Option.mapOr(Effect.succeed(), serviceName =>
      switch (
        Spec.outgoingExtensionPointEventHandlers->Dict.get(serviceName),
        Spec.outgoingExtensionEventHandlers->Dict.get(serviceName),
        Spec.incomingExtensionEventHandlers->Dict.get(serviceName),
      ) {
      | (None, None, None) => Effect.logInfo("No mapping matches service name")
      | _ => Effect.succeed()
      }
    )

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(eventJson' => {
      let id = Spec.pluginDefinition.id
      Effect.logInfo(
        `Plugin ${id} handleJsonEvents: incoming event: ${LogFormat.event'JsonToLogMessage(
            eventJson',
          )}`,
      )
      ->Effect.zipRight(detectUnhandledEventEffect(eventJson'))
      ->Effect.zipRight(
        handleEventEffect(eventJson', Spec.incomingConnectExtensionEventHandlers)
        ->Effect.zipRight(
          Effect.all(
            [
              handleEventEffect(eventJson', Spec.outgoingExtensionPointEventHandlers),
              handleEventEffect(eventJson', Spec.outgoingExtensionEventHandlers),
              handleEventEffect(eventJson', Spec.incomingExtensionEventHandlers),
            ],
            {"concurrency": "unbounded"},
          )->Effect.map(_ => ())
        )
      )
    })
    ->Stream.runDrain
}
