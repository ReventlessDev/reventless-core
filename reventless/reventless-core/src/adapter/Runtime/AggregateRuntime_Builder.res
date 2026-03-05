module type T = {
  type context
  type runtimeParts
  module CommandTopicChannel: CommandTopic_Adapter.Channel
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forCommandGenerator: Runtime.forComponent<
    CommandGenerator.effectEventHandler<context>,
    runtimeParts,
    CommandGenerator.component,
  >
  let forCommandTopic: Runtime.forComponent<
    Runtime.effectHandler<CommandTopicChannel.callbackEvent, context, unit, string>,
    runtimeParts,
    CommandTopic.component<'op>,
  >
  let forEventCollector: Runtime.forEventCollector<
    Runtime.effectHandler<EventCollectorChannel.callbackEvent, context, unit, string>,
    EventCollector.component,
  >
  let finish: unit => unit
}
