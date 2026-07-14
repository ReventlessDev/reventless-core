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

describe("AppSync_SdlDecorate.injectAwsAuthAll", () => {
  // Regression: an ARG-LESS field named in iamFieldNames must still get @aws_iam.
  // extractLeadingName used to return `Platform_ApiFragments:` (trailing colon) for
  // arg-less fields, so isIam missed it and the field stayed Cognito-only — which
  // 401'd the deploy waiter's SigV4 poll of Platform_ApiFragments on real AWS.
  testSync("dual-auths an arg-less query field named in iamFieldNames", () => {
    let base = ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [`  Platform_RegisterApiFragment(input: In): CommandResult`],
      queries: [`  Platform_ApiFragments: [Entry!]!`, `  Other_Query: Int`],
      subscriptions: [],
      subscriptionSources: [],
    })
    let decorated = AppSync_SdlDecorate.injectAwsAuthAll(
      base,
      ~group="Admin",
      ~iamFieldNames=["Platform_RegisterApiFragment", "Platform_ApiFragments"],
    )
    let parts = ReventlessCore.GraphQL_Stitcher.decode(decorated)
    let queryField = name =>
      parts.queries->Array.find(q => q->String.includes(name))->Option.getOrThrow
    // The arg-less IAM query gets dual-auth.
    expect(queryField("Platform_ApiFragments"))->toContain("@aws_iam")
    // The arg-full IAM mutation still does too.
    expect(parts.mutations->Array.getUnsafe(0))->toContain("@aws_iam")
    // A query NOT in iamFieldNames stays Cognito-only.
    let other = queryField("Other_Query")
    expect(other)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
    expect(other->String.includes("@aws_iam"))->toBe(false)
  })
})

describe("AppSync_SdlDecorate.planAwsPushes", () => {
  // Neutral admin base: a system-callable mutation + a shared traversal type.
  let rawAdminBase = ReventlessCore.GraphQL_Stitcher.encode({
    types: [`type CommandAccepted {\n  id: ID!\n}`],
    mutations: [`  Platform_RegisterApiFragment(input: ApiFragmentInput): CommandResult`],
    queries: [],
    subscriptions: [],
    subscriptionSources: [],
  })
  let iamFieldNames = ["Platform_RegisterApiFragment"]
  let mkFrag = (~mutation, ~target): AppSync_SdlDecorate.targetedFragmentInput => {
    encoded: ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [mutation],
      queries: [],
      subscriptions: [],
      subscriptionSources: [],
    }).encoded,
    protocol: "graphql",
    target,
  }
  let platformFrag = mkFrag(~mutation=`  Inspector_Ping: CommandResult`, ~target="Platform")
  let domainFrag = mkFrag(~mutation=`  Catalog_AddProduct(input: AddInput): CommandResult`, ~target="Domain")

  testSync("split mode: Platform API carries admin base (dual-auth) + Platform frags; Domain API excludes the admin base", () => {
    let plans = AppSync_SdlDecorate.planAwsPushes(
      ~rawAdminBase,
      ~iamFieldNames,
      ~fragments=[platformFrag, domainFrag],
      ~splitApi=true,
    )
    expect(plans->Array.length)->toBe(2)
    let platformPlan = plans->Array.find(p => p.api == "PlatformApi")->Option.getOrThrow
    let domainPlan = plans->Array.find(p => p.api == "DomainApi")->Option.getOrThrow
    // Admin base mutation lands on the Platform API with dual-auth (system caller).
    expect(platformPlan.sdl)->toContain("Platform_RegisterApiFragment")
    expect(platformPlan.sdl)->toContain(`@aws_cognito_user_pools(cognito_groups: ["Admin"]) @aws_iam`)
    // Platform-target plugin field present on the Platform API.
    expect(platformPlan.sdl)->toContain("Inspector_Ping")
    // Shared traversal type stamped once on the assembled SDL.
    expect(platformPlan.sdl)->toContain(`type CommandAccepted @aws_cognito_user_pools @aws_iam {`)
    // Domain-target field on the Domain API; admin base absent (empty base in split mode).
    expect(domainPlan.sdl)->toContain("Catalog_AddProduct")
    expect(domainPlan.sdl->String.includes("Platform_RegisterApiFragment"))->toBe(false)
  })

  testSync("unified mode: a single Domain API carries admin base + all frags", () => {
    let plans = AppSync_SdlDecorate.planAwsPushes(
      ~rawAdminBase,
      ~iamFieldNames,
      ~fragments=[platformFrag, domainFrag],
      ~splitApi=false,
    )
    expect(plans->Array.length)->toBe(1)
    let plan = plans->Array.getUnsafe(0)
    expect(plan.api)->toBe("DomainApi")
    expect(plan.sdl)->toContain("Platform_RegisterApiFragment")
    expect(plan.sdl)->toContain("Inspector_Ping")
    expect(plan.sdl)->toContain("Catalog_AddProduct")
  })
})

