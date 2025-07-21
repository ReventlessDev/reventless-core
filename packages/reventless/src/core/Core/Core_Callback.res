module type Spec = {
  let pluginDefinition: ReventlessSpec.Plugin.pluginDefinition
  let outgoingExtensionPointEventHandlers: array<ExtensionPoint.eventHandler>
}

module type T = {
  let handleJsonEvents: array<Js.Json.t> => Js.Promise.t<unit>
}

module Make = (Spec: Spec): T => {
  let handleJsonEvents = eventsJson' => {
    let count = eventsJson'->Array.length
    eventsJson'
    ->Array.mapWithIndex(async (eventJson', idx) => {
      let idx = idx + 1
      eventJson'->Logger.logJsonEvent(
        `Core eventHandler: outgoing event ${idx->Int.toString}/${count->Int.toString}:`,
      )
      Spec.outgoingExtensionPointEventHandlers
      ->Array.map(handleEvent => {
        handleEvent(eventJson', Spec.pluginDefinition)
      })
      ->Js.Promise.all
      ->Util.Promise.toUnit
    })
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}
