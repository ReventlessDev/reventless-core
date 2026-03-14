module type Spec = {
  let pluginDefinition: Reventless.Plugin.pluginDefinition
  let outgoingExtensionPointJsonEventsHandlers: array<ExtensionPoint.jsonEventsHandler>
}

module type T = {
  let handleJsonEvents: EventCollector.jsonEventsHandler
}

module Make = (Spec: Spec): T => {
  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(eventJson' =>
      Effect.logInfo(
        `Admin handleJsonEvents: outgoing event: ${LogFormat.event'JsonToLogMessage(eventJson')}`,
      )->Effect.zipRight(
        Effect.all(
          Spec.outgoingExtensionPointJsonEventsHandlers->Array.map(handleEvent =>
            Effect.promise(() => handleEvent(eventJson', Spec.pluginDefinition))
          ),
          {"concurrency": "unbounded"},
        )->Effect.map(_ => ())
      )
    )
    ->Stream.runDrain
}
