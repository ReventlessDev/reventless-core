module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forEventCollector: Runtime.forEventCollector<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    EventCollector.component,
  >
  let finish: unit => unit
}
