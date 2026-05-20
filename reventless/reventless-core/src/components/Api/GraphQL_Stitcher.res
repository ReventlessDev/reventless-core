// GraphQL schema stitcher.
// Merges a base fragment with plugin fragments into a single SDL string.
// Detects and logs type/field name collisions.

type fragmentParts = {
  types: array<string>,
  mutations: array<string>,
  queries: array<string>,
  subscriptions: array<string>,
}

let encode = (parts: fragmentParts): Reventless.Plugin.apiSchemaFragment => {
  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(parts.types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(parts.mutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(parts.queries->Array.map(JSON.Encode.string))),
        ("subscriptions", JSON.Encode.array(parts.subscriptions->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify
  {Reventless.Plugin.encoded, protocol: "graphql"}
}

let decode = (fragment: Reventless.Plugin.apiSchemaFragment): fragmentParts => {
  switch fragment.encoded->JSON.parseOrThrow->JSON.Decode.object {
  | None => {types: [], mutations: [], queries: [], subscriptions: []}
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
      subscriptions: getString("subscriptions"),
    }
  }
}

// Extract the first identifier from a SDL field/type string.
// e.g. "  fieldName(args): Type" → "fieldName"
//      "type TypeName {" → "TypeName"
let extractLeadingName = (str: string): string => {
  let trimmed = str->String.trim
  // Remove "type ", "enum ", or "input " prefix if present
  let afterType = if trimmed->String.startsWith("type ") {
    trimmed->String.slice(~start=5, ~end=trimmed->String.length)->String.trim
  } else if trimmed->String.startsWith("enum ") {
    trimmed->String.slice(~start=5, ~end=trimmed->String.length)->String.trim
  } else if trimmed->String.startsWith("input ") {
    trimmed->String.slice(~start=6, ~end=trimmed->String.length)->String.trim
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

  // Collect all subscription fields — detect collisions by field name
  let seenSubscriptionFields: Set.t<string> = Set.make()
  let allSubscriptions: array<string> = []

  parts->Array.forEach(({subscriptions}) =>
    subscriptions->Array.forEach(field => {
      let fieldName = extractLeadingName(field)
      if seenSubscriptionFields->Set.has(fieldName) {
        Console.warn(`[GraphQL_Stitcher] Duplicate subscription field — skipped: ${fieldName}`)
      } else {
        seenSubscriptionFields->Set.add(fieldName)
        allSubscriptions->Array.push(field)
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

  let subscriptionsSdl =
    allSubscriptions->Array.length > 0
      ? Some(`type Subscription {\n${allSubscriptions->Array.join("\n")}\n}`)
      : None

  let sdlParts =
    [Some(typesSdl), Some(queriesSdl), Some(mutationsSdl), subscriptionsSdl]->Array.filterMap(
      x => x,
    )
  sdlParts->Array.join("\n\n")
}

let isIdentStart = (line: string): bool =>
  switch line->String.codePointAt(0) {
  // A-Z (65-90), a-z (97-122), or `_` (95)
  | Some(c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
  | None => false
  }

/**
Count the field definitions inside a root object type (`Mutation` / `Query`) of a
full SDL string.

Used by the runtime schema-update circuit breaker (AdminEventCollectorEntryPoint)
to detect a catastrophic shrink before pushing a new schema to AppSync. Heuristic
but adequate for a shrink guard: root operation fields are flat single-line
declarations (`name(args): T` or `name: T`), so we slice the `type <typeName> {
… }` block at its first `{`/`}` and count indented lines that begin with an
identifier character, ignoring directive-only lines (`@…`), comments (`#…`) and
braces.
*/
let countRootTypeFields = (~sdl: string, ~typeName: string): int => {
  let marker = `type ${typeName}`
  switch sdl->String.indexOfOpt(marker) {
  | None => 0
  | Some(typeStart) =>
    let rest = sdl->String.slice(~start=typeStart)
    switch (rest->String.indexOfOpt("{"), rest->String.indexOfOpt("}")) {
    | (Some(openIdx), Some(closeIdx)) if closeIdx > openIdx =>
      rest
      ->String.slice(~start=openIdx + 1, ~end=closeIdx)
      ->String.split("\n")
      ->Array.filter(line => {
        let trimmed = line->String.trim
        trimmed->String.length > 0 && isIdentStart(trimmed)
      })
      ->Array.length
    | _ => 0
    }
  }
}

/**
Decide whether replacing the live schema (`currentSdl`) with `newSdl` would drop
so many root-type (`Mutation` + `Query`) fields that it is almost certainly a
transient/incomplete stitch rather than an intentional removal.

Returns `true` when the new root-field total is below `threshold` × the current
total. When the current schema has no countable root fields (e.g. first deploy,
or introspection was unavailable so `currentSdl` is empty) it returns `false` so
the initial push always proceeds.
*/
let isCatastrophicSchemaShrink = (~currentSdl: string, ~newSdl: string, ~threshold: float): bool => {
  let current =
    countRootTypeFields(~sdl=currentSdl, ~typeName="Mutation") +
    countRootTypeFields(~sdl=currentSdl, ~typeName="Query")
  let next =
    countRootTypeFields(~sdl=newSdl, ~typeName="Mutation") +
    countRootTypeFields(~sdl=newSdl, ~typeName="Query")
  current > 0 && next->Int.toFloat < current->Int.toFloat *. threshold
}
