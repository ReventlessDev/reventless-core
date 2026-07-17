// GraphQL schema inspector — debugging utilities for inspecting generated schemas.
// All public functions accept polymorphic S.t<'a> and use S.castToUnknown internally.

open ReventlessInfra.Api

// ── Granular Level ──────────────────────────────────────────────────────────

let inspectScalar = (schema: S.t<'a>): string => {
  let collectedTypes: array<string> = []
  let seenTypes = Set.make()
  GraphQL_FragmentGenerator.deriveFieldType(
    ~parentTypeName="",
    ~fieldName="",
    ~required=false,
    schema->S.castToUnknown,
    collectedTypes,
    seenTypes,
  )
}

let inspectObjectType = (~typeName: string, schema: S.t<'a>): option<string> => {
  let types = GraphQL_FragmentGenerator.deriveObjectTypeWithNested(~typeName, schema->S.castToUnknown)
  types->Array.get(types->Array.length - 1)
}

let inspectMutationFields = (~fieldPrefix: string, commandSchema: S.t<'a>): array<string> => {
  let schema = commandSchema->S.castToUnknown
  let fields: array<string> = []
  let collectedTypes: array<string> = []
  let seenTypes = Set.make()
  switch schema {
  | Union({anyOf}) =>
    let constructorNames = Reventless.DcbTag.extractAllVariantNames(commandSchema)
    anyOf->Array.forEachWithIndex((variantSchema, i) => {
      let fieldName = switch constructorNames->Array.get(i) {
      | Some(name) => `${fieldPrefix}_${name}`
      | None => `${fieldPrefix}_Variant${Int.toString(i)}`
      }
      GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
        ~fieldName,
        ~collectedTypes,
        ~seenTypes,
        variantSchema,
      )->Option.forEach(field => fields->Array.push(field))
    })
  | Object(_) =>
    GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
      ~fieldName=fieldPrefix,
      ~collectedTypes,
      ~seenTypes,
      schema,
    )->Option.forEach(field => fields->Array.push(field))
  | _ => ()
  }
  fields
}

type queryFieldInspection = {
  typeDef: option<string>,
  singleQuery: string,
  listQuery: option<string>,
}

let inspectQueryFields = (
  ~name: string,
  ~typeName: string,
  stateSchema: S.t<'a>,
): queryFieldInspection => {
  let schema = stateSchema->S.castToUnknown
  let types = GraphQL_FragmentGenerator.deriveObjectTypeWithNested(~typeName, schema)
  let typeDef = types->Array.get(types->Array.length - 1)
  let singleQuery = GraphQL_FragmentGenerator.deriveObjectQueryField(
    ~singleFieldName=name,
    ~typeName,
  )
  let pluralName = name ++ "s"
  let listQuery = Some(
    GraphQL_FragmentGenerator.deriveListQueryField(
      ~listFieldName=pluralName,
      ~pluralTypeName=pluralName,
    ),
  )
  {typeDef, singleQuery, listQuery}
}

// ── Plugin Level — Fragment Inspector ───────────────────────────────────────

type fragmentInspection = {
  types: array<string>,
  mutations: array<string>,
  queries: array<string>,
  sdlPreview: string,
}

let inspectFragment = (fragment: Reventless.Plugin.apiSchemaFragment): fragmentInspection => {
  let parts = GraphQL_Stitcher.decode(fragment)
  let typesSdl = parts.types->Array.join("\n\n")
  let queriesSdl = switch parts.queries->Array.length > 0 {
  | true => `type Query {\n${parts.queries->Array.join("\n")}\n}`
  | false => ""
  }
  let mutationsSdl = switch parts.mutations->Array.length > 0 {
  | true => `type Mutation {\n${parts.mutations->Array.join("\n")}\n}`
  | false => ""
  }
  let sdlParts =
    [typesSdl, queriesSdl, mutationsSdl]->Array.filter(p => p->String.length > 0)
  let sdlPreview = sdlParts->Array.join("\n\n")
  {types: parts.types, mutations: parts.mutations, queries: parts.queries, sdlPreview}
}

let printFragment = (fragment: Reventless.Plugin.apiSchemaFragment): unit => {
  let log = Logger.fromEnv()
  let {types, mutations, queries, sdlPreview} = inspectFragment(fragment)
  log.debug(~comp="GraphQL", "[GraphQL Fragment]")
  log.debug(~comp="GraphQL", `  Types (${types->Array.length->Int.toString}):`)
  types->Array.forEach(t => {
    let name = GraphQL_Stitcher.extractLeadingName(t)
    log.debug(~comp="GraphQL", `    - ${name}`)
    log.debug(~comp="GraphQL", `      ${t}`)
  })
  log.debug(~comp="GraphQL", `  Mutations (${mutations->Array.length->Int.toString}):`)
  mutations->Array.forEach(m => {
    let name = GraphQL_Stitcher.extractLeadingName(m)
    log.debug(~comp="GraphQL", `    - ${name}`)
    log.debug(~comp="GraphQL", `      ${m}`)
  })
  log.debug(~comp="GraphQL", `  Queries (${queries->Array.length->Int.toString}):`)
  queries->Array.forEach(q => {
    let name = GraphQL_Stitcher.extractLeadingName(q)
    log.debug(~comp="GraphQL", `    - ${name}`)
    log.debug(~comp="GraphQL", `      ${q}`)
  })
  log.debug(~comp="GraphQL", "\n--- SDL Preview ---")
  log.debug(~comp="GraphQL", sdlPreview)
  log.debug(~comp="GraphQL", "--- End ---")
}

let inspectPluginEntries = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
): string => {
  let mutationNames =
    mutationEntries
    ->Array.flatMap(entry => entry.fieldNames)
    ->Array.join(", ")
  let queryNames =
    queryEntries
    ->Array.map(entry => {
      `${entry.singleFieldName}(id) -> ${entry.returnTypeName}, ${entry.listFieldName} -> [${entry.returnTypeName}]`
    })
    ->Array.join(", ")
  let mutCount = mutationEntries->Array.flatMap(e => e.fieldNames)->Array.length->Int.toString
  let queryCount = queryEntries->Array.length->Int.toString
  `Mutations (${mutCount}): ${mutationNames}\nQueries (${queryCount}): ${queryNames}`
}
