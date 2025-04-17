module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forEventCollector: Runtime.forComponent<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    runtimeParts,
    EventCollector.component,
  >
  let finish: unit => unit
}
