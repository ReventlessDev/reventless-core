// Output.t-free counterpart of Reventless.OutboundTranslationSlice.outputs.
// Sub-type of Plugin.resolvedOutputs; holds subscription resources and TODO list database.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
  queryDb: QueryDb.resolvedOutputs,
}
