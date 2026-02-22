// Output.t-free counterpart of ReventlessSpec.CommandTopic.outputs.
// Sub-type of ExtensionPoint.resolvedOutputs; holds the queue URN so extensions
// can locate the topic to publish commands to.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
}
