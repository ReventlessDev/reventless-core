module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forSideEffectHandlerEventCollector: Runtime.forComponent<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    runtimeParts,
    EventCollector.component,
  >
  let forPluginEventCollector: Runtime.forComponent<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    runtimeParts,
    EventCollector.component,
  >
  let forPluginHeartbeat: Runtime.forComponent<
    Runtime.eventHandler<unit, context, unit>,
    runtimeParts,
    Heartbeat.component,
  >
  // let forDeadLetterQueue: Runtime.forComponent<'h, runtimeParts, Plugin.component>
}
