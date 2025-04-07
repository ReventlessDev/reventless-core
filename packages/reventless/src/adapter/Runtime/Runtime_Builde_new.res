type environmentBuilder<'handler, 'parts, 'component> = (
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

  let forAggregateCommandGenerator: environmentBuilder<
    CommandGenerator.commandGenerator,
    parts,
    CommandGenerator.component,
  >
  let forAggregateCommandTopic: environmentBuilder<
    Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    parts,
    CommandTopic.component<'op>,
  >
  let forAggregateEventCollector: environmentBuilder<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    parts,
    EventCollector.component,
  >
  let forReadModelEventCollector: environmentBuilder<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    parts,
    EventCollector.component,
  >
  let forExtensionPointCommandTopic: environmentBuilder<
    Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    parts,
    CommandTopic.component<'op>,
  >
  let forSideEffectHandlerEventCollector: environmentBuilder<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    parts,
    EventCollector.component,
  >
  let forPluginEventCollector: environmentBuilder<
    Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    parts,
    EventCollector.component,
  >
  let forPluginHeartbeat: environmentBuilder<'h, parts, Heartbeat.component>
  let forDeadLetterQueue: environmentBuilder<'h, parts, Plugin.component>
}
