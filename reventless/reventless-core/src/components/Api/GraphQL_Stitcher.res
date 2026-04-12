// GraphQL schema stitcher.
// Merges a base fragment with plugin fragments into a single SDL string.
// Detects and logs type/field name collisions.

type fragmentParts = {
  types: array<string>,
  mutations: array<string>,
  queries: array<string>,
}

let encode = (parts: fragmentParts): Reventless.Plugin.apiSchemaFragment => {
  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(parts.types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(parts.mutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(parts.queries->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify
  {Reventless.Plugin.encoded, protocol: "graphql"}
}

let decode = (fragment: Reventless.Plugin.apiSchemaFragment): fragmentParts => {
  switch fragment.encoded->JSON.parseOrThrow->JSON.Decode.object {
  | None => {types: [], mutations: [], queries: []}
  | Some(dict) =>
    let getString = (key): array<string> =>
      switch dict->Dict.get(key) {
      | Some(JSON.Array(arr)) =>
        arr->Array.filterMap(j =>
          switch j {
          | JSON.String(s) => Some(s)
          | _ => None
          }
        )
      | _ => []
      }
    {
      types: getString("types"),
      mutations: getString("mutations"),
      queries: getString("queries"),
    }
  }
}

// Extract the first identifier from a SDL field/type string.
// e.g. "  fieldName(args): Type" → "fieldName"
//      "type TypeName {" → "TypeName"
let extractLeadingName = (str: string): string => {
  let trimmed = str->String.trim
  // Remove "type " or "enum " prefix if present
  let afterType = if trimmed->String.startsWith("type ") {
    trimmed->String.slice(~start=5, ~end=trimmed->String.length)->String.trim
  } else if trimmed->String.startsWith("enum ") {
    trimmed->String.slice(~start=5, ~end=trimmed->String.length)->String.trim
  } else {
    trimmed
  }
  // Split on "(" first to remove arg list, then on " " and "{" for the name
  afterType
  ->String.split("(")
  ->Array.get(0)
  ->Option.getOr("")
  ->String.trim
  ->String.split(" ")
  ->Array.get(0)
  ->Option.getOr("")
  ->String.trim
  ->String.split("{")
  ->Array.get(0)
  ->Option.getOr("")
  ->String.trim
}

// Relay base types injected into every stitched schema.
let relayBaseTypes = [
  `interface Node {\n  id: ID!\n}`,
  `type PageInfo {\n  hasNextPage: Boolean!\n  hasPreviousPage: Boolean!\n  startCursor: String\n  endCursor: String\n}`,
  `enum SortOrder {\n  ASC\n  DESC\n}`,
]

let relayBaseQueries = [
  `  node(id: ID!): Node`,
]

/**
Stitch a base fragment with plugin fragments into a complete GraphQL SDL string.

- Base fragment is always first (defines core types + Plugin mutations/queries).
- Plugin fragments add their own types, mutations, and queries.
- Collision detection: duplicate type definitions and field names are logged and skipped.
- Relay base types (Node interface, PageInfo) and node query are always injected.

Returns the full SDL string ready for use with AppSync or graphql-yoga.
*/
let stitch = (
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
): string => {
  let allFragments = Array.concat([baseFragment], pluginFragments)
  let parts = allFragments->Array.map(decode)

  // Collect all type definitions — detect collisions by type name
  // Start with Relay base types (Node interface, PageInfo)
  let seenTypeNames: Set.t<string> = Set.make()
  let allTypes: array<string> = []
  relayBaseTypes->Array.forEach(typeDef => {
    let name = extractLeadingName(typeDef)
    seenTypeNames->Set.add(name)
    allTypes->Array.push(typeDef)
  })

  parts->Array.forEach(({types}) =>
    types->Array.forEach(typeDef => {
      let name = extractLeadingName(typeDef)
      if name->String.length == 0 {
        allTypes->Array.push(typeDef)
      } else if seenTypeNames->Set.has(name) {
        Console.warn(`[GraphQL_Stitcher] Duplicate type — skipped: ${name}`)
      } else {
        seenTypeNames->Set.add(name)
        allTypes->Array.push(typeDef)
      }
    })
  )

  // Collect all mutation fields — detect collisions by field name
  let seenMutationFields: Set.t<string> = Set.make()
  let allMutations: array<string> = []

  parts->Array.forEach(({mutations}) =>
    mutations->Array.forEach(field => {
      let fieldName = extractLeadingName(field)
      if seenMutationFields->Set.has(fieldName) {
        Console.warn(`[GraphQL_Stitcher] Duplicate mutation field — skipped: ${fieldName}`)
      } else {
        seenMutationFields->Set.add(fieldName)
        allMutations->Array.push(field)
      }
    })
  )

  // Collect all query fields — detect collisions by field name
  // Start with Relay node query
  let seenQueryFields: Set.t<string> = Set.make()
  let allQueries: array<string> = []
  relayBaseQueries->Array.forEach(field => {
    let fieldName = extractLeadingName(field)
    seenQueryFields->Set.add(fieldName)
    allQueries->Array.push(field)
  })

  parts->Array.forEach(({queries}) =>
    queries->Array.forEach(field => {
      let fieldName = extractLeadingName(field)
      if seenQueryFields->Set.has(fieldName) {
        Console.warn(`[GraphQL_Stitcher] Duplicate query field — skipped: ${fieldName}`)
      } else {
        seenQueryFields->Set.add(fieldName)
        allQueries->Array.push(field)
      }
    })
  )

  // Build the final SDL
  let typesSdl = allTypes->Array.join("\n\n")

  let mutationsSdl =
    allMutations->Array.length > 0
      ? `type Mutation {\n${allMutations->Array.join("\n")}\n}`
      : "type Mutation {\n  _noop: String\n}"

  let queriesSdl =
    allQueries->Array.length > 0
      ? `type Query {\n${allQueries->Array.join("\n")}\n}`
      : "type Query {\n  _noop: String\n}"

  let sdlParts = [typesSdl, queriesSdl, mutationsSdl]->Array.filter(p => p->String.length > 0)
  sdlParts->Array.join("\n\n")
}
