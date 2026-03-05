module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forPluginEventCollector: Runtime.forEventCollector<
    Runtime.effectHandler<EventCollectorChannel.callbackEvent, context, unit, string>,
    EventCollector.component,
  >
  let forPluginHeartbeat: Runtime.forComponent<
    Runtime.eventHandler<unit, context, unit>,
    runtimeParts,
    Heartbeat.component,
  >
  let forDcbCommandTopic: Runtime.forComponent<
    Runtime.effectHandler<'callbackEvent, context, unit, string>,
    runtimeParts,
    CommandTopic.component<'op>,
  >
  // let forDeadLetterQueue: Runtime.forComponent<'h, runtimeParts, Plugin.component>
  let finish: unit => unit
}
