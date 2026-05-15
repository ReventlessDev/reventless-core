// GraphQL schema fragment generator.
// Derives GraphQL SDL fragments from sury schemas (commandSchema, stateSchema)
// using SchemaType as the shared intermediate representation.

open ReventlessInfra.Api

// ── SchemaType → GraphQL type reference ──────────────────────────────────────

let rec fromSchemaType = (
  ~required: bool,
  ~asInput: bool=false,
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
  | Nullable(inner) => fromSchemaType(~required=false, ~asInput, inner, collectedTypes, seenTypes)
  | ArrayOf(item) =>
    let itemType = fromSchemaType(~required=true, ~asInput, item, collectedTypes, seenTypes)
    `[${itemType}]${bang}`
  | ObjectRef(name, fields) =>
    if !(seenTypes->Set.has(name)) {
      seenTypes->Set.add(name)
      let typeDef = objectRefToGraphQL(~asInput, name, fields, collectedTypes, seenTypes)
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
  ~asInput: bool=false,
  typeName: string,
  fields: dict<SchemaType.schemaType>,
  collectedTypes: array<string>,
  seenTypes: Set.t<string>,
): string => {
  let fieldStrs =
    fields
    ->Dict.toArray
    ->Array.map(((fieldName, fieldType)) => {
      let gqlType = fromSchemaType(~required=true, ~asInput, fieldType, collectedTypes, seenTypes)
      `  ${fieldName}: ${gqlType}`
    })
    ->Array.join("\n")
  let keyword = asInput ? "input" : "type"
  `${keyword} ${typeName} {\n${fieldStrs}\n}`
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
  `type ${singularTypeName}Connection {\n  edges: [${singularTypeName}Edge!]!\n  pageInfo: PageInfo!\n}`,
]

let deriveSubIdFilterType = (~filterTypeName: string): string =>
  `input ${filterTypeName} {\n  prefix: String\n  from: String\n  to: String\n  eq: String\n  order: SortOrder\n}`

// ── Server-side filter / sort capability ─────────────────────────────────────
// Derived from the structural annotations carried on the state schema
// (`@id`, `@compositeId`, `@subId`, `@compositeSubId`, `@index`). Both the
// SDL emitter and the in-memory resolver consume the same record so the
// emitted Filter / OrderBy and the runtime narrow / sort cannot drift.

type filterField = {
  name: string,
  gqlType: string,
  range: bool,
}

type serverCapability = {
  filterFields: array<filterField>,
  sortFields: array<string>,
}

let emptyCapability: serverCapability = {filterFields: [], sortFields: []}

// Convert a SchemaType.schemaType to its GraphQL scalar name (input position).
// Mirrors the scalar branches of fromSchemaType — kept inline because we don't
// emit `!`/list wrappers for filter inputs.
let scalarOfSchemaType = (st: SchemaType.schemaType): string =>
  switch st {
  | ScalarString => "String"
  | ScalarNumber => "Float"
  | ScalarBoolean => "Boolean"
  | ScalarBigInt => "String"
  | EntityId => "ID"
  | _ => "String"
  }

let deriveServerCapability = (schema: S.t<unknown>): serverCapability => {
  switch Reventless.StateAnnotations.getSpec(schema) {
  | None => emptyCapability
  | Some(spec) =>
    let fieldTypes = SchemaType.fromSuryObject(~typeName="", schema)->Option.getOr(Dict.make())
    let scalarOf = (fieldName: string): string =>
      fieldTypes->Dict.get(fieldName)->Option.mapOr("String", scalarOfSchemaType)

    let filterFields: array<filterField> = []
    let sortFields: array<string> = []
    let seenFilter: Set.t<string> = Set.make()
    let seenSort: Set.t<string> = Set.make()

    let pushFilter = (name, ~range) =>
      if !(seenFilter->Set.has(name)) {
        seenFilter->Set.add(name)
        filterFields->Array.push({name, gqlType: scalarOf(name), range})
      }
    let pushSort = name =>
      if !(seenSort->Set.has(name)) {
        seenSort->Set.add(name)
        sortFields->Array.push(name)
      }

    spec.ids->Array.forEach(name => {
      pushFilter(name, ~range=false)
      pushSort(name)
    })
    spec.compositeIds->Array.forEach(name => pushFilter(name, ~range=false))
    spec.subIds->Array.forEach(name => {
      pushFilter(name, ~range=true)
      pushSort(name)
    })
    spec.compositeSubIds->Array.forEach(name => {
      pushFilter(name, ~range=true)
      pushSort(name)
    })
    spec.indexes->Array.forEach(((name, _indexName)) => {
      pushFilter(name, ~range=false)
      pushSort(name)
    })
    // @scan / @scanSort are explicit opt-ins for non-indexed fields. They
    // expand the SDL surface only — the in-memory resolver's narrow / sort
    // helpers already operate on arbitrary fields, so no additional code
    // path is needed here.
    spec.scan->Array.forEach(name => pushFilter(name, ~range=false))
    spec.scanSort->Array.forEach(name => pushSort(name))

    {filterFields, sortFields}
  }
}

// Returns one warning per `@scanSort` field that is NOT also a sort key of the
// table or any GSI. The Scan-based AWS resolver evaluates such requests as a
// JS-runtime per-page sort over a full Scan — correct, but expensive. The
// schema author should either point the field at an index sort key or
// explicitly accept the per-page-sort caveat. Returns [] when validation is
// not applicable (no schema, no `@scanSort` fields).
let validateScanSortAlignment = (
  ~schema: S.t<unknown>,
  ~readModelName: string,
  ~knownSortFields: array<string>,
): array<string> =>
  switch Reventless.StateAnnotations.getSpec(schema) {
  | None => []
  | Some(spec) =>
    spec.scanSort->Array.filterMap(field =>
      if knownSortFields->Array.includes(field) {
        None
      } else {
        Some(
          `Read model "${readModelName}": @scanSort field "${field}" is not the sort key of any table or GSI. Sort requests for this field will be evaluated as a JS-runtime per-page sort over a full Scan — expensive in production. Add it as the sort key of an index, or accept the per-page-sort caveat.`,
        )
      }
    )
  }

let deriveConnectionFilterType = (
  ~filterTypeName: string,
  ~capability: serverCapability=emptyCapability,
): string => {
  let baseFields = ["search: String", "searchPrefix: String", "ids: [ID!]"]
  let perFieldFilters =
    capability.filterFields->Array.flatMap(f => {
      let eq = `${f.name}Eq: ${f.gqlType}`
      if f.range {
        [eq, `${f.name}From: ${f.gqlType}`, `${f.name}To: ${f.gqlType}`]
      } else {
        [eq]
      }
    })
  let allFields = Array.concat(baseFields, perFieldFilters)
  let body = allFields->Array.map(f => `  ${f}`)->Array.join("\n")
  `input ${filterTypeName} {\n${body}\n}`
}

// Emits an `enum <Type>OrderField` and `input <Type>OrderBy` pair when the
// capability has any sort fields. Returns [] when no field is sortable so
// the connection field doesn't reference a non-existent OrderBy type.
let deriveConnectionOrderByType = (
  ~singularTypeName: string,
  ~capability: serverCapability,
): array<string> =>
  if capability.sortFields->Array.length == 0 {
    []
  } else {
    let orderFieldEnumName = singularTypeName ++ "OrderField"
    let orderByInputName = singularTypeName ++ "OrderBy"
    let valuesStr = capability.sortFields->Array.map(f => `  ${f}`)->Array.join("\n")
    [
      `enum ${orderFieldEnumName} {\n${valuesStr}\n}`,
      `input ${orderByInputName} {\n  field: ${orderFieldEnumName}!\n  direction: SortOrder!\n}`,
    ]
  }

let deriveItemsQueryField = (
  ~singleFieldName: string,
  ~returnTypeName: string,
  ~filterTypeName: string,
): string =>
  `  ${singleFieldName}Items(id: ID!, filter: ${filterTypeName}, first: Int, after: String, last: Int, before: String): ${returnTypeName}Connection!`

// ── Query field derivation ─────────────────────────────────────────────────

let deriveObjectQueryField = (
  ~singleFieldName: string,
  ~typeName: string,
  ~includeIdParam: bool=true,
  ~subIdField: option<string>=?,
): string =>
  if includeIdParam {
    switch subIdField {
    | Some(sortField) => `  ${singleFieldName}(id: ID!, ${sortField}: String!): ${typeName}`
    | None => `  ${singleFieldName}(id: ID!): ${typeName}`
    }
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
  ~filterTypeName: string,
  ~hasOrderBy: bool=false,
): string => {
  let orderByArg = hasOrderBy ? `, orderBy: ${singularTypeName}OrderBy` : ""
  `  ${listFieldName}(filter: ${filterTypeName}${orderByArg}, first: Int, after: String, last: Int, before: String): ${singularTypeName}Connection!`
}

// ── Mutation field derivation ──────────────────────────────────────────────

let deriveMutationFieldFromObject = (
  ~fieldName: string,
  ~collectedTypes: array<string>,
  ~seenTypes: Set.t<string>,
  variantSchema: S.t<unknown>,
): option<string> =>
  switch SchemaType.fromSuryObject(~typeName=fieldName, variantSchema) {
  | Some(fields) =>
    let args =
      fields
      ->Dict.toArray
      ->Array.map(((argName, argType)) => {
        let gqlType = fromSchemaType(
          ~required=true,
          ~asInput=true,
          argType,
          collectedTypes,
          seenTypes,
        )
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

  // Extract the constructor name from a mutation field name like
  // `Plugin_Activate` / `Platform_Plugin_Activate` — always the last
  // underscore-separated segment (e.g. `Activate`).
  let constructorNameOf = (fieldName: string): string =>
    fieldName->String.split("_")->Array.get(fieldName->String.split("_")->Array.length - 1)
      ->Option.getOr(fieldName)

  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    switch schema {
    | Union({anyOf}) =>
      // Map each fieldName to its variant in anyOf by matching the constructor
      // name. Position-based pairing (anyOf index ↔ fieldNames index) breaks
      // when `@noApi` filters out some variants but the schema still carries
      // them — the field name "Platform_Plugin_Deactivate" would otherwise be
      // married to the `Connect(pluginDefinition)` variant at unfiltered
      // index 1, leaking a stale `_0: Platform_Plugin_Deactivate_0` arg.
      let variantNames = anyOf->Array.map(v =>
        switch v {
        | Object({items}) =>
          items
          ->Array.find(item => item.location == "TAG")
          ->Option.flatMap(item =>
            switch item.schema {
            | String({const}) => Some(const)
            | _ => None
            }
          )
          ->Option.getOr("")
        | String({const}) => const
        | _ => ""
        }
      )
      entry.fieldNames->Array.forEach(fieldName => {
        let cname = constructorNameOf(fieldName)
        let variantIndex = variantNames->Array.indexOf(cname)
        let variantSchema = variantIndex >= 0
          ? anyOf->Array.get(variantIndex)->Option.getOr(schema)
          : schema
        switch deriveMutationFieldFromObject(
          ~fieldName,
          ~collectedTypes=types,
          ~seenTypes,
          variantSchema,
        ) {
        | Some(field) =>
          let withId = if field->String.includes("(") {
            field->String.replace(`${fieldName}(`, `${fieldName}(id: ID!, `)
          } else {
            field->String.replace(`${fieldName}:`, `${fieldName}(id: ID!):`)
          }
          mutations->Array.push(withId)
        | None =>
          // Payload-less variant (S.literal("Ctor")) — no Object fields to
          // derive args from, but still a valid mutation. Emit a bare form;
          // CommandGeneratorResolvers_GraphQL.deriveSdlField uses the same
          // fallback for the in-memory path.
          mutations->Array.push(`  ${fieldName}(id: ID!): String!`)
        }
      })
    | Object(_) =>
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        deriveMutationFieldFromObject(
          ~fieldName,
          ~collectedTypes=types,
          ~seenTypes,
          schema,
        )
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
      ~subIdField=?entry.subIdField,
    )
    queries->Array.push(singleField)

    let listFieldName = entry.listFieldName
    // Items query (sort key conditions, Relay connection) — generated when subIdField is set
    switch entry.subIdField {
    | Some(_sf) =>
      let itemsFilterTypeName = entry.returnTypeName ++ "ItemsFilter"
      if !(seenTypes->Set.has(itemsFilterTypeName)) {
        seenTypes->Set.add(itemsFilterTypeName)
        types->Array.push(deriveSubIdFilterType(~filterTypeName=itemsFilterTypeName))
      }
      queries->Array.push(
        deriveItemsQueryField(
          ~singleFieldName=entry.singleFieldName,
          ~returnTypeName=entry.returnTypeName,
          ~filterTypeName=itemsFilterTypeName,
        ),
      )
    | None => ()
    }

    // By-index connection queries — generated for each GSI on the entry
    switch entry.indexQueries {
    | Some(indexes) =>
      let connectionTypeName = entry.returnTypeName ++ "Connection"
      indexes->Array.forEach(({index}) => {
        let stripped = if index->String.startsWith("by") && index->String.length > 2 {
          index->String.slice(~start=2, ~end=index->String.length)
        } else {
          index
        }
        let fieldName = entry.singleFieldName ++ "By" ++ stripped->String.capitalize
        queries->Array.push(
          `  ${fieldName}(id: ID!, first: Int, after: String, last: Int, before: String): ${connectionTypeName}!`,
        )
      })
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
      let capability = deriveServerCapability(entry.stateSchema)
      let connectionFilterTypeName = entry.returnTypeName ++ "Filter"
      if !(seenTypes->Set.has(connectionFilterTypeName)) {
        seenTypes->Set.add(connectionFilterTypeName)
        types->Array.push(
          deriveConnectionFilterType(~filterTypeName=connectionFilterTypeName, ~capability),
        )
      }
      let orderByTypes =
        deriveConnectionOrderByType(~singularTypeName=entry.returnTypeName, ~capability)
      let hasOrderBy = orderByTypes->Array.length > 0
      if hasOrderBy {
        let orderFieldEnumName = entry.returnTypeName ++ "OrderField"
        let orderByInputName = entry.returnTypeName ++ "OrderBy"
        if !(seenTypes->Set.has(orderFieldEnumName)) {
          seenTypes->Set.add(orderFieldEnumName)
          seenTypes->Set.add(orderByInputName)
          orderByTypes->Array.forEach(t => types->Array.push(t))
        }
      }
      let listField = deriveConnectionQueryField(
        ~listFieldName,
        ~singularTypeName=entry.returnTypeName,
        ~filterTypeName=connectionFilterTypeName,
        ~hasOrderBy,
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
        ("subscriptions", JSON.Encode.array([])),
      ]),
    )->JSON.stringify

  {Reventless.Plugin.encoded, protocol: "graphql"}
}
