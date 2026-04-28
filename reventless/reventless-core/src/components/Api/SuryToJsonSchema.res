// Shared utility: convert sury S.t<'a> schemas to JSON Schema objects.
// Uses SchemaType as the shared intermediate representation.

// ── Helpers ──────────────────────────────────────────────────────────────

let str = JSON.Encode.string

let jsonObject = (entries: array<(string, JSON.t)>): JSON.t =>
  JSON.Encode.object(Dict.fromArray(entries))

// Merge x-reventless-* extension properties from a Reventless.StateAnnotations.stateAnnotationSpec
// into a property schema (a JSON Schema object). Returns the schema unchanged when the field
// has no annotations or when the schema is not a JSON object.
let mergeAnnotations = (
  fieldSchema: JSON.t,
  fieldName: string,
  spec: Reventless.StateAnnotations.stateAnnotationSpec,
): JSON.t =>
  switch fieldSchema->JSON.Decode.object {
  | None => fieldSchema
  | Some(obj) =>
    if spec.ids->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-id", JSON.Encode.bool(true))
    }
    if spec.compositeIds->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-compositeId", JSON.Encode.bool(true))
    }
    if spec.subIds->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-subId", JSON.Encode.bool(true))
    }
    if spec.compositeSubIds->Array.includes(fieldName) {
      obj->Dict.set("x-reventless-compositeSubId", JSON.Encode.bool(true))
    }
    switch spec.indexes->Array.find(((field, _)) => field === fieldName) {
    | Some((_, indexName)) =>
      let value =
        indexName === "" ? JSON.Encode.bool(true) : JSON.Encode.string(indexName)
      obj->Dict.set("x-reventless-index", value)
    | None => ()
    }
    JSON.Encode.object(obj)
  }

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

and objectRefToJsonSchema = (
  ~annotations: option<Reventless.StateAnnotations.stateAnnotationSpec>=?,
  fields: dict<SchemaType.schemaType>,
): JSON.t => {
  let props = Dict.make()
  let required: array<string> = []
  fields
  ->Dict.toArray
  ->Array.forEach(((fieldName, fieldType)) => {
    let baseSchema = fromSchemaType(fieldType)
    let withAnnotations = switch annotations {
    | Some(spec) => mergeAnnotations(baseSchema, fieldName, spec)
    | None => baseSchema
    }
    props->Dict.set(fieldName, withAnnotations)
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
  | Some(fields) =>
    let annotations = Reventless.StateAnnotations.getSpec(schema)
    objectRefToJsonSchema(~annotations?, fields)
  | None => jsonObject([("type", str("object"))])
  }

let toJsonSchema = (schema: S.t<unknown>): JSON.t =>
  fromSchemaType(SchemaType.fromSury(~parentName="", ~fieldName="", schema))
