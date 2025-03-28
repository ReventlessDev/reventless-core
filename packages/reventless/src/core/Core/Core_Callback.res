type eventHandler = (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>

module type Spec = {
  let pluginDefinition: ReventlessSpec.Plugin.pluginDefinition
  let outgoingExtensionPointEventHandlers: array<eventHandler>
}

module Make = (Spec: Spec) => {
  let eventsHandler = events'Json => {
    let count = events'Json->Belt.Array.size
    events'Json
    ->Belt.Array.mapWithIndex(async (idx, event'Json) => {
      let idx = idx + 1
      event'Json->Logger.logJsonEvent(
        `Core eventHandler: outgoing event ${idx->Belt.Int.toString}/${count->Belt.Int.toString}:`,
      )
      Spec.outgoingExtensionPointEventHandlers
      ->Belt.Array.map(handleEvent => {
        handleEvent(event'Json, Spec.pluginDefinition)
      })
      ->Js.Promise.all
      ->Util.Promise.toUnit
    })
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}
