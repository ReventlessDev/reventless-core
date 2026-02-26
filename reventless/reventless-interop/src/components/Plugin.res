// Output.t-free counterpart of Reventless.Plugin.outputs (primary cross-stack export).
// Only the fields that are actually accessed cross-stack are declared here;
// optional markers allow old publishers (that may lack new fields) to still validate.

@schema
type resolvedOutputs = {
  id: string,
  version: string,
  readModels?: dict<ReadModel.resolvedOutputs>,
  extensionPoints?: dict<ExtensionPoint.resolvedOutputs>,
}
