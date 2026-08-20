// GraphQL schema stitcher.
// Merges a base fragment with plugin fragments into a single SDL string.
// Detects and logs type/field name collisions.

let log = Logger.fromEnv()

// Neutral subscription→mutation source mapping. Core emits provider-free
// subscription SDL; this record carries which mutation(s) feed a subscription
// field so each provider can wire its own dialect (AppSync appends
// `@aws_subscribe(mutations: [...])` at push time; the local platform routes
// its PubSub bridge from the same mapping). Supports many-mutations-to-one
// fan-in (e.g. onUIFragmentChange ← three Platform_UIFragment* mutations).
type subscriptionSource = {
  field: string,
  mutations: array<string>,
}

type fragmentParts = {
  types: array<string>,
  mutations: array<string>,
  queries: array<string>,
  subscriptions: array<string>,
  subscriptionSources: array<subscriptionSource>,
}

let encodeSubscriptionSource = (source: subscriptionSource): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("field", JSON.Encode.string(source.field)),
      ("mutations", JSON.Encode.array(source.mutations->Array.map(JSON.Encode.string))),
    ]),
  )

let encode = (parts: fragmentParts): Reventless.Plugin.apiSchemaFragment => {
  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(parts.types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(parts.mutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(parts.queries->Array.map(JSON.Encode.string))),
        ("subscriptions", JSON.Encode.array(parts.subscriptions->Array.map(JSON.Encode.string))),
        (
          "subscriptionSources",
          JSON.Encode.array(parts.subscriptionSources->Array.map(encodeSubscriptionSource)),
        ),
      ]),
    )->JSON.stringify
  {Reventless.Plugin.encoded, protocol: "graphql"}
}

let decode = (fragment: Reventless.Plugin.apiSchemaFragment): fragmentParts => {
  switch fragment.encoded->JSON.parseOrThrow->JSON.Decode.object {
  | None => {types: [], mutations: [], queries: [], subscriptions: [], subscriptionSources: []}
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
    // Tolerant of fragments encoded before the field existed — default [].
    let subscriptionSources = switch dict->Dict.get("subscriptionSources") {
    | Some(JSON.Array(arr)) =>
      arr->Array.filterMap(j =>
        j
        ->JSON.Decode.object
        ->Option.flatMap(obj => {
          let field = obj->Dict.get("field")->Option.flatMap(JSON.Decode.string)
          let mutations = switch obj->Dict.get("mutations") {
          | Some(JSON.Array(ms)) =>
            ms->Array.filterMap(m =>
              switch m {
              | JSON.String(s) => Some(s)
              | _ => None
              }
            )
          | _ => []
          }
          field->Option.map(field => {field, mutations})
        })
      )
    | _ => []
    }
    {
      types: getString("types"),
      mutations: getString("mutations"),
      queries: getString("queries"),
      subscriptions: getString("subscriptions"),
      subscriptionSources,
    }
  }
}

/**
Union of the subscription→mutation source mappings across a base fragment and
all plugin fragments, deduped by subscription field name (first wins — matching
`stitch`'s first-wins field dedupe). Providers use this to decorate or wire the
STITCHED schema's subscription fields.
*/
let collectSubscriptionSources = (
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
): array<subscriptionSource> => {
  let seen: Set.t<string> = Set.make()
  Array.concat([baseFragment], pluginFragments)
  ->Array.flatMap(fragment => decode(fragment).subscriptionSources)
  ->Array.filter(source =>
    if seen->Set.has(source.field) {
      false
    } else {
      seen->Set.add(source.field)
      true
    }
  )
}

// Extract the first identifier from a SDL field/type string.
// e.g. "  fieldName(args): Type" → "fieldName"
//      "type TypeName {" → "TypeName"
// Every SDL keyword that introduces a named definition. `union` was missing while
// `CommandResult` was the only union in the schema: a keyword left in place makes
// every declaration of that kind name itself after the keyword, so the second one
// deduped against the first and vanished — AppSync then rejected the schema for a
// type that was never emitted.
let definitionKeywords = ["type ", "enum ", "input ", "union ", "interface ", "scalar "]

