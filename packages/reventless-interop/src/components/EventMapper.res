// Output.t-free counterpart of ReventlessSpec.EventMapper.outputs.
// Primary cross-stack export: every plugin stack exports an "eventMappers" array
// of these records.

@schema
type resolvedOutputs = {
  name: string,
  eventCollector: EventCollector.resolvedOutputs,
  counter?: Counter.resolvedOutputs,
}
