// Output.t-free counterpart of Reventless.Adapter.resource.
// Pulumi resolves all pending Output.t<string> fields before serializing stack exports,
// so every field here is a plain string.

// `sortKey` carries sury's default `option` encoding — the key is omitted rather than
// written as `null` — matching `reventless-spec`'s `Plugin.res` and the rest of the repo.
// The `T | null` it used to carry worked around a sury bug that rejected `undefined` in a
// union variant payload as non-jsonable; fixed in 11.0.0-alpha.11. This is stack-export
// metadata read through StackReference, so a `pulumi up` is all the change needs.

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
  tags: dict<string>,
}
