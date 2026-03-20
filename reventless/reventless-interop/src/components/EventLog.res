// Output.t-free counterpart of Reventless.EventLog.outputs.
// Sub-type of Aggregate.resolvedOutputs; holds the event store and event topic resources.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
  eventTopic: EventTopic.resolvedOutputs,
}
