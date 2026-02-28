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
      Effect.promise(async () => {
        eventJson'->Logger.logJsonEvent(`Core handleJsonEvents: outgoing event:`)
        let _ = await Spec.outgoingExtensionPointJsonEventsHandlers
          ->Array.map(handleEvent => handleEvent(eventJson', Spec.pluginDefinition))
          ->Promise.all
      })
    )
    ->Stream.runDrain
}
