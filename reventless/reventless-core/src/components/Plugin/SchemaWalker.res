// SchemaWalker — runtime sury schema introspection for Plugin_BuiltHook.
//
// Walks an S.t<unknown> schema and produces a Plugin_BuiltHook.typeSchema
// describing its fields, constructors, and a stable structural hash.
//
// Follows the same Union/Object/Number/Boolean constructor names used by
// SchemaType.res (which are the real sury constructors, not Float/Bool/Int).

open Plugin_BuiltHook

// ---------------------------------------------------------------------------
// Type description — maps a sury schema node to a human-readable string.
// Optional fields in sury are Union({anyOf}) containing Null or Undefined.
// ---------------------------------------------------------------------------
let rec describeSchema = (schema: S.t<unknown>): string =>
  switch schema {
  | String({const: ?Some(_)}) => "string"
  | String(_) => "string"
  | Number(_) => "number"
  | Boolean(_) => "bool"
  | BigInt(_) => "bigint"
  | Null(_) => "null"
  | Union({anyOf}) =>
    // Nullable/optional field: Union of Null/Undefined + one real type.
    let nonNull = anyOf->Array.filter(v =>
      switch v {
      | Null(_) | Undefined(_) => false
      | _ => true
      }
    )
    switch nonNull->Array.get(0) {
    | Some(inner) => "option<" ++ describeSchema(inner) ++ ">"
    | None => "unknown"
    }
  | Array({additionalItems}) =>
    let itemDesc = switch additionalItems {
    | Schema(s) => describeSchema(s)
    | _ => "unknown"
    }
    "array<" ++ itemDesc ++ ">"
  | Object(_) => "object"
  | _ => "unknown"
  }

// Returns true if the schema represents an optional field
// (Union containing Null or Undefined).
let isOptionalSchema = (schema: S.t<unknown>): bool =>
  switch schema {
  | Union({anyOf}) =>
    anyOf->Array.some(v =>
      switch v {
      | Null(_) | Undefined(_) => true
      | _ => false
      }
    )
  | _ => false
  }

// ---------------------------------------------------------------------------
// Field extraction from an Object({properties}) schema.
// ---------------------------------------------------------------------------
let extractFields = (properties: dict<S.t<unknown>>): array<fieldSchema> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((name, fieldSch)) =>
    // Skip the TAG discriminator — it's an internal sury marker.
    if name == "TAG" {
      None
    } else {
      let isRequired = !isOptionalSchema(fieldSch)
      Some({
        name,
        typeDescription: describeSchema(fieldSch),
        isRequired,
      })
    }
  )
  ->Array.toSorted((a, b) => String.compare(a.name, b.name))

// ---------------------------------------------------------------------------
// Hash computation — SHA256 over sorted "name:type:required" tuples.
// ---------------------------------------------------------------------------
let hashFields = (fields: array<fieldSchema>): string => {
  let dict =
    fields
    ->Array.map(f => (f.name, f.typeDescription ++ ":" ++ (f.isRequired ? "1" : "0")))
    ->Dict.fromArray
  HashObj.hashDict(~dict, ~options={algorithm: SHA256})
}

let hashConstructors = (ctors: array<constructorSchema>): string => {
  let dict =
    ctors
    ->Array.toSorted((a, b) => String.compare(a.name, b.name))
    ->Array.map(c => (c.name, hashFields(c.fields)))
    ->Dict.fromArray
  HashObj.hashDict(~dict, ~options={algorithm: SHA256})
}

// ---------------------------------------------------------------------------
// TAG entry helper — extracts the const string value from the "TAG" entry of
// a sury Object's `properties` dict (the alpha.5 location of the variant
// discriminant; the alpha.4 `items` array no longer exists).
// ---------------------------------------------------------------------------
let tagConstOf = (properties: dict<S.t<unknown>>): option<string> =>
  properties
  ->Dict.get("TAG")
  ->Option.flatMap(s =>
    switch s {
    | String({const: ?Some(v)}) => Some(v)
    | _ => None
    }
  )

// ---------------------------------------------------------------------------
// Main walker — converts an S.t<unknown> to a typeSchema.
// ---------------------------------------------------------------------------
let walkSchema = (typeName: string, schema: S.t<unknown>): typeSchema =>
  switch schema {
  | Object({properties}) =>
    let fields = extractFields(properties)
    {
      typeName,
      kind: "record",
      fields,
      structuralHash: hashFields(fields),
    }
  | Union({anyOf}) =>
    // Check if this is a nullable scalar vs. a true variant union.
    let hasNullLike = anyOf->Array.some(v =>
      switch v {
      | Null(_) | Undefined(_) => true
      | _ => false
      }
    )
    if hasNullLike {
      // It's an optional/nullable scalar at the top level, treat as unknown.
      {typeName, kind: "unknown", fields: [], structuralHash: ""}
    } else {
      let constructors =
        anyOf->Array.filterMap(variantSchema =>
          switch variantSchema {
          | Object({properties}) =>
            tagConstOf(properties)->Option.map(name => {
              name,
              fields: extractFields(properties),
            })
          | _ => None
          }
        )
      {
        typeName,
        kind: "variant",
        fields: [],
        constructors: constructors,
        structuralHash: hashConstructors(constructors),
      }
    }
  | _ => {typeName, kind: "unknown", fields: [], structuralHash: ""}
  }

// ---------------------------------------------------------------------------
// Convenience: walk a typed schema (casts to unknown internally).
// ---------------------------------------------------------------------------
let walk = (typeName: string, schema: S.t<'a>): typeSchema =>
  walkSchema(typeName, schema->S.castToUnknown)
