// Shared utility: convert sury S.t<'a> schemas to JSON Schema objects.
// Used by MCP_SchemaGenerator (for MCP tool inputSchema) and can also
// back GraphQL_FragmentGenerator if refactored later.

let isTagged = Reventless.DcbTag.isTagged

// ── Helpers ──────────────────────────────────────────────────────────────

let str = JSON.Encode.string

let jsonObject = (entries: array<(string, JSON.t)>): JSON.t =>
  JSON.Encode.object(Dict.fromArray(entries))

// ── Scalar → JSON Schema ─────────────────────────────────────────────────

/** Map a sury field schema to a JSON Schema type object. */
let rec deriveFieldSchema = (fieldSchema: S.t<unknown>): JSON.t => {
  if isTagged(fieldSchema) {
    jsonObject([("type", str("string")), ("format", str("uuid"))])
  } else {
    switch fieldSchema {
    | String(_) => jsonObject([("type", str("string"))])
    | Number(_) => jsonObject([("type", str("number"))])
    | Boolean(_) => jsonObject([("type", str("boolean"))])
    | BigInt(_) => jsonObject([("type", str("integer"))])
    | Array({items}) =>
      let itemSchema = switch items->Array.get(0) {
      | Some({schema}) => deriveFieldSchema(schema->(Obj.magic: S.t<unknown> => S.t<unknown>))
      | None => jsonObject([("type", str("string"))])
      }
      jsonObject([("type", str("array")), ("items", itemSchema)])
    | Object(_) => deriveObjectSchema(fieldSchema)
    | Union({anyOf}) =>
      let schemas = anyOf->Array.map(s => deriveFieldSchema(s))
      jsonObject([("oneOf", JSON.Encode.array(schemas))])
    | Null(_) => jsonObject([("type", str("null"))])
    | _ => jsonObject([("type", str("string"))])
    }
  }
}

/** Map a sury Object schema to a JSON Schema object with properties and required. */
and deriveObjectSchema = (schema: S.t<unknown>): JSON.t =>
  switch schema {
  | Object({properties}) =>
    let props = Dict.make()
    let required: array<string> = []
    properties
    ->Dict.toArray
    ->Array.forEach(((fieldName, fieldSchema)) => {
      if fieldName !== "TAG" {
        props->Dict.set(fieldName, deriveFieldSchema(fieldSchema))
        required->Array.push(fieldName)
      }
    })
    let entries: array<(string, JSON.t)> = [
      ("type", str("object")),
      ("properties", JSON.Encode.object(props)),
    ]
    if required->Array.length > 0 {
      entries->Array.push(("required", JSON.Encode.array(required->Array.map(JSON.Encode.string))))
    }
    jsonObject(entries)
  | _ => jsonObject([("type", str("object"))])
  }

// ── Variant command → per-variant JSON Schemas ───────────────────────────

/** Derive a JSON Schema for a single command variant (Object within a Union).
    Strips the TAG field (sury discriminator). */
let deriveVariantSchema = (variantSchema: S.t<unknown>): JSON.t =>
  switch variantSchema {
  | Object({properties}) =>
    let props = Dict.make()
    let required: array<string> = []
    properties
    ->Dict.toArray
    ->Array.forEach(((fieldName, fieldSchema)) => {
      if fieldName !== "TAG" {
        props->Dict.set(fieldName, deriveFieldSchema(fieldSchema))
        required->Array.push(fieldName)
      }
    })
    let entries: array<(string, JSON.t)> = [
      ("type", str("object")),
      ("properties", JSON.Encode.object(props)),
    ]
    if required->Array.length > 0 {
      entries->Array.push(("required", JSON.Encode.array(required->Array.map(JSON.Encode.string))))
    }
    jsonObject(entries)
  | _ => jsonObject([("type", str("object"))])
  }

// ── Full schema → JSON Schema ────────────────────────────────────────────

/** Convert any sury schema to a JSON Schema object. Top-level entry point. */
let toJsonSchema = (schema: S.t<unknown>): JSON.t => deriveFieldSchema(schema)
