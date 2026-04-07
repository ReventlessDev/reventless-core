// GraphQL schema fragment generator.
// Derives GraphQL SDL fragments from sury schemas (commandSchema, stateSchema)
// using SchemaType as the shared intermediate representation.

open ReventlessInfra.Api

// ── SchemaType → GraphQL type reference ──────────────────────────────────────

let rec fromSchemaType = (
  ~required: bool,
  st: SchemaType.schemaType,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let bang = required ? "!" : ""
  switch st {
  | ScalarString => `String${bang}`
  | ScalarNumber => `Float${bang}`
  | ScalarBoolean => `Boolean${bang}`
  | ScalarBigInt => `String${bang}`
  | EntityId => `ID${bang}`
  | Nullable(inner) => fromSchemaType(~required=false, inner, collectedTypes, seenTypes)
  | ArrayOf(item) =>
    let itemType = fromSchemaType(~required=true, item, collectedTypes, seenTypes)
    `[${itemType}]${bang}`
  | ObjectRef(name, fields) =>
    if !(seenTypes->Set.has(name)) {
      seenTypes->Set.add(name)
      let typeDef = objectRefToGraphQL(name, fields, collectedTypes, seenTypes)
      collectedTypes->Array.push(typeDef)
    }
    `${name}${bang}`
  | Enum(name, values) =>
    if !(seenTypes->Set.has(name)) {
      seenTypes->Set.add(name)
      let valuesStr = values->Array.join("\n  ")
      collectedTypes->Array.push(`enum ${name} {\n  ${valuesStr}\n}`)
    }
    `${name}${bang}`
  | Unknown => `String${bang}`
  }
}

and objectRefToGraphQL = (
  typeName: string,
  fields: dict<SchemaType.schemaType>,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let fieldStrs =
    fields
    ->Dict.toArray
    ->Array.map(((fieldName, fieldType)) => {
      let gqlType = fromSchemaType(~required=true, fieldType, collectedTypes, seenTypes)
      `  ${fieldName}: ${gqlType}`
    })
    ->Array.join("\n")
  `type ${typeName} {\n${fieldStrs}\n}`
}

// ── Legacy bridge: sury → GraphQL via SchemaType ─────────────────────────────

let deriveFieldType = (
  ~parentTypeName: string,
  ~fieldName: string,
  ~required: bool,
  fieldSchema: S.t<unknown>,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let st = SchemaType.fromSury(~parentName=parentTypeName, ~fieldName, fieldSchema)
  fromSchemaType(~required, st, collectedTypes, seenTypes)
}

// ── Object type derivation ─────────────────────────────────────────────────

let deriveObjectTypeWithNested = (
  ~typeName: string,
  ~excludeFields: array<string>=[],
  ~includeIdParam: bool=true,
  schema: S.t<unknown>,
): array<string> =>
  switch SchemaType.fromSuryObject(~typeName, schema) {
  | Some(fields) =>
    let filteredFields = if excludeFields->Array.length > 0 {
      let d = Dict.make()
      fields
      ->Dict.toArray
      ->Array.forEach(((k, v)) => {
        if !(excludeFields->Array.some(ex => ex == k)) {
          d->Dict.set(k, v)
        }
      })
      d
    } else {
      fields
    }
    let collectedTypes: array<string> = []
    let seenTypes = Set.make()
    seenTypes->Set.add(typeName)
    let mainType = objectRefToGraphQL(typeName, filteredFields, collectedTypes, seenTypes)
    let mainTypeWithId = if includeIdParam {
      mainType->String.replace(
        `type ${typeName} {\n`,
        `type ${typeName} implements Node {\n  id: ID!\n`,
      )
    } else {
      mainType
    }
    Array.concat(collectedTypes, [mainTypeWithId])
  | None => []
  }

let derivePluralWrapperType = (~pluralTypeName: string, ~singularTypeName: string): string =>
  `type ${pluralTypeName} {\n  nextToken: String\n  scannedCount: Int!\n  items: [${singularTypeName}!]!\n}`

let deriveConnectionTypes = (~singularTypeName: string): array<string> => [
  `type ${singularTypeName}Edge {\n  node: ${singularTypeName}!\n  cursor: String!\n}`,
  `type ${singularTypeName}Connection {\n  edges: [${singularTypeName}Edge!]!\n  pageInfo: PageInfo!\n  totalCount: Int\n}`,
]

let deriveByIdConnectionType = (~typeName: string): string =>
  `type ${typeName}ByIdConnection {\n  items: [${typeName}!]!\n  nextToken: String\n}`

let deriveByIdConnectionQueryField = (
  ~singleFieldName: string,
  ~returnTypeName: string,
): string =>
  `  ${singleFieldName}ById(id: ID!, prefix: String, from: String, to: String, eq: String, reverse: Boolean, limit: Int, nextToken: String): ${returnTypeName}ByIdConnection!`

// ── Query field derivation ─────────────────────────────────────────────────

let deriveObjectQueryField = (
  ~singleFieldName: string,
  ~typeName: string,
  ~includeIdParam: bool=true,
): string =>
  if includeIdParam {
    `  ${singleFieldName}(id: ID!): ${typeName}`
  } else {
    `  ${singleFieldName}: ${typeName}`
  }

