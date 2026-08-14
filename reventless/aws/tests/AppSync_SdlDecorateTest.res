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
    @aws_cognito_user_pools(cognito_groups: ["Admin"])
  onCatalogEventLog_eventAppended: CatalogEventLogEvent
}`

describe("AppSync_SdlDecorate.injectAwsSubscribe", () => {
  testSync("appends @aws_subscribe on a 1:1 mutation-sourced field (with args)", () => {
    let sdl = AppSync_SdlDecorate.injectAwsSubscribe(stitchedSdl, ~sources)
    expect(sdl)->toContain(
      `onCatalog_AddProduct(id: ID): CommandResult\n    @aws_subscribe(mutations: ["Catalog_AddProduct"])`,
    )
  })

  testSync("appends the many-mutations fan-in on a no-arg field, keeping the group directive", () => {
    let sdl = AppSync_SdlDecorate.injectAwsSubscribe(stitchedSdl, ~sources)
    expect(sdl)->toContain(
      `onUIFragmentChange: UIFragmentChangeEvent\n    @aws_subscribe(mutations: ["Platform_UIFragmentRegistered", "Platform_UIFragmentUpdated", "Platform_UIFragmentDeregistered"])`,
    )
    // The auth directive line appended by injectAwsAuthAll survives.
    expect(sdl)->toContain(`@aws_cognito_user_pools(cognito_groups: ["Admin"])`)
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

describe("AppSync_Adapter.stitchStandaloneWithAwsDirectives", () => {
  testSync("assembles a neutral fragment into an AWS-dialect standalone document", () => {
    let fragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [`type PluginStatusChangeEvent {\n  pluginId: ID!\n}`],
      mutations: [`  Platform_PluginStatusChanged(pluginId: ID!, status: PluginStatus!): PluginStatusChangeEvent`],
      queries: [],
      subscriptions: [`  onPluginStatusChange: PluginStatusChangeEvent`],
      subscriptionSources: [
        {field: "onPluginStatusChange", mutations: ["Platform_PluginStatusChanged"]},
      ],
    })
    let sdl = AppSync_Adapter.stitchStandaloneWithAwsDirectives(~fragment)
    expect(sdl)->toContain(`@aws_subscribe(mutations: ["Platform_PluginStatusChanged"])`)
    // Standalone documents never carry the global node query (dropped on AWS —
    // see the merged-api plan's Relay node resolution).
    expect(sdl)->not_->toContain("node(id: ID!): Node")
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
    expect(other)->toContain(`@aws_cognito_user_pools(cognito_groups: ["Admin"])`)
    expect(other->String.includes("@aws_iam"))->toBe(false)
  })
})


describe("AppSync_SdlDecorate.stampSharedIamTypes", () => {
  testSync("stamps the CommandResult members", () => {
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

// ── Type-level Cognito stamping (defaultAction: DENY groundwork) ─────────────
//
// With `defaultAction: ALLOW` an undirectived type is reachable by any
// authenticated Cognito caller, so this pass changes nothing observable. It
// exists so the default can be flipped to DENY, where an undirectived type is
// refused mid-traversal even for a caller who passed the field's own gate.

describe("AppSync_SdlDecorate.stampAllTypesCognito", () => {
  testSync("stamps an undirectived object type", () => {
    let sdl = AppSync_SdlDecorate.stampAllTypesCognito("type Product {\n  id: ID!\n}")
    expect(sdl)->toContain("type Product @aws_cognito_user_pools {")
  })

  testSync("leaves an already-directived type alone, keeping its @aws_iam arm", () => {
    let sdl =
      AppSync_SdlDecorate.stampSharedIamTypes(
        "type PageInfo {\n  hasNextPage: Boolean!\n}",
      )->AppSync_SdlDecorate.stampAllTypesCognito
    expect(sdl)->toContain("type PageInfo @aws_cognito_user_pools @aws_iam {")
    // Not double-stamped.
    expect(sdl->String.includes("@aws_cognito_user_pools @aws_cognito_user_pools"))->toBe(false)
  })

  testSync("does not stamp input, enum, union or interface declarations", () => {
    let sdl = AppSync_SdlDecorate.stampAllTypesCognito(
      "input ProductFilter {\n  id: ID\n}\n\nenum Status {\n  Active\n}\n\nunion CommandResult = CommandAccepted | CommandRejected\n\ninterface Node {\n  id: ID!\n}",
    )
    expect(sdl->String.includes("@aws_cognito_user_pools"))->toBe(false)
  })

  testSync("is idempotent", () => {
    let once = AppSync_SdlDecorate.stampAllTypesCognito("type Product {\n  id: ID!\n}")
    expect(AppSync_SdlDecorate.stampAllTypesCognito(once))->toBe(once)
  })
})

// ── Final field sweep ───────────────────────────────────────────────────────
//
// `injectAwsAuth` only decorates fields it can pair with a schema entry. Several
// surfaces never reach it: the domain base (`Platform_ping`), event-history
// queries, `…_eventAppended` subscriptions, upload mutations,
// `Platform_SetActiveRole`, `geocode`. A deployed-SDL count after the first
// sweep found 11 such fields still bare on the domain API. This pass is the net.

describe("AppSync_SdlDecorate.stampUndirectivedFields", () => {
  let frag = (~mutations=[], ~queries=[], ~subscriptions=[], ()) =>
    ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations,
      queries,
      subscriptions,
      subscriptionSources: [],
    })

  testSync("stamps a query no schema entry ever paired with", () => {
    let out = AppSync_SdlDecorate.stampUndirectivedFields(
      frag(~queries=["  Platform_ping: String"], ()),
    )
    let q = ReventlessCore.GraphQL_Stitcher.decode(out).queries->Array.getUnsafe(0)
    expect(q)->toContain("@aws_cognito_user_pools")
    expect(q)->not_->toContain("cognito_groups")
  })

  testSync("stamps an event-log subscription", () => {
    let out = AppSync_SdlDecorate.stampUndirectivedFields(
      frag(~subscriptions=["  onFoo_eventAppended: FooEvent"], ()),
    )
    expect(
      ReventlessCore.GraphQL_Stitcher.decode(out).subscriptions->Array.getUnsafe(0),
    )->toContain("@aws_cognito_user_pools")
  })

  testSync("leaves an already-gated field untouched, group and all", () => {
    let gated = `  Secret_Read: String\n    @aws_cognito_user_pools(cognito_groups: ["Admin"])`
    let out = AppSync_SdlDecorate.stampUndirectivedFields(frag(~queries=[gated], ()))
    let q = ReventlessCore.GraphQL_Stitcher.decode(out).queries->Array.getUnsafe(0)
    expect(q)->toContain(`cognito_groups: ["Admin"]`)
    expect(q->String.includes("@aws_cognito_user_pools @aws_cognito_user_pools"))->toBe(false)
  })

  testSync("does not strip an @aws_iam arm", () => {
    let dual = "  Sys_Sync: String\n    @aws_cognito_user_pools @aws_iam"
    let out = AppSync_SdlDecorate.stampUndirectivedFields(frag(~mutations=[dual], ()))
    expect(
      ReventlessCore.GraphQL_Stitcher.decode(out).mutations->Array.getUnsafe(0),
    )->toContain("@aws_iam")
  })

  testSync("is idempotent", () => {
    let once = AppSync_SdlDecorate.stampUndirectivedFields(frag(~queries=["  a: String"], ()))
    let twice = AppSync_SdlDecorate.stampUndirectivedFields(once)
    expect(ReventlessCore.GraphQL_Stitcher.decode(twice).queries->Array.getUnsafe(0))->toBe(
      ReventlessCore.GraphQL_Stitcher.decode(once).queries->Array.getUnsafe(0),
    )
  })
})

// ── Deploy-time gate invariant ──────────────────────────────────────────────
//
// `defaultAction: DENY` — the request-time fail-closed switch — is unavailable:
// AWS refuses it alongside an additional auth provider, and every API here has
// AWS_IAM. So this check moves fail-closed into the deploy, where nothing can
// veto it: a schema that cannot be gated is never pushed.

describe("AppSync_SdlDecorate.assertGateable", () => {
  let refuses = (sdl: string): bool =>
    switch AppSync_SdlDecorate.assertGateable(sdl) {
    | _ => false
    | exception _ => true
    }

  // The original outage, exactly. A "does it have a directive?" check passes
  // this — @aws_auth was present on all 18 admin fields the whole time it was
  // inert. Only knowing WHICH directive the service honours catches it.
  testSync("refuses @aws_auth, the directive AppSync ignores here", () => {
    let sdl = `type Query @aws_cognito_user_pools {\n  Admin_Thing: String @aws_auth(cognito_groups: ["Admin"])\n}`
    expect(refuses(sdl))->toBe(true)
  })

  testSync("refuses a root field carrying no enforced directive", () => {
    expect(refuses("type Query @aws_cognito_user_pools {\n  Platform_ping: String\n}"))->toBe(true)
  })

  testSync("refuses an object type carrying no enforced directive", () => {
    let sdl =
      "type Query @aws_cognito_user_pools {\n  a: String @aws_cognito_user_pools\n}\ntype Product {\n  id: ID!\n}"
    expect(refuses(sdl))->toBe(true)
  })

  // Our real emission shape puts a mutation's directive on the FOLLOWING line.
  testSync("accepts a directive on the line after the field", () => {
    let sdl = "type Query @aws_cognito_user_pools {\n  Platform_ping: String\n    @aws_cognito_user_pools\n}"
    expect(refuses(sdl))->toBe(false)
  })

  testSync("accepts a group-gated field and an @aws_iam-only field", () => {
    let sdl =
      `type Mutation @aws_cognito_user_pools {\n  Gated: String\n    @aws_cognito_user_pools(cognito_groups: ["Admin"])\n  Sys: String\n    @aws_cognito_user_pools @aws_iam\n}`
    expect(refuses(sdl))->toBe(false)
  })

  // The whole pipeline must satisfy its own invariant on the real admin base.
  testSync("the assembled admin base passes", () => {
    let decorated = AppSync_Adapter.injectAwsAuthAll(
      ReventlessCore.Platform_AdminApi.baseFragment(~cloner=true),
      ~group="Admin",
    )
    let sdl = AppSync_Adapter.stitchStandaloneWithAwsDirectives(~fragment=decorated)
    expect(sdl->String.includes("@aws_cognito_user_pools"))->toBe(true)
  })
})
