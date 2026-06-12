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
})
