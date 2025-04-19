module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forSideEffectHandlerEventCollector: Runtime.forEventCollector<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    EventCollector.component,
  >
  let forPluginEventCollector: Runtime.forEventCollector<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    EventCollector.component,
  >
  let forPluginHeartbeat: Runtime.forComponent<
    Runtime.eventHandler<unit, context, unit>,
    runtimeParts,
    Heartbeat.component,
  >
  // let forDeadLetterQueue: Runtime.forComponent<'h, runtimeParts, Plugin.component>
  let finish: Plugin.component => unit
}
