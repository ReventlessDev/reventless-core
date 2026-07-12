open JestGlobals
open GraphQL_Stitcher

// A representative stitched schema: admin base (Platform_*) plus two domain
// plugins (Catalog_*, Ordering_*). 4 Mutation + 4 Query root fields.
let fullSchemaSdl = `type Node {
  id: ID!
}

type Query {
  node(id: ID!): Node
  Platform_plugins: [Plugin]
  Catalog_products: [Product]
  Ordering_orders: [Order]
}

type Mutation {
  Platform_connectPlugin(input: ConnectInput): ConnectResult
  Catalog_addProduct(input: AddInput): Product
  Catalog_updateProduct(input: UpdateInput): Product
  Ordering_placeOrder(input: OrderInput): Order
}`

// The exact failure observed in alpha: a lifecycle window collapses the live
// schema back to admin-base only — every Catalog_*/Ordering_* field gone.
// 1 Mutation + 2 Query root fields.
let collapsedSchemaSdl = `type Node {
  id: ID!
}

type Query {
  node(id: ID!): Node
  Platform_plugins: [Plugin]
}

type Mutation {
  Platform_connectPlugin(input: ConnectInput): ConnectResult
}`

// Real stitched shape: injectAwsAuthAll appends @aws_auth on its own indented
// line after each Mutation field, so a field spans two physical lines.
let authAnnotatedSdl = `type Mutation {
  Platform_connectPlugin(input: ConnectInput): ConnectResult
    @aws_auth(cognito_groups: ["Admin"])
  Catalog_addProduct(input: AddInput): Product
    @aws_auth(cognito_groups: ["User"])
}

type Query {
  node(id: ID!): Node @aws_auth(cognito_groups: ["Admin"])
}`

describe("GraphQL_Stitcher.countRootTypeFields", () => {
  testSync("counts Mutation fields", () => {
    expect(countRootTypeFields(~sdl=fullSchemaSdl, ~typeName="Mutation"))->toBe(4)
  })
  testSync("counts Query fields", () => {
    expect(countRootTypeFields(~sdl=fullSchemaSdl, ~typeName="Query"))->toBe(4)
  })
  testSync("ignores @aws_auth directive lines, counts each Mutation field once", () => {
    expect(countRootTypeFields(~sdl=authAnnotatedSdl, ~typeName="Mutation"))->toBe(2)
  })
  testSync("ignores @aws_auth directive lines, counts each Query field once", () => {
    expect(countRootTypeFields(~sdl=authAnnotatedSdl, ~typeName="Query"))->toBe(1)
  })
  testSync("missing type returns 0", () => {
    expect(countRootTypeFields(~sdl=fullSchemaSdl, ~typeName="Subscription"))->toBe(0)
  })
  testSync("empty SDL returns 0", () => {
    expect(countRootTypeFields(~sdl="", ~typeName="Mutation"))->toBe(0)
  })
})

describe("GraphQL_Stitcher.isCatastrophicSchemaShrink", () => {
  testSync("rejects the all-disconnected collapse (8 → 3 root fields, < 50%)", () => {
    expect(
      isCatastrophicSchemaShrink(~currentSdl=fullSchemaSdl, ~newSdl=collapsedSchemaSdl, ~threshold=0.5),
    )->toBe(true)
  })
  testSync("allows an intentional small removal above threshold (8 → 7)", () => {
    let minusOneSdl = `type Query {
  node(id: ID!): Node
  Platform_plugins: [Plugin]
  Catalog_products: [Product]
  Ordering_orders: [Order]
}

type Mutation {
  Platform_connectPlugin(input: ConnectInput): ConnectResult
  Catalog_addProduct(input: AddInput): Product
  Ordering_placeOrder(input: OrderInput): Order
}`
    expect(
      isCatastrophicSchemaShrink(~currentSdl=fullSchemaSdl, ~newSdl=minusOneSdl, ~threshold=0.5),
    )->toBe(false)
  })
  testSync("allows the first push when there is no live schema to protect", () => {
    expect(
      isCatastrophicSchemaShrink(~currentSdl="", ~newSdl=fullSchemaSdl, ~threshold=0.5),
    )->toBe(false)
  })
  testSync("allows an unchanged re-push (same SDL)", () => {
    expect(
      isCatastrophicSchemaShrink(~currentSdl=fullSchemaSdl, ~newSdl=fullSchemaSdl, ~threshold=0.5),
    )->toBe(false)
  })
  testSync("allows a purely additive push even below threshold cardinality", () => {
    // A tiny live schema growing into a big one drops nothing → never a clobber,
    // regardless of the ratio.
    expect(
      isCatastrophicSchemaShrink(~currentSdl=collapsedSchemaSdl, ~newSdl=fullSchemaSdl, ~threshold=0.5),
    )->toBe(false)
  })
  testSync("includes Subscription fields when judging a shrink", () => {
    let withSubs = `type Query {
  node(id: ID!): Node
}

type Mutation {
  Ordering_placeOrder(input: OrderInput): Order
}

type Subscription {
  onOrdering_Customer_Register: Customer
  onOrdering_Customer_UpdateAddress: Customer
  onCatalog_Product_Added: Product
}`
    // Dropping every Subscription field (and keeping Mutation/Query) is a shrink
    // the Mutation+Query-only guard would have missed.
    let subsGone = `type Query {
  node(id: ID!): Node
}

type Mutation {
  Ordering_placeOrder(input: OrderInput): Order
}`
    expect(
      isCatastrophicSchemaShrink(~currentSdl=withSubs, ~newSdl=subsGone, ~threshold=0.5),
    )->toBe(true)
  })
})

