// Output.t-free counterpart of Reventless.InboundTranslationSlice.outputs.
// Sub-type of Plugin.resolvedOutputs; holds infrastructure resources and audit log database.

@schema
type resolvedOutputs = {
  resources: array<Resource.t>,
  queryDb: QueryDb.resolvedOutputs,
}
