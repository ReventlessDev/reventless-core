// Output.t-free counterpart of Reventless.DcbEventLog.outputs.
// Sub-type of Plugin.resolvedOutputs; holds the event log storage and event topic resources.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
  eventTopic: EventTopic.resolvedOutputs,
}
