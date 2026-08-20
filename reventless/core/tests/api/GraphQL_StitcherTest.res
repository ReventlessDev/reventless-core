open JestGlobals
open GraphQL_Stitcher

describe("GraphQL_Stitcher.subscriptionSources", () => {
  testSync("encode/decode round-trips the subscription→mutation source mapping", () => {
    let fragment = encode({
      types: [],
      mutations: [`  Catalog_AddProduct(input: AddInput): CommandResult`],
      queries: [],
      subscriptions: [`  onCatalog_AddProduct(id: ID): CommandResult`],
      subscriptionSources: [{field: "onCatalog_AddProduct", mutations: ["Catalog_AddProduct"]}],
    })
    let parts = decode(fragment)
    expect(parts.subscriptionSources)->toEqual([
      {field: "onCatalog_AddProduct", mutations: ["Catalog_AddProduct"]},
    ])
  })

  testSync("decode tolerates fragments encoded before the field existed", () => {
    let legacy: Reventless.Plugin.apiSchemaFragment = {
      encoded: `{"types":[],"mutations":[],"queries":[],"subscriptions":["  onX(id: ID): CommandResult"]}`,
      protocol: "graphql",
    }
    expect(decode(legacy).subscriptionSources)->toEqual([])
  })

  testSync("collectSubscriptionSources unions across fragments, first wins per field", () => {
    let base = encode({
      types: [],
      mutations: [],
      queries: [],
      subscriptions: [`  onUIFragmentChange: UIFragmentChangeEvent`],
      subscriptionSources: [
        {field: "onUIFragmentChange", mutations: ["Platform_UIFragmentRegistered"]},
      ],
    })
    let pluginA = encode({
      types: [],
      mutations: [],
      queries: [],
      subscriptions: [`  onA(id: ID): CommandResult`],
      subscriptionSources: [
        {field: "onA", mutations: ["A"]},
        // Colliding field — the base fragment's mapping must win.
        {field: "onUIFragmentChange", mutations: ["Rogue_Mutation"]},
      ],
    })
    let collected = collectSubscriptionSources(~baseFragment=base, ~pluginFragments=[pluginA])
    expect(collected)->toEqual([
      {field: "onUIFragmentChange", mutations: ["Platform_UIFragmentRegistered"]},
      {field: "onA", mutations: ["A"]},
    ])
  })

  testSync("core-emitted admin base fragment carries no provider directives", () => {
    let base = Platform_AdminApi.baseFragment(~cloner=true)
    expect(base.encoded->String.includes("@aws_subscribe"))->toBe(false)
    expect(base.encoded->String.includes("@aws_auth"))->toBe(false)
    // The subscription→mutation fan-in rides the structured metadata instead.
    let parts = decode(base)
    let fields = parts.subscriptionSources->Array.map(s => s.field)
    expect(fields->Array.includes("onUIFragmentChange"))->toBe(true)
    expect(fields->Array.includes("onPluginStatusChange"))->toBe(true)
  })
})

// Two unions in one schema is what caught this: every definition keyword the name
// extractor does not strip makes each declaration of that kind name itself after
// the keyword, so the second dedupes against the first and is dropped. With
// `CommandResult` the only union, nothing showed it. The local path does not use
// this dedup, so a golden carrying both unions still passed while AppSync rejected
// the schema for a type that was never emitted.
describe("GraphQL_Stitcher.extractLeadingName", () => {
  testSync("names a union after the union, not after the keyword", () => {
    expect(extractLeadingName("union Geolocation = GeolocationLocated | GeolocationPending"))->toBe(
      "Geolocation",
    )
    expect(extractLeadingName("union CommandResult = CommandAccepted | CommandRejected"))->toBe(
      "CommandResult",
    )
  })

  testSync("names an interface and a scalar after themselves", () => {
    expect(extractLeadingName("interface Node { id: ID! }"))->toBe("Node")
    expect(extractLeadingName("scalar AWSDateTime"))->toBe("AWSDateTime")
  })

  // The cases that already worked, kept so a rewrite of the keyword list has to
  // keep them working.
  testSync("still names types, enums and inputs", () => {
    expect(extractLeadingName("type Ordering_Customer implements Node { id: ID! }"))->toBe(
      "Ordering_Customer",
    )
    expect(extractLeadingName("enum SortOrder { ASC DESC }"))->toBe("SortOrder")
    expect(extractLeadingName("input Ordering_CustomerFilter { id: ID }"))->toBe(
      "Ordering_CustomerFilter",
    )
  })

  // Fields go through the same extractor, and an arg-less one has no "(" to cleave
  // the type off.
  testSync("still names fields, with and without args", () => {
    expect(extractLeadingName("  Catalog_AddProduct(input: AddInput): CommandResult"))->toBe(
      "Catalog_AddProduct",
    )
    expect(extractLeadingName("  Platform_ApiFragments: [Fragment!]!"))->toBe(
      "Platform_ApiFragments",
    )
  })
})

describe("GraphQL_Stitcher.stitchStandalone", () => {
  let pluginFragment = encode({
    types: [
      `type Product implements Node {\n  id: ID!\n  name: String\n}`,
      `union CommandResult = CommandAccepted | CommandRejected | CommandPending`,
    ],
    mutations: [`  Catalog_AddProduct(input: AddInput): CommandResult`],
    queries: [`  Catalog_products: [Product]`],
    subscriptions: [`  onCatalog_AddProduct(id: ID): CommandResult`],
    subscriptionSources: [{field: "onCatalog_AddProduct", mutations: ["Catalog_AddProduct"]}],
  })

  testSync("renders a self-contained subgraph document with relay base types", () => {
    let sdl = stitchStandalone(~fragment=pluginFragment)
    expect(sdl)->toContain("interface Node {")
    expect(sdl)->toContain("type PageInfo {")
    expect(sdl)->toContain("type Product implements Node {")
    expect(sdl)->toContain("Catalog_AddProduct(input: AddInput): CommandResult")
    expect(sdl)->toContain("onCatalog_AddProduct(id: ID): CommandResult")
  })

  testSync("omits the global node query (the canonical base document owns it)", () => {
    let sdl = stitchStandalone(~fragment=pluginFragment)
    expect(sdl->String.includes("node(id: ID!): Node"))->toBe(false)
  })

  testSync("stitch keeps injecting the global node query (whole-schema path unchanged)", () => {
    let sdl = stitch(~baseFragment=pluginFragment, ~pluginFragments=[])
    expect(sdl)->toContain("node(id: ID!): Node")
  })
})
