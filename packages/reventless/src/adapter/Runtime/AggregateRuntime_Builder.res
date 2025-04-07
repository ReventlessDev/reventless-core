type builder<'handler, 'parts, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~memorySize: int=?,
  ~timeout: int=?,
  'component,
) => Runtime.environment<'parts>

module type T = {
  type context
  type parts
  module CommandTopicChannel: CommandTopic_Adapter.Channel
  module EventCollectorChannel: EventCollector_Adapter.Channel

  let forCommandGenerator: builder<
    CommandGenerator.eventHandler<context>,
    parts,
    CommandGenerator.component,
  >
  let forCommandTopic: builder<
    Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    parts,
    CommandTopic.component<'op>,
  >
  let forEventCollector: builder<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    parts,
    EventCollector.component,
  >
}
