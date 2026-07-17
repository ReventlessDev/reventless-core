// Output.t-free counterpart of Reventless.AutomationSlice.outputs.
// Sub-type of Plugin.resolvedOutputs; holds subscription resources and TODO list database.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
  queryDb: QueryDb.resolvedOutputs,
}
