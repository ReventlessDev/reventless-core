// GraphQL schema fragment generator.
// Derives GraphQL SDL fragments from sury schemas (commandSchema, stateSchema)
// using the same introspection patterns as DcbTag.res.

open ReventlessInfra.Api

// Reuse DcbTag introspection helpers
let isTagged = Reventless.DcbTag.isTagged
let extractEventTypes = Reventless.DcbTag.extractEventTypes

// ── Field type derivation (recursive) ───────────────────────────────────────

/**
Derive the GraphQL type reference for a schema field, collecting any
nested type/enum definitions into `collectedTypes`.
Returns the type reference string (e.g. "String", "[Extension!]!", "Status").
*/
let rec deriveFieldType = (
  ~parentTypeName: string,
  ~fieldName: string,
  ~required: bool,
  fieldSchema: S.t<unknown>,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let bang = required ? "!" : ""
  if isTagged(fieldSchema) {
    `ID${bang}`
  } else {
    switch fieldSchema {
    | String(_) => `String${bang}`
    | Number(_) => `Float${bang}`
    | Boolean(_) => `Boolean${bang}`
    | Array({additionalItems: Schema(itemSchema)}) =>
      let itemType = deriveFieldType(
        ~parentTypeName,
        ~fieldName,
        ~required=true,
        itemSchema,
        collectedTypes,
        seenTypes,
      )
      `[${itemType}]${bang}`
    | Object({properties}) =>
      let nestedTypeName =
        parentTypeName ++ fieldName->String.charAt(0)->String.toUpperCase ++ fieldName->String.slice(~start=1, ~end=fieldName->String.length)
      if !(seenTypes->Set.has(nestedTypeName)) {
        seenTypes->Set.add(nestedTypeName)
        let typeDef = deriveObjectTypeDeep(~typeName=nestedTypeName, properties, collectedTypes, seenTypes)
        collectedTypes->Array.push(typeDef)
      }
      `${nestedTypeName}${bang}`
    | Union({anyOf}) =>
      // Check if this is an option (union with null) or an enum (union of string consts)
      let nonNullVariants = anyOf->Array.filter(v =>
        switch v {
        | Null(_) => false
        | _ => true
        }
      )
      if nonNullVariants->Array.length == 1 {
        // Option<T> — unwrap and derive the inner type as nullable
        let inner = nonNullVariants->Array.getUnsafe(0)
        deriveFieldType(~parentTypeName, ~fieldName, ~required=false, inner, collectedTypes, seenTypes)
      } else {
        // Check if all variants are string consts → GraphQL enum
        let constValues = nonNullVariants->Array.filterMap(v =>
          switch v {
          | String({const: ?Some(c)}) => Some(c)
          | _ => None
          }
        )
        if constValues->Array.length == nonNullVariants->Array.length && constValues->Array.length > 0 {
          let enumName =
            parentTypeName ++ fieldName->String.charAt(0)->String.toUpperCase ++ fieldName->String.slice(~start=1, ~end=fieldName->String.length)
          if !(seenTypes->Set.has(enumName)) {
            seenTypes->Set.add(enumName)
            let values = constValues->Array.join("\n  ")
            collectedTypes->Array.push(`enum ${enumName} {\n  ${values}\n}`)
          }
          `${enumName}${bang}`
        } else {
          `String${bang}`
        }
      }
    | _ => `String${bang}`
    }
  }
}

/**
Derive a GraphQL type definition with recursive nested type support.
Collects nested type definitions into `collectedTypes`.
*/
and deriveObjectTypeDeep = (
  ~typeName: string,
  properties: dict<S.t<unknown>>,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let fields =
    properties
    ->Dict.toArray
    ->Array.map(((fieldName, fieldSchema)) => {
      let gqlType = deriveFieldType(
        ~parentTypeName=typeName,
        ~fieldName,
        ~required=true,
        fieldSchema,
        collectedTypes,
        seenTypes,
      )
      `  ${fieldName}: ${gqlType}`
    })
    ->Array.join("\n")
  `type ${typeName} {\n${fields}\n}`
}

// ── Scalar derivation (legacy, used by mutation arg derivation) ─────────────

let deriveScalarType = (fieldSchema: S.t<unknown>): string => {
  if isTagged(fieldSchema) {
    "ID!"
  } else {
    switch fieldSchema {
    | String(_) => "String"
    | Number(_) => "Float"
    | Boolean(_) => "Boolean"
    | _ => "String"
    }
  }
}

// ── Object type derivation ─────────────────────────────────────────────────

/**
Derive a GraphQL type definition from an Object sury schema (flat scalars only).
For schemas with nested types, use `deriveObjectTypeDeep` instead.
*/
let deriveObjectType = (~typeName: string, schema: S.t<unknown>): option<string> =>
  switch schema {
  | Object({properties}) =>
    let fields =
      properties
      ->Dict.toArray
      ->Array.map(((fieldName, fieldSchema)) => {
        let gqlType = deriveScalarType(fieldSchema)
        `  ${fieldName}: ${gqlType}`
      })
      ->Array.join("\n")
    Some(`type ${typeName} {\n${fields}\n}`)
  | _ => None
  }

