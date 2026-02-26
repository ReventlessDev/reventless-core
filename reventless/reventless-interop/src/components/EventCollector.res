// Output.t-free counterpart of Reventless.EventCollector.outputs.
// Sub-type of EventMapper.resolvedOutputs; not a separate primary stack export.

@schema
type resolvedOutputs = {
  name: string,
  resources: array<Resource.t>,
}