describe("GraphQL_Stitcher.rootTypeFieldNames", () => {
  testSync("lists Mutation field names", () => {
    expect(rootTypeFieldNames(~sdl=fullSchemaSdl, ~typeName="Mutation"))->toEqual([
      "Platform_connectPlugin",
      "Catalog_addProduct",
      "Catalog_updateProduct",
      "Ordering_placeOrder",
    ])
  })
  testSync("strips args and @aws_auth directive lines", () => {
    expect(rootTypeFieldNames(~sdl=authAnnotatedSdl, ~typeName="Mutation"))->toEqual([
      "Platform_connectPlugin",
      "Catalog_addProduct",
    ])
  })
  testSync("missing type returns []", () => {
    expect(rootTypeFieldNames(~sdl=fullSchemaSdl, ~typeName="Subscription"))->toEqual([])
  })
})

describe("GraphQL_Stitcher.missingRootFields", () => {
  testSync("reports plugin fields absent from an admin-base clobber", () => {
    // The alpha 2026-07-08 clobber: live schema is admin-base only. Every
    // Catalog_*/Ordering_* field the deploy expects is missing → repair fires.
    let missing = missingRootFields(~expectedSdl=fullSchemaSdl, ~liveSdl=collapsedSchemaSdl)
    expect(missing->Array.includes("Catalog_addProduct"))->toBe(true)
    expect(missing->Array.includes("Ordering_placeOrder"))->toBe(true)
    expect(missing->Array.includes("Ordering_orders"))->toBe(true)
  })
  testSync("empty when live schema is a superset (intact)", () => {
    expect(missingRootFields(~expectedSdl=fullSchemaSdl, ~liveSdl=fullSchemaSdl))->toEqual([])
  })
  testSync("detects an equal-cardinality field swap the count test misses", () => {
    // Same number of root fields, but one Mutation field replaced by a foreign
    // one — a swap. countRootTypeFields would report no drift; the name-set diff
    // catches it.
    let swapped = `type Query {
  node(id: ID!): Node
  Platform_plugins: [Plugin]
  Catalog_products: [Product]
  Ordering_orders: [Order]
}

type Mutation {
  Platform_connectPlugin(input: ConnectInput): ConnectResult
  Catalog_addProduct(input: AddInput): Product
  Catalog_updateProduct(input: UpdateInput): Product
  Foreign_strayField(input: OrderInput): Order
}`
    // Same count on both sides.
    expect(countRootTypeFields(~sdl=swapped, ~typeName="Mutation"))->toBe(
      countRootTypeFields(~sdl=fullSchemaSdl, ~typeName="Mutation"),
    )
    // But the expected Ordering_placeOrder is missing from the live (swapped) schema.
    let missing = missingRootFields(~expectedSdl=fullSchemaSdl, ~liveSdl=swapped)
    expect(missing->Array.includes("Ordering_placeOrder"))->toBe(true)
  })
})

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
    let base = AdminApi.baseFragment(~cloner=true)
    expect(base.encoded->String.includes("@aws_subscribe"))->toBe(false)
    expect(base.encoded->String.includes("@aws_auth"))->toBe(false)
    // The subscription→mutation fan-in rides the structured metadata instead.
    let parts = decode(base)
    let fields = parts.subscriptionSources->Array.map(s => s.field)
    expect(fields->Array.includes("onUIFragmentChange"))->toBe(true)
    expect(fields->Array.includes("onPluginStatusChange"))->toBe(true)
  })
})
