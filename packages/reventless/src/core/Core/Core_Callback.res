type eventHandler = (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>

module type Spec = {
  let pluginDefinition: ReventlessSpec.Plugin.pluginDefinition
  let outgoingExtensionPointEventHandlers: array<eventHandler>
}

module Make = (Spec: Spec) => {
  let eventsHandler = eventsJson' => {
    let count = eventsJson'->Belt.Array.size
    eventsJson'
    ->Belt.Array.mapWithIndex(async (idx, eventJson') => {
      let idx = idx + 1
      eventJson'->Logger.logJsonEvent(
        `Core eventHandler: outgoing event ${idx->Belt.Int.toString}/${count->Belt.Int.toString}:`,
      )
      Spec.outgoingExtensionPointEventHandlers
      ->Belt.Array.map(handleEvent => {
        handleEvent(eventJson', Spec.pluginDefinition)
      })
      ->Js.Promise.all
      ->Util.Promise.toUnit
    })
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}
