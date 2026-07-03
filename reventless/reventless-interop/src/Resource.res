// Output.t-free counterpart of Reventless.Adapter.resource.
// Pulumi resolves all pending Output.t<string> fields before serializing stack exports,
// so every field here is a plain string.

// A plain `option<string>` field inside a union variant compiles to `string |
// undefined`, which sury rejects as non-jsonable (jsonableValidation, flag 16) —
// `reverseConvertToJsonOrThrow` on `resourceInfo` then throws for *every*
// `StorageKeys` value, `sortKey` present or not. `js_nullable` produces `string
// | null` instead, which is JSON-safe in a union payload. (Same fix as
// `reventless-spec`'s `Plugin.res`.)
@module("sury/src/Sury.res.mjs") external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"
let stringOptionSchema = _jsNullable(S.string, ())

@schema
type resourceInfo =
  | StorageKeys({partitionKey: string, sortKey: @s.matches(stringOptionSchema) option<string>})
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
