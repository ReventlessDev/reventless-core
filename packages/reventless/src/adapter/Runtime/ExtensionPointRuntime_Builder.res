module type T = {
  type context
  type runtimeParts
  module CommandTopicChannel: CommandTopic_Adapter.Channel

  let forCommandTopic: Runtime.forComponent<
    Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    runtimeParts,
    CommandTopic.component<'op>,
  >
}
