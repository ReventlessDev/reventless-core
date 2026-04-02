// Output.t-free counterpart of Reventless.Adapter.resource.
// Pulumi resolves all pending Output.t<string> fields before serializing stack exports,
// so every field here is a plain string.

@schema
type resourceInfo =
  | StorageKeys({partitionKey: string, sortKey: option<string>})
  | StreamSource({sourceUrn: string})
  | ApiResolver({typeName: string, fieldName: string})
  | NoInfo

@schema
type t = {
  name: string,
  id: string,
  urn: string,
  resourceInfo: resourceInfo,
  service: string,
  role: string,
  region: string,
  resourceType: string,
  configuration: dict<string>,
}
