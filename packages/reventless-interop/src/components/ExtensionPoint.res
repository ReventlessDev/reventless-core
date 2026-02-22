// Output.t-free counterpart of ReventlessSpec.ExtensionPoint.outputs.
// Sub-type of Plugin.resolvedOutputs; not a separate primary stack export.
// Consumers read commandTopic.resources and eventTopic.resources to locate
// the queue/topic URNs needed to connect an extension.

@schema
type resolvedOutputs = {
  name: string,
  commandTopic: CommandTopic.resolvedOutputs,
  eventTopic: EventTopic.resolvedOutputs,
}
