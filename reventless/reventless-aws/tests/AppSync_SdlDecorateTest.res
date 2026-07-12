// AppSync_SdlDecorate — push-time @aws_subscribe injection from the neutral
// subscription→mutation source metadata. Core emits directive-free SDL; the
// AWS provider appends its dialect onto the STITCHED schema here.

open JestGlobals

let sources: array<ReventlessCore.GraphQL_Stitcher.subscriptionSource> = [
  {field: "onCatalog_AddProduct", mutations: ["Catalog_AddProduct"]},
  {
    field: "onUIFragmentChange",
    mutations: [
      "Platform_UIFragmentRegistered",
      "Platform_UIFragmentUpdated",
      "Platform_UIFragmentDeregistered",
    ],
  },
]

let stitchedSdl = `type UIFragmentChangeEvent {
  pluginId: ID!
}

type Query {
  node(id: ID!): Node
}

type Mutation {
  Catalog_AddProduct(input: AddInput): CommandResult
}

type Subscription {
  onCatalog_AddProduct(id: ID): CommandResult
  onUIFragmentChange: UIFragmentChangeEvent
    @aws_auth(cognito_groups: ["Admin"])
  onCatalogEventLog_eventAppended: CatalogEventLogEvent
}`

describe("AppSync_SdlDecorate.injectAwsSubscribe", () => {
  testSync("appends @aws_subscribe on a 1:1 mutation-sourced field (with args)", () => {
    let sdl = AppSync_SdlDecorate.injectAwsSubscribe(stitchedSdl, ~sources)
    expect(sdl)->toContain(
      `onCatalog_AddProduct(id: ID): CommandResult\n    @aws_subscribe(mutations: ["Catalog_AddProduct"])`,
    )
  })

  testSync("appends the many-mutations fan-in on a no-arg field, keeping @aws_auth", () => {
    let sdl = AppSync_SdlDecorate.injectAwsSubscribe(stitchedSdl, ~sources)
    expect(sdl)->toContain(
      `onUIFragmentChange: UIFragmentChangeEvent\n    @aws_subscribe(mutations: ["Platform_UIFragmentRegistered", "Platform_UIFragmentUpdated", "Platform_UIFragmentDeregistered"])`,
    )
    // The auth directive line appended by injectAwsAuthAll survives.
    expect(sdl)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
  })

  testSync("leaves unmapped fields (Source A) and non-Subscription blocks untouched", () => {
    let sdl = AppSync_SdlDecorate.injectAwsSubscribe(stitchedSdl, ~sources)
    expect(sdl)->toContain(`onCatalogEventLog_eventAppended: CatalogEventLogEvent\n}`)
    // The Mutation field shares its leading name with a source's mutation —
    // it must not be decorated (only the Subscription block is).
    expect(sdl)->toContain(`Catalog_AddProduct(input: AddInput): CommandResult\n}`)
  })

  testSync("no-op on empty sources or an SDL without a Subscription block", () => {
    expect(AppSync_SdlDecorate.injectAwsSubscribe(stitchedSdl, ~sources=[]))->toBe(stitchedSdl)
    let noSubs = `type Query {\n  node(id: ID!): Node\n}`
    expect(AppSync_SdlDecorate.injectAwsSubscribe(noSubs, ~sources))->toBe(noSubs)
  })
})

describe("AppSync_Adapter.stitchWithAwsDirectives", () => {
  testSync("assembles neutral fragments into AWS-dialect SDL", () => {
    let baseFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [`  Platform_PluginStatusChanged(pluginId: ID!, status: PluginStatus!): PluginStatusChangeEvent`],
      queries: [],
      subscriptions: [`  onPluginStatusChange: PluginStatusChangeEvent`],
      subscriptionSources: [
        {field: "onPluginStatusChange", mutations: ["Platform_PluginStatusChanged"]},
      ],
    })
    let pluginFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [`type PluginStatusChangeEvent {\n  pluginId: ID!\n}`],
      mutations: [`  Catalog_AddProduct(input: AddInput): CommandResult`],
      queries: [],
      subscriptions: [`  onCatalog_AddProduct(id: ID): CommandResult`],
      subscriptionSources: [{field: "onCatalog_AddProduct", mutations: ["Catalog_AddProduct"]}],
    })
    let sdl = AppSync_Adapter.stitchWithAwsDirectives(
      ~baseFragment,
      ~pluginFragments=[pluginFragment],
    )
    expect(sdl)->toContain(`@aws_subscribe(mutations: ["Platform_PluginStatusChanged"])`)
    expect(sdl)->toContain(`@aws_subscribe(mutations: ["Catalog_AddProduct"])`)
  })
})
