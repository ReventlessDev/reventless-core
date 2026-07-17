// Output.t-free counterpart of Reventless.StateChangeSlice.outputs.
// Sub-type of Plugin.resolvedOutputs; holds the command queue infrastructure resources.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
}