let deriveListQueryField = (
  ~listFieldName: string,
  ~pluralTypeName: string,
): string =>
  `  ${listFieldName}(nextToken: String, limit: Int): ${pluralTypeName}!`

let deriveConnectionQueryField = (
  ~listFieldName: string,
  ~singularTypeName: string,
): string =>
  `  ${listFieldName}(first: Int, after: String, last: Int, before: String): ${singularTypeName}Connection!`

// ── Mutation field derivation ──────────────────────────────────────────────

let deriveMutationFieldFromObject = (
  ~fieldName: string,
  variantSchema: S.t<unknown>,
): option<string> =>
  switch SchemaType.fromSuryObject(~typeName=fieldName, variantSchema) {
  | Some(fields) =>
    let collectedTypes: array<string> = []
    let seenTypes = Set.make()
    let args =
      fields
      ->Dict.toArray
      ->Array.map(((argName, argType)) => {
        let gqlType = fromSchemaType(~required=true, argType, collectedTypes, seenTypes)
        `${argName}: ${gqlType}`
      })
      ->Array.join(", ")
    let argsPart = args->String.length > 0 ? `(${args})` : ""
    Some(`  ${fieldName}${argsPart}: String!`)
  | None => None
  }

// ── Main generate function ─────────────────────────────────────────────────

let generate = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let types: array<string> = []
  let mutations: array<string> = []
  let queries: array<string> = []
  let seenTypes = Set.make()

  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    switch schema {
    | Union({anyOf}) =>
      anyOf->Array.forEachWithIndex((variantSchema, i) => {
        let fieldName = entry.fieldNames->Array.get(i)->Option.getOr("")
        if fieldName->String.length > 0 {
          deriveMutationFieldFromObject(~fieldName, variantSchema)
          ->Option.forEach(field => {
            let withId = if field->String.includes("(") {
              field->String.replace(`${fieldName}(`, `${fieldName}(id: ID!, `)
            } else {
              field->String.replace(`${fieldName}:`, `${fieldName}(id: ID!):`)
            }
            mutations->Array.push(withId)
          })
        }
      })
    | Object(_) =>
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        deriveMutationFieldFromObject(~fieldName, schema)
        ->Option.forEach(field => mutations->Array.push(field))
      }
    | _ => ()
    }
  })

  queryEntries->Array.forEach(entry => {
    let includeIdParam = entry.includeIdParam->Option.getOr(true)
    let connectionSpec = entry.connectionSpec->Option.getOr(true)
    if !(seenTypes->Set.has(entry.returnTypeName)) {
      seenTypes->Set.add(entry.returnTypeName)
      let excludeFields = switch entry.excludeFields {
      | Some(fields) => fields
      | None => []
      }
      let nestedTypes = deriveObjectTypeWithNested(
        ~typeName=entry.returnTypeName,
        ~excludeFields,
        ~includeIdParam,
        entry.stateSchema,
      )
      nestedTypes->Array.forEach(t => {
        types->Array.push(t)
      })
    }

    let singleField = deriveObjectQueryField(
      ~singleFieldName=entry.singleFieldName,
      ~typeName=entry.returnTypeName,
      ~includeIdParam,
    )
    queries->Array.push(singleField)

    let listFieldName = entry.listFieldName
    // ByIdConnection query (sort key conditions) — generated when subIdField is set
    switch entry.subIdField {
    | Some(_sf) =>
      let byIdConnTypeName = entry.returnTypeName ++ "ByIdConnection"
      if !(seenTypes->Set.has(byIdConnTypeName)) {
        seenTypes->Set.add(byIdConnTypeName)
        types->Array.push(deriveByIdConnectionType(~typeName=entry.returnTypeName))
      }
      queries->Array.push(
        deriveByIdConnectionQueryField(
          ~singleFieldName=entry.singleFieldName,
          ~returnTypeName=entry.returnTypeName,
        ),
      )
    | None => ()
    }

    if connectionSpec {
      // Relay Connection spec: Edge + Connection types
      let connectionTypeName = entry.returnTypeName ++ "Connection"
      if !(seenTypes->Set.has(connectionTypeName)) {
        let edgeName = entry.returnTypeName ++ "Edge"
        seenTypes->Set.add(edgeName)
        seenTypes->Set.add(connectionTypeName)
        deriveConnectionTypes(~singularTypeName=entry.returnTypeName)
        ->Array.forEach(t => types->Array.push(t))
      }
      let listField = deriveConnectionQueryField(
        ~listFieldName,
        ~singularTypeName=entry.returnTypeName,
      )
      queries->Array.push(listField)
    } else {
      // Legacy AppSync-style: items/nextToken/scannedCount
      if !(seenTypes->Set.has(listFieldName)) {
        seenTypes->Set.add(listFieldName)
        let pluralType = derivePluralWrapperType(
          ~pluralTypeName=listFieldName,
          ~singularTypeName=entry.returnTypeName,
        )
        types->Array.push(pluralType)
      }
      let listField = deriveListQueryField(
        ~listFieldName,
        ~pluralTypeName=listFieldName,
      )
      queries->Array.push(listField)
    }
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