/**
Derive a GraphQL type definition with full nested type support.
Returns an array of type definitions (the main type + any nested types/enums).
Optionally excludes fields by name.
*/
let deriveObjectTypeWithNested = (
  ~typeName: string,
  ~excludeFields: array<string>=[],
  schema: S.t<unknown>,
): array<string> =>
  switch schema {
  | Object({properties}) =>
    let collectedTypes: array<string> = []
    let seenTypes = Set.make()
    seenTypes->Set.add(typeName)
    let filteredProps = if excludeFields->Array.length > 0 {
      let d = Dict.make()
      properties
      ->Dict.toArray
      ->Array.forEach(((k, v)) => {
        if !(excludeFields->Array.some(ex => ex == k)) {
          d->Dict.set(k, v)
        }
      })
      d
    } else {
      properties
    }
    let mainType = deriveObjectTypeDeep(~typeName, filteredProps, collectedTypes, seenTypes)
    Array.concat(collectedTypes, [mainType])
  | _ => []
  }

/**
Derive a plural wrapper type for list queries.
e.g. `type Catalog_Products { nextToken: String  scannedCount: Int!  items: [Catalog_Product!]! }`
*/
let derivePluralWrapperType = (~pluralTypeName: string, ~singularTypeName: string): string =>
  `type ${pluralTypeName} {\n  nextToken: String\n  scannedCount: Int!\n  items: [${singularTypeName}!]!\n}`

// ── Query field derivation ─────────────────────────────────────────────────

let deriveObjectQueryField = (
  ~singleFieldName: string,
  ~typeName: string,
): string =>
  `  ${singleFieldName}(id: ID!): ${typeName}`

let deriveListQueryField = (
  ~listFieldName: string,
  ~pluralTypeName: string,
): string =>
  `  ${listFieldName}(nextToken: String, limit: Int): ${pluralTypeName}!`

// ── Mutation field derivation ──────────────────────────────────────────────

/**
Derive a GraphQL mutation field from a single variant Object schema.
e.g. AddCategory({categoryId: ID!, name: String}) → `  AddCategory(categoryId: ID!, name: String!): String!`
*/
let deriveMutationFieldFromObject = (
  ~fieldName: string,
  variantSchema: S.t<unknown>,
): option<string> =>
  switch variantSchema {
  | Object({properties}) =>
    let args =
      properties
      ->Dict.toArray
      ->Array.filter(((argName, _)) => argName !== "TAG")
      ->Array.map(((argName, argSchema)) => {
        let gqlType = deriveScalarType(argSchema)
        `${argName}: ${gqlType}`
      })
      ->Array.join(", ")
    let argsPart = args->String.length > 0 ? `(${args})` : ""
    Some(`  ${fieldName}${argsPart}: String!`)
  | _ => None
  }

// ── Main generate function ─────────────────────────────────────────────────

/**
Generate a GraphQL schema fragment from mutation and query entries.

Mutation entries are derived from aggregate command schemas (Union variants)
and DCB StateChangeSlice command schemas (single-variant schemas).

Query entries are derived from ReadModel and StateViewSlice state schemas.

Returns an `apiSchemaFragment` with the encoded JSON SDL and protocol="graphql".
*/
let generate = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let types: array<string> = []
  let mutations: array<string> = []
  let queries: array<string> = []
  let seenTypes = Set.make()

  // Process mutation entries
  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    switch schema {
    | Union({anyOf}) =>
      // Aggregate command union: pair each fieldName[i] with anyOf[i].
      // Prepend "id: ID!" — aggregate commands target a specific instance.
      anyOf->Array.forEachWithIndex((variantSchema, i) => {
        let fieldName = entry.fieldNames->Array.get(i)->Option.getOr("")
        if fieldName->String.length > 0 {
          deriveMutationFieldFromObject(~fieldName, variantSchema)
          ->Option.forEach(field => {
            let withId = if field->String.includes("(") {
              // Has other args — prepend id
              field->String.replace(`${fieldName}(`, `${fieldName}(id: ID!, `)
            } else {
              // No args — add (id: ID!)
              field->String.replace(`${fieldName}:`, `${fieldName}(id: ID!):`)
            }
            mutations->Array.push(withId)
          })
        }
      })
    | Object(_) =>
      // Single-variant / plain object command (e.g. DCB slice)
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        deriveMutationFieldFromObject(~fieldName, schema)
        ->Option.forEach(field => mutations->Array.push(field))
      }
    | _ => ()
    }
  })

  // Process query entries
  queryEntries->Array.forEach(entry => {
    // Derive the singular return type definition from the state schema (deduplicated)
    if !(seenTypes->Set.has(entry.returnTypeName)) {
      seenTypes->Set.add(entry.returnTypeName)
      let excludeFields = switch entry.excludeFields {
      | Some(fields) => fields
      | None => []
      }
      let nestedTypes = deriveObjectTypeWithNested(
        ~typeName=entry.returnTypeName,
        ~excludeFields,
        entry.stateSchema,
      )
      nestedTypes->Array.forEach(t => {
        types->Array.push(t)
      })
    }

    // Single query field
    let singleField = deriveObjectQueryField(
      ~singleFieldName=entry.singleFieldName,
      ~typeName=entry.returnTypeName,
    )
    queries->Array.push(singleField)

    // Optional list query field with plural wrapper type
    entry.listFieldName->Option.forEach(listFieldName => {
      // Generate plural wrapper type (deduplicated)
      if !(seenTypes->Set.has(listFieldName)) {
        seenTypes->Set.add(listFieldName)
        let pluralType = derivePluralWrapperType(
          ~pluralTypeName=listFieldName,
          ~singularTypeName=entry.returnTypeName,
        )
        types->Array.push(pluralType)
      }

      // List query returns the plural wrapper type
      let listField = deriveListQueryField(
        ~listFieldName,
        ~pluralTypeName=listFieldName,
      )
      queries->Array.push(listField)
    })
  })

  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(mutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(queries->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify

  {Reventless.Plugin.encoded, protocol: "graphql"}
}
