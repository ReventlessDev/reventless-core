module type T = {
  type context
  type runtimeParts
  module CommandTopicChannel: CommandTopic_Adapter.Channel
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forCommandGenerator: Runtime.forComponent<
    CommandGenerator.eventHandler<context>,
    runtimeParts,
    CommandGenerator.component,
  >
  let forCommandTopic: Runtime.forComponent<
    Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    runtimeParts,
    CommandTopic.component<'op>,
  >
  let forEventCollector: Runtime.forComponent<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    runtimeParts,
    EventCollector.component,
  >
}
