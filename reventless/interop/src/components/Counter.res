// Output.t-free counterpart of Counter.outputs.
// Sub-type of EventMapper.resolvedOutputs; not a separate primary stack export.

@schema
type queryDb = {resources: array<Resource.t>}

@schema
type resolvedOutputs = {
  referencesDb: queryDb,
  countsDb: queryDb,
}