describe("AppSync_SdlDecorate.stampSharedIamTypes", () => {
  // Regression: the deploy waiter polls the IAM-callable Platform_ApiFragments query via
  // SigV4; its return type Platform_ApiFragmentEntry must carry the type-level @aws_iam or
  // the SigV4 caller reaches the query field but gets "Not Authorized to access <field> on
  // type Platform_ApiFragmentEntry" (deploy validation #7).
  testSync("stamps Platform_ApiFragmentEntry with dual-auth", () => {
    let sdl = AppSync_SdlDecorate.stampSharedIamTypes(
      "type Platform_ApiFragmentEntry {\n  pluginId: String!\n  pushStatus: String!\n}",
    )
    expect(sdl)->toContain("type Platform_ApiFragmentEntry @aws_cognito_user_pools @aws_iam {")
  })

  testSync("still stamps the CommandResult members", () => {
    let sdl = AppSync_SdlDecorate.stampSharedIamTypes("type CommandAccepted {\n  id: ID!\n}")
    expect(sdl)->toContain("type CommandAccepted @aws_cognito_user_pools @aws_iam {")
  })
})

describe("AppSync_SdlDecorate.stampCanonicalTypes", () => {
  testSync("stamps shared object types, the Node interface, and the CommandResult union", () => {
    let sdl = AppSync_SdlDecorate.stampCanonicalTypes(
      "interface Node {\n  id: ID!\n}\n\ntype PageInfo {\n  hasNextPage: Boolean!\n}\n\nunion CommandResult = CommandAccepted | CommandRejected | CommandPending\n\ntype CommandAccepted {\n  msgId: ID!\n}",
    )
    expect(sdl)->toContain("interface Node @canonical {")
    expect(sdl)->toContain("type PageInfo @canonical {")
    expect(sdl)->toContain("union CommandResult @canonical = CommandAccepted")
    expect(sdl)->toContain("type CommandAccepted @canonical {")
  })

  testSync("composes after stampSharedIamTypes and leaves other types alone", () => {
    let sdl =
      AppSync_SdlDecorate.stampSharedIamTypes(
        "type PageInfo {\n  hasNextPage: Boolean!\n}\n\ntype Product {\n  id: ID!\n}",
      )->AppSync_SdlDecorate.stampCanonicalTypes
    expect(sdl)->toContain("type PageInfo @aws_cognito_user_pools @aws_iam @canonical {")
    expect(sdl)->toContain("type Product {")
    expect(sdl->String.includes("type Product @canonical"))->toBe(false)
  })

  testSync("is idempotent", () => {
    let once = AppSync_SdlDecorate.stampCanonicalTypes("type PageInfo {\n  x: Int\n}")
    expect(AppSync_SdlDecorate.stampCanonicalTypes(once))->toBe(once)
  })
})