let extractLeadingName = (str: string): string => {
  let trimmed = str->String.trim
  let afterType = switch definitionKeywords->Array.find(kw => trimmed->String.startsWith(kw)) {
  | Some(kw) =>
    trimmed->String.slice(~start=kw->String.length, ~end=trimmed->String.length)->String.trim
  | None => trimmed
  }
  // Split on "(" first to remove arg list, then on " ", "{", and ":" for the name.
  // The ":" split is load-bearing for ARG-LESS fields: `Foo: [Bar!]!` has no "(" to
  // cleave the type off, and no space before the colon, so without it the name comes
  // back as `Foo:` (trailing colon) and fails exact-match lookups like iamFieldNames
  // — which is what dropped @aws_iam from the arg-less Platform_ApiFragments query and
  // 401'd the deploy waiter. Fields WITH args already lost their type via split("("),
  // so the ":" split is a harmless no-op for them.
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
  ->String.split(":")
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
Assemble fragments into a complete GraphQL SDL string.

- Fragments are processed in order (first wins on collisions).
- Collision detection: duplicate type definitions and field names are logged and skipped.
- Relay base types (Node interface, PageInfo) are always injected; the global
  `node` query only when `includeGlobalNodeQuery` (stitched schemas yes,
  standalone subgraph documents no).

Returns the full SDL string ready for use with AppSync or graphql-yoga.
Public entry points: `stitch` (base + plugins, the whole-schema path) and
`stitchStandalone` (one fragment as a self-contained subgraph document).
*/
let assembleSdl = (
  ~fragments: array<Reventless.Plugin.apiSchemaFragment>,
  ~includeGlobalNodeQuery: bool,
): string => {
  let parts = fragments->Array.map(decode)

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
        log.warn(~comp="GraphQL_Stitcher", `Duplicate type — skipped: ${name}`)
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
        log.warn(~comp="GraphQL_Stitcher", `Duplicate mutation field — skipped: ${fieldName}`)
      } else {
        seenMutationFields->Set.add(fieldName)
        allMutations->Array.push(field)
      }
    })
  )

  // Collect all query fields — detect collisions by field name
  // Start with Relay node query (single-resolver-owned: omitted from
  // standalone subgraph documents, where the platform's canonical source
  // owns the global `node` field)
  let seenQueryFields: Set.t<string> = Set.make()
  let allQueries: array<string> = []
  if includeGlobalNodeQuery {
    relayBaseQueries->Array.forEach(field => {
      let fieldName = extractLeadingName(field)
      seenQueryFields->Set.add(fieldName)
      allQueries->Array.push(field)
    })
  }

  parts->Array.forEach(({queries}) =>
    queries->Array.forEach(field => {
      let fieldName = extractLeadingName(field)
      if seenQueryFields->Set.has(fieldName) {
        log.warn(~comp="GraphQL_Stitcher", `Duplicate query field — skipped: ${fieldName}`)
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
        log.warn(~comp="GraphQL_Stitcher", `Duplicate subscription field — skipped: ${fieldName}`)
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

let stitch = (
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
): string =>
  assembleSdl(
    ~fragments=Array.concat([baseFragment], pluginFragments),
    ~includeGlobalNodeQuery=true,
  )

/**
Render ONE fragment as a standalone schema document for merge-based
composition (plugin = subgraph, platform = merge). The relay base types are
included so the document is self-contained and valid on its own; the global
`node(id: ID!)` root query is omitted — exactly one source (the platform's
canonical one) may own that field's resolver, so only the canonical base
document carries it (via `stitch`).
*/
let stitchStandalone = (~fragment: Reventless.Plugin.apiSchemaFragment): string =>
  assembleSdl(~fragments=[fragment], ~includeGlobalNodeQuery=false)

// (The schema-clobber guard family — rootTypeFieldNames / countRootTypeFields /
// missingRootFields / isCatastrophicSchemaShrink — was retired with the push
// machinery: under merged-API composition every source API is a single writer,
// so no whole-replace push exists to guard.)
