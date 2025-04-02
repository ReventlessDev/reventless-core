type environmentBuilder<'event, 'context, 'result, 'parts, 'component> = (
  ~handler: Pulumi.Output.t<Runtime.eventHandler<'event, 'context, 'result>>,
  ~memorySize: int=?,
  ~timeout: int=?,
  'component,
) => Runtime.environment<'parts>

module type T = {
  type context
  type parts

  let forAggregateCommandGenerator: environmentBuilder<
    'event,
    context,
    'result,
    parts,
    CommandGenerator.component,
  >
  let forAggregateCommandTopic: environmentBuilder<
    'event,
    context,
    'result,
    parts,
    CommandTopic.component<'op>,
  >
  let forAggregateEventCollector: environmentBuilder<
    'event,
    context,
    'result,
    parts,
    EventCollector.component,
  >
  let forReadModelEventCollector: environmentBuilder<
    'event,
    context,
    'result,
    parts,
    EventCollector.component,
  >
  let forExtensionPointCommandTopic: environmentBuilder<
    'event,
    context,
    'result,
    parts,
    CommandTopic.component<'op>,
  >
  let forSideEffectHandlerEventCollector: environmentBuilder<
    'event,
    context,
    'result,
    parts,
    EventCollector.component,
  >
  let forPluginEventCollector: environmentBuilder<
    'event,
    context,
    'result,
    parts,
    EventCollector.component,
  >
  let forPluginHeartbeat: environmentBuilder<'event, context, 'result, parts, Heartbeat.component>
  let forDeadLetterQueue: environmentBuilder<'event, context, 'result, parts, Plugin.component>
}
