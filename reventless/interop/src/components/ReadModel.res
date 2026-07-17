// Output.t-free counterpart of Reventless.ReadModel.outputs.
// Sub-type of Plugin.resolvedOutputs; consumers access queryDb.resources to
// connect their QueryEngine to a remote read model's DynamoDB table.

@schema
type queryDb = {resources: array<Resource.t>}

@schema
type resolvedOutputs = {
  name: string,
  queryDb: queryDb,
  sourceNames: array<string>,
}
