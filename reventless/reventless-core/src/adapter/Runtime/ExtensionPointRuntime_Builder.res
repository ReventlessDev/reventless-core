module type T = {
  type context
  type runtimeParts
  module CommandTopicChannel: CommandTopic_Adapter.Channel

  let forCommandTopic: Runtime.forComponent<
    Runtime.effectHandler<CommandTopicChannel.callbackEvent, context, unit, string>,
    runtimeParts,
    CommandTopic.component<'op>,
  >
}
