module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forPluginEventCollector: Runtime.forEventCollector<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    EventCollector.component,
  >
  let forPluginHeartbeat: Runtime.forComponent<
    Runtime.eventHandler<unit, context, unit>,
    runtimeParts,
    Heartbeat.component,
  >
  let forDcbCommandTopic: Runtime.forComponent<
    Runtime.eventHandler<'callbackEvent, context, unit>,
    runtimeParts,
    CommandTopic.component<'op>,
  >
  // let forDeadLetterQueue: Runtime.forComponent<'h, runtimeParts, Plugin.component>
  let finish: unit => unit
}
