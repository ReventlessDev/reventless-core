// Output.t-free counterpart of Reventless.EventTopic.outputs.
// Sub-type of ExtensionPoint.resolvedOutputs; holds the topic URN so extensions
// can subscribe to events published by this extension point.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
}
