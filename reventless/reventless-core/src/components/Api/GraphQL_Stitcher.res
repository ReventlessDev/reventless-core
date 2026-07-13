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

let isIdentStart = (line: string): bool =>
  switch line->String.codePointAt(0) {
  // A-Z (65-90), a-z (97-122), or `_` (95)
  | Some(c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
  | None => false
  }

/**
List the field NAMES defined inside a root object type (`Mutation` / `Query` /
`Subscription`) of a full SDL string.

This is the identity-aware primitive underlying every schema-clobber guard:
`countRootTypeFields` is just its length, and the deploy-time repair / shrink
guards compare the returned NAME SETS rather than cardinalities so they catch
field *swaps* and equal-cardinality drift that a count comparison misses.

Heuristic but adequate: root operation fields are flat single-line declarations
(`name(args): T` or `name: T`), so we slice the `type <typeName> { … }` block at
its first `{`/`}` and read the leading identifier of each indented line that
begins with an identifier character, ignoring directive-only lines (`@…`),
comments (`#…`) and braces.
*/
let rootTypeFieldNames = (~sdl: string, ~typeName: string): array<string> => {
  let marker = `type ${typeName}`
  switch sdl->String.indexOfOpt(marker) {
  | None => []
  | Some(typeStart) =>
    let rest = sdl->String.slice(~start=typeStart)
    switch (rest->String.indexOfOpt("{"), rest->String.indexOfOpt("}")) {
    | (Some(openIdx), Some(closeIdx)) if closeIdx > openIdx =>
      rest
      ->String.slice(~start=openIdx + 1, ~end=closeIdx)
      ->String.split("\n")
      ->Array.filterMap(line => {
        let trimmed = line->String.trim
        if trimmed->String.length > 0 && isIdentStart(trimmed) {
          // `name(args): T` → extractLeadingName strips the arg list; `name: T`
          // (no args) leaves a trailing colon on the token — drop it so a field
          // reads the same whether or not it takes arguments.
          let name = extractLeadingName(trimmed)
          let name = name->String.endsWith(":")
            ? name->String.slice(~start=0, ~end=name->String.length - 1)
            : name
          name->String.length > 0 ? Some(name) : None
        } else {
          None
        }
      })
    | _ => []
    }
  }
}

/**
Count the field definitions inside a root object type (`Mutation` / `Query`) of a
full SDL string. Length of `rootTypeFieldNames`.
*/
let countRootTypeFields = (~sdl: string, ~typeName: string): int =>
  rootTypeFieldNames(~sdl, ~typeName)->Array.length

// The three GraphQL root operation types every clobber guard reasons over.
let rootTypeNames = ["Mutation", "Query", "Subscription"]

/**
Union of every root-operation field name across `Mutation` + `Query` +
`Subscription`. The identity set the deploy-time repair and shrink guards diff.
*/
let allRootFieldNames = (~sdl: string): array<string> =>
  rootTypeNames->Array.flatMap(typeName => rootTypeFieldNames(~sdl, ~typeName))

/**
Root-operation field names present in `expectedSdl` but MISSING from `liveSdl`
(across Mutation + Query + Subscription). Non-empty ⇒ the live schema is not a
superset of what we expect and a repair push is warranted — this heals field
*swaps* and equal-cardinality drift that a bare count comparison would skip.
*/
let missingRootFields = (~expectedSdl: string, ~liveSdl: string): array<string> => {
  let liveSet = allRootFieldNames(~sdl=liveSdl)->Set.fromArray
  allRootFieldNames(~sdl=expectedSdl)->Array.filter(name => !(liveSet->Set.has(name)))
}

/**
Decide whether replacing the live schema (`currentSdl`) with `newSdl` would drop
root-operation fields the pushing stack does not carry — i.e. an almost-certainly
transient/incomplete stitch rather than an intentional removal.

Identity-based (across `Mutation` + `Query` + `Subscription`):
- When `newSdl`'s field-name set is a SUPERSET of the live set — nothing is
  dropped — it is purely additive (or unchanged) and never a clobber, so this
  returns `false` even when the pushing stack is legitimately adding its own
  fields.
- Otherwise it falls back to the cardinality threshold on the union of the three
  root types: `true` only when the new total drops below `threshold` × the
  current total. A small intentional removal (above threshold) is allowed.

When the current schema has no countable root fields (e.g. first deploy, or
introspection was unavailable so `currentSdl` is empty) it returns `false` so the
initial push always proceeds.
*/
let isCatastrophicSchemaShrink = (~currentSdl: string, ~newSdl: string, ~threshold: float): bool => {
  let currentNames = allRootFieldNames(~sdl=currentSdl)
  let newSet = allRootFieldNames(~sdl=newSdl)->Set.fromArray
  let dropped = currentNames->Array.filter(name => !(newSet->Set.has(name)))
  if dropped->Array.length == 0 {
    // Additive or unchanged push — the new schema keeps every live field.
    false
  } else {
    let current = currentNames->Array.length
    let next = allRootFieldNames(~sdl=newSdl)->Array.length
    current > 0 && next->Int.toFloat < current->Int.toFloat *. threshold
  }
}
