// GraphQL schema inspector — debugging utilities for inspecting generated schemas.
// All public functions accept polymorphic S.t<'a> and use S.castToUnknown internally.

open ReventlessInfra.Api

// ── Granular Level ──────────────────────────────────────────────────────────

let inspectScalar = (schema: S.t<'a>): string =>
  GraphQL_FragmentGenerator.deriveScalarType(schema->S.castToUnknown)

let inspectObjectType = (~typeName: string, schema: S.t<'a>): option<string> =>
  GraphQL_FragmentGenerator.deriveObjectType(~typeName, schema->S.castToUnknown)

let inspectMutationFields = (~fieldPrefix: string, commandSchema: S.t<'a>): array<string> => {
  let schema = commandSchema->S.castToUnknown
  let fields: array<string> = []
  switch schema {
  | Union({anyOf}) =>
    let constructorNames = Reventless.DcbTag.extractEventTypes(commandSchema)
    anyOf->Array.forEachWithIndex((variantSchema, i) => {
      let fieldName = switch constructorNames->Array.get(i) {
      | Some(name) => `${fieldPrefix}_${name}`
      | None => `${fieldPrefix}_Variant${Int.toString(i)}`
      }
      GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
        ~fieldName,
        variantSchema,
        ~authorization=None,
      )->Option.forEach(field => fields->Array.push(field))
    })
  | Object(_) =>
    GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
      ~fieldName=fieldPrefix,
      schema,
      ~authorization=None,
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
  let typeDef = GraphQL_FragmentGenerator.deriveObjectType(~typeName, schema)
  let singleQuery = GraphQL_FragmentGenerator.deriveObjectQueryField(
    ~singleFieldName=name,
    ~typeName,
    ~authorization=None,
  )
  let pluralName = name ++ "s"
  let listQuery = Some(
    GraphQL_FragmentGenerator.deriveListQueryField(
      ~listFieldName=pluralName,
      ~pluralTypeName=pluralName,
      ~authorization=None,
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
  let {types, mutations, queries, sdlPreview} = inspectFragment(fragment)
  Console.log("[GraphQL Fragment]")
  Console.log(`  Types (${types->Array.length->Int.toString}):`)
  types->Array.forEach(t => {
    let name = GraphQL_Stitcher.extractLeadingName(t)
    Console.log(`    - ${name}`)
    Console.log(`      ${t}`)
  })
  Console.log(`  Mutations (${mutations->Array.length->Int.toString}):`)
  mutations->Array.forEach(m => {
    let name = GraphQL_Stitcher.extractLeadingName(m)
    Console.log(`    - ${name}`)
    Console.log(`      ${m}`)
  })
  Console.log(`  Queries (${queries->Array.length->Int.toString}):`)
  queries->Array.forEach(q => {
    let name = GraphQL_Stitcher.extractLeadingName(q)
    Console.log(`    - ${name}`)
    Console.log(`      ${q}`)
  })
  Console.log("\n--- SDL Preview ---")
  Console.log(sdlPreview)
  Console.log("--- End ---")
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
      let listPart = switch entry.listFieldName {
      | Some(ln) => `, ${ln} -> [${entry.returnTypeName}]`
      | None => ""
      }
      `${entry.singleFieldName}(id) -> ${entry.returnTypeName}${listPart}`
    })
    ->Array.join(", ")
  let mutCount = mutationEntries->Array.flatMap(e => e.fieldNames)->Array.length->Int.toString
  let queryCount = queryEntries->Array.length->Int.toString
  `Mutations (${mutCount}): ${mutationNames}\nQueries (${queryCount}): ${queryNames}`
}
