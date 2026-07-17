// Output.t-free counterpart of Reventless.Aggregate.outputs.
// Sub-type of Plugin.resolvedOutputs.
// The addEventMapper callback is not serializable and is omitted.

@schema
type resolvedOutputs = {
  name: string,
  commandGenerator: CommandGenerator.resolvedOutputs,
  commandTopic: CommandTopic.resolvedOutputs,
  eventLog: EventLog.resolvedOutputs,
  eventMapper?: EventMapper.resolvedOutputs,
}
