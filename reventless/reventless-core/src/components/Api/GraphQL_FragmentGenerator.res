// GraphQL schema fragment generator.
// Derives GraphQL SDL fragments from sury schemas (commandSchema, stateSchema)
// using the same introspection patterns as DcbTag.res.

open ReventlessInfra.Api

// Reuse DcbTag introspection helpers
let isTagged = Reventless.DcbTag.isTagged
let extractEventTypes = Reventless.DcbTag.extractEventTypes

// ── Scalar derivation ─────────────────────────────────────────────────────

/**
Map a sury schema to its GraphQL scalar type name.
`@s.matches(DcbTag.string)` annotated fields → `ID!` (content-based routing key).
*/
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
Derive a GraphQL type definition from an Object sury schema.
Returns something like:  `type Product { id: ID! name: String price: Float }`
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
Derive a plural wrapper type for list queries.
e.g. `type Catalog_Products { nextToken: String  scannedCount: Int!  items: [Catalog_Product!]! }`
*/
let derivePluralWrapperType = (~pluralTypeName: string, ~singularTypeName: string): string =>
  `type ${pluralTypeName} {\n  nextToken: String\n  scannedCount: Int!\n  items: [${singularTypeName}!]!\n}`

// ── Query field derivation ─────────────────────────────────────────────────

let deriveObjectQueryField = (
  ~singleFieldName: string,
  ~typeName: string,
  ~authorization: option<Reventless.ReadModel.authorization>,
): string => {
  let authDirective = switch authorization {
  | Some({group}) => ` @aws_auth(cognito_groups: ["${group}"])`
  | None => ""
  }
  `  ${singleFieldName}(id: ID!): ${typeName}${authDirective}`
}

let deriveListQueryField = (
  ~listFieldName: string,
  ~pluralTypeName: string,
  ~authorization: option<Reventless.ReadModel.authorization>,
): string => {
  let authDirective = switch authorization {
  | Some({group}) => ` @aws_auth(cognito_groups: ["${group}"])`
  | None => ""
  }
  `  ${listFieldName}(nextToken: String, limit: Int): ${pluralTypeName}!${authDirective}`
}

// ── Mutation field derivation ──────────────────────────────────────────────

/**
Derive a GraphQL mutation field from a single variant Object schema.
e.g. AddCategory({categoryId: ID!, name: String}) → `  AddCategory(categoryId: ID!, name: String!): String!`
*/
let deriveMutationFieldFromObject = (
  ~fieldName: string,
  variantSchema: S.t<unknown>,
  ~authorization: option<Reventless.ReadModel.authorization>,
): option<string> => {
  let authDirective = switch authorization {
  | Some({group}) => `\n    @aws_auth(cognito_groups: ["${group}"])`
  | None => ""
  }
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
    Some(`  ${fieldName}${argsPart}: String!${authDirective}`)
  | _ => None
  }
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
          deriveMutationFieldFromObject(~fieldName, variantSchema, ~authorization=None)
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
        deriveMutationFieldFromObject(~fieldName, schema, ~authorization=None)
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
      let typeDef = deriveObjectType(~typeName=entry.returnTypeName, entry.stateSchema)
      typeDef->Option.forEach(t => types->Array.push(t))
    }

    // Single query field
    let singleField = deriveObjectQueryField(
      ~singleFieldName=entry.singleFieldName,
      ~typeName=entry.returnTypeName,
      ~authorization=entry.authorization,
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
        ~authorization=entry.authorization,
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
