module type T = {
  type context
  type runtimeParts
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let registerPluginName: string => unit
  let forPluginEventCollector: Runtime.forEventCollector<
    Runtime.effectInvocationHandler<EventCollectorChannel.callbackEvent, context, unit, string>,
    EventCollector.component,
  >
  let forPluginHeartbeat: Runtime.forComponent<
    Runtime.invocationHandler<unit, context, unit>,
    runtimeParts,
    Heartbeat.component,
  >
  let forDcbCommandTopic: Runtime.forComponent<
    Runtime.effectInvocationHandler<'callbackEvent, context, unit, string>,
    runtimeParts,
    CommandTopic.component<'op>,
  >
  // let forDeadLetterQueue: Runtime.forComponent<'h, runtimeParts, Plugin.component>
  let finish: unit => unit
}
