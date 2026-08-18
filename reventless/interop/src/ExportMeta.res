// The reventless-interop package version emitted in every _interopMeta stack export.
// Bump this according to the SemVer policy in the interop plan when types change.
let version = "0.1.0-alpha.0"

// Metadata written alongside named stack outputs in every plugin stack.
// `fields` maps each export name ("tasks", "eventMappers", "plugin") to the list
// of field names actually present in the serialized JSON for that export.
// The field list is derived automatically from actual values via `fieldNamesOf` —
// optional fields only appear when the corresponding value is Some.
@schema
type t = {
  version: string,
  fields: dict<array<string>>,
}

// Serialize `value` using its sury schema and return the top-level JSON object
// keys present in the result.  Optional fields are omitted by sury when None,
// so absent optional fields will NOT appear in the returned array — which is
// exactly the behaviour needed for the field manifest.
let fieldNamesOf = (value: 'a, schema: S.t<'a>): array<string> =>
  value
  ->S.decodeOrThrow(~from=schema, ~to=S.json)
  ->JSON.Decode.object
  ->Option.mapOr([], Dict.keysToArray)
