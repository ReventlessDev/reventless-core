// Shared utility: convert sury S.t<'a> schemas to JSON Schema objects.
// Uses SchemaType as the shared intermediate representation.

// ── Helpers ──────────────────────────────────────────────────────────────

let str = JSON.Encode.string

let jsonObject = (entries: array<(string, JSON.t)>): JSON.t =>
  JSON.Encode.object(Dict.fromArray(entries))

// ── SchemaType → JSON Schema ─────────────────────────────────────────────

let rec fromSchemaType = (st: SchemaType.schemaType): JSON.t =>
  switch st {
  | ScalarString => jsonObject([("type", str("string"))])
  | ScalarNumber => jsonObject([("type", str("number"))])
  | ScalarBoolean => jsonObject([("type", str("boolean"))])
  | ScalarBigInt => jsonObject([("type", str("integer"))])
  | EntityId => jsonObject([("type", str("string")), ("format", str("uuid"))])
  | Nullable(inner) =>
    let innerSchema = fromSchemaType(inner)
    jsonObject([("oneOf", JSON.Encode.array([innerSchema, jsonObject([("type", str("null"))])]))])
  | ArrayOf(item) =>
    jsonObject([("type", str("array")), ("items", fromSchemaType(item))])
  | ObjectRef(_, fields) => objectRefToJsonSchema(fields)
  | Enum(_, values) =>
    jsonObject([
      ("type", str("string")),
      ("enum", JSON.Encode.array(values->Array.map(JSON.Encode.string))),
    ])
  | Unknown => jsonObject([("type", str("string"))])
  }

and objectRefToJsonSchema = (fields: dict<SchemaType.schemaType>): JSON.t => {
  let props = Dict.make()
  let required: array<string> = []
  fields
  ->Dict.toArray
  ->Array.forEach(((fieldName, fieldType)) => {
    props->Dict.set(fieldName, fromSchemaType(fieldType))
    required->Array.push(fieldName)
  })
  let entries: array<(string, JSON.t)> = [
    ("type", str("object")),
    ("properties", JSON.Encode.object(props)),
  ]
  if required->Array.length > 0 {
    entries->Array.push(("required", JSON.Encode.array(required->Array.map(JSON.Encode.string))))
  }
  jsonObject(entries)
}

// ── Public API (sury → JSON Schema via SchemaType) ───────────────────────

let deriveObjectSchema = (schema: S.t<unknown>): JSON.t =>
  switch SchemaType.fromSuryObject(~typeName="", schema) {
  | Some(fields) => objectRefToJsonSchema(fields)
  | None => jsonObject([("type", str("object"))])
  }

let toJsonSchema = (schema: S.t<unknown>): JSON.t =>
  fromSchemaType(SchemaType.fromSury(~parentName="", ~fieldName="", schema))
