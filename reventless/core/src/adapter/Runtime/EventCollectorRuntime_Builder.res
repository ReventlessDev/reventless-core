module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forEventCollector: Runtime.forEventCollector<
    Runtime.effectInvocationHandler<EventCollectorChannel.callbackEvent, context, unit, string>,
    EventCollector.component,
  >
  let finish: unit => unit
}
