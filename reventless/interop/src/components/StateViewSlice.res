// Output.t-free counterpart of Reventless.StateViewSlice.outputs.
// Sub-type of Plugin.resolvedOutputs; holds subscription resources and query database.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
  queryDb: QueryDb.resolvedOutputs,
}
