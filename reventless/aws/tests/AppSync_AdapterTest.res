open JestGlobals

describe("AppSync_Adapter.sha256Hex", () => {
  testSync("returns a 64-character hex string", () => {
    let hash = AppSync_Adapter.sha256Hex("hello")
    expect(hash->String.length)->toBe(64)
  })

  testSync("is stable — same input produces same digest", () => {
    let sdl = "type Query { ping: String }"
    expect(AppSync_Adapter.sha256Hex(sdl))->toBe(AppSync_Adapter.sha256Hex(sdl))
  })

  testSync("differs for inputs that differ by one character", () => {
    let sdlA = "type Query { ping: String }"
    let sdlB = "type Query { pong: String }"
    expect(AppSync_Adapter.sha256Hex(sdlA))->not_->toBe(AppSync_Adapter.sha256Hex(sdlB))
  })
})

// Helper to decode a schema fragment for inspection.
let decodeFragment = (fragment: Reventless.Plugin.apiSchemaFragment) =>
  ReventlessCore.GraphQL_Stitcher.decode(fragment)

describe("AppSync_Adapter.injectAwsAuthAll", () => {
  let baseFragment = ReventlessCore.Platform_AdminApi.baseFragment(~cloner=true)

  testSync("adds @aws_auth directive to all mutation fields", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    parts.mutations->Array.forEach(field => {
      expect(field)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
    })
  })

  testSync("adds @aws_auth directive to all query fields", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    parts.queries->Array.forEach(field => {
      expect(field)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
    })
  })

  testSync("preserves type definitions unchanged", () => {
    let original = decodeFragment(baseFragment)
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    expect(parts.types)->toEqual(original.types)
  })

  testSync("uses specified group name", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="SuperAdmin")
    let parts = decodeFragment(augmented)
    parts.mutations->Array.forEach(field => {
      expect(field)->toContain(`cognito_groups: ["SuperAdmin"]`)
    })
  })

  // Regression: `injectAwsAuthAll` used to re-encode the fragment without the
  // `subscriptions` array, silently dropping every Subscription field on the
  // admin base. That caused AppSync to reject the auto-generated resolver for
  // `Subscription.onPlatform_Plugin_Activate` (and Deactivate) with "Type not
  // found" at deploy time. The subscription fields must survive the round-trip
  // and pick up the same @aws_auth group as mutations/queries.
  testSync("preserves subscription fields with @aws_auth directive", () => {
    let original = decodeFragment(baseFragment)
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    expect(parts.subscriptions->Array.length)->toBe(original.subscriptions->Array.length)
    expect(parts.subscriptions->Array.length)->toBeGreaterThan(0)
    parts.subscriptions->Array.forEach(field => {
      expect(field)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
    })
  })

  testSync("admin Plugin aggregate subscription fields survive the round-trip", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    let joined = parts.subscriptions->Array.join("\n")
    expect(joined)->toContain("onPlatform_Plugin_Activate")
    expect(joined)->toContain("onPlatform_Plugin_Deactivate")
  })
})

describe("AppSync_Adapter.injectAwsAuth", () => {
  testSync("injects auth only on entries with authorization", () => {
    // Build a fragment with known entries
    let mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry> =
      ReventlessCore.Platform_AdminApi.mutationEntries(~cloner=false)
    let queryEntries = ReventlessCore.PluginBaseFragment.queryEntries

    let baseFragment = ReventlessCore.Platform_AdminApi.baseFragment(~cloner=false)
    let augmented = AppSync_Adapter.injectAwsAuth(
      baseFragment,
      ~mutationEntries,
      ~queryEntries,
    )
    let parts = decodeFragment(augmented)

    // Query entries have authorization → should have @aws_auth
    let queryWithAuth =
      queryEntries->Array.some(entry => entry.authorization->Option.isSome)
    if queryWithAuth {
      let hasAuthQuery = parts.queries->Array.some(field =>
        field->String.includes("@aws_auth")
      )
      expect(hasAuthQuery)->toBe(true)
    }
  })
})

describe("AppSync_Adapter.generateFragment", () => {
  testSync("produces fragment with auth directives from entries", () => {
    let mutationEntries = ReventlessCore.Platform_AdminApi.mutationEntries(~cloner=false)
    let queryEntries = ReventlessCore.PluginBaseFragment.queryEntries

    let fragment = AppSync_Adapter.generateFragment(~mutationEntries, ~queryEntries)
    let parts = decodeFragment(fragment)

    // Should have types, mutations, and queries
    expect(parts.types->Array.length)->toBeGreaterThan(0)
    expect(parts.mutations->Array.length)->toBeGreaterThan(0)
    expect(parts.queries->Array.length)->toBeGreaterThan(0)
  })
})

// ── Stage E2: spec-level permission → @aws_auth directive ───────────────
//
// Verifies that `injectAwsAuth` lifts the `Authorization.permission` values
// (set by Plugin_Builder / Dcb_Builder from `@@reventless.authorize` /
// `@authorize` PPX annotations) into `@aws_auth(cognito_groups: [...])`
// directives on the corresponding SDL fields.

describe("AppSync_Adapter.injectAwsAuth — Stage E2 permission lifting", () => {
  // Minimal mutation fragment with two fields. Field names must match what
  // the entries declare so the stitcher's extractLeadingName can pair them.
  let makeFragment = (mutationFields, queryFields) =>
    ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: mutationFields,
      queries: queryFields,
      subscriptions: [],
      subscriptionSources: [],
    })

  let mutationEntry = (
    ~fieldNames: array<string>,
    ~fieldPermissions: dict<Reventless.Authorization.permission>,
  ): ReventlessInfra.Api.mutationSchemaEntry => {
    fieldNames,
    commandSchema: S.unknown,
    fieldPermissions,
  }

  let queryEntry = (
    ~single,
    ~list,
    ~permission: option<Reventless.Authorization.permission>,
  ): ReventlessInfra.Api.querySchemaEntry => {
    singleFieldName: single,
    listFieldName: list,
    returnTypeName: single,
    stateSchema: S.unknown,
    authorization: None,
    permission: ?permission,
  }

  testSync("AllowGroups([\"Admin\"]) emits cognito_groups: [\"Admin\"] on mutation", () => {
    let fp = Dict.fromArray([(
      "catalog_Category_Archive",
      Reventless.Authorization.AllowGroups(["Admin"]),
    )])
    let entry = mutationEntry(
      ~fieldNames=["catalog_Category_Archive"],
      ~fieldPermissions=fp,
    )
    let frag = makeFragment(["catalog_Category_Archive(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[entry],
      ~queryEntries=[],
    )
    let parts = decodeFragment(aug)
    let m = parts.mutations->Array.getUnsafe(0)
    expect(m)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
  })

  testSync("AllowGroups multi-group emits comma-separated groups", () => {
    let fp = Dict.fromArray([(
      "p_X",
      Reventless.Authorization.AllowGroups(["Admin", "Editor"]),
    )])
    let entry = mutationEntry(~fieldNames=["p_X"], ~fieldPermissions=fp)
    let frag = makeFragment(["p_X(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[entry],
      ~queryEntries=[],
    )
    let parts = decodeFragment(aug)
    expect(parts.mutations->Array.getUnsafe(0))->toContain(
      `@aws_auth(cognito_groups: ["Admin", "Editor"])`,
    )
  })

  testSync("AllowAuthenticated emits no directive", () => {
    let fp = Dict.fromArray([(
      "p_Add",
      Reventless.Authorization.AllowAuthenticated,
    )])
    let entry = mutationEntry(~fieldNames=["p_Add"], ~fieldPermissions=fp)
    let frag = makeFragment(["p_Add(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[entry],
      ~queryEntries=[],
    )
    let parts = decodeFragment(aug)
    expect(parts.mutations->Array.getUnsafe(0))->not_->toContain("@aws_auth")
  })

  testSync("DenyAll emits sentinel __deny_all__ group", () => {
    let fp = Dict.fromArray([("p_Hide", Reventless.Authorization.DenyAll)])
    let entry = mutationEntry(~fieldNames=["p_Hide"], ~fieldPermissions=fp)
    let frag = makeFragment(["p_Hide(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[entry],
      ~queryEntries=[],
    )
    let parts = decodeFragment(aug)
    expect(parts.mutations->Array.getUnsafe(0))->toContain(`"__deny_all__"`)
  })

  testSync("Per-field permissions: only annotated fields get directives", () => {
    let fp = Dict.fromArray([
      ("p_Archive", Reventless.Authorization.AllowGroups(["Admin"])),
      ("p_Add", Reventless.Authorization.AllowAuthenticated),
    ])
    let entry = mutationEntry(
      ~fieldNames=["p_Archive", "p_Add"],
      ~fieldPermissions=fp,
    )
    let frag = makeFragment(
      ["p_Archive(id: ID!): String", "p_Add(name: String!): String"],
      [],
    )
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[entry],
      ~queryEntries=[],
    )
    let parts = decodeFragment(aug)
    let archive = parts.mutations->Array.find(f => f->String.includes("p_Archive"))
    let add = parts.mutations->Array.find(f => f->String.includes("p_Add"))
    switch archive {
    | Some(f) => expect(f)->toContain(`cognito_groups: ["Admin"]`)
    | None => JsError.throwWithMessage("missing archive field")
    }
    switch add {
    | Some(f) => expect(f)->not_->toContain("@aws_auth")
    | None => JsError.throwWithMessage("missing add field")
    }
  })

  testSync("Query permission applies to BOTH single and list field names", () => {
    let entry = queryEntry(
      ~single="p_Item",
      ~list="p_Items",
      ~permission=Some(Reventless.Authorization.AllowGroups(["Manager"])),
    )
    // Production query SDL emitted by GraphQL_FragmentGenerator always has an
    // arg list (Relay pagination on the list field), so extractLeadingName's
    // paren-first split reliably yields the bare field name.
    let frag = makeFragment(
      [],
      [
        "p_Item(id: ID!): Item",
        "p_Items(first: Int, after: String): ItemConnection!",
      ],
    )
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[],
      ~queryEntries=[entry],
    )
    let parts = decodeFragment(aug)
    let item = parts.queries->Array.find(f => f->String.includes("p_Item("))
    let items = parts.queries->Array.find(f => f->String.includes("p_Items("))
    switch (item, items) {
    | (Some(s), Some(l)) =>
      expect(s)->toContain(`cognito_groups: ["Manager"]`)
      expect(l)->toContain(`cognito_groups: ["Manager"]`)
    | _ => JsError.throwWithMessage("missing query fields")
    }
  })

  testSync("Spec-level permission wins over legacy authorization field", () => {
    // Legacy {tableName, group} says "Admin"; spec-level says "Manager".
    // Spec-level must win.
    let fp = Dict.fromArray([(
      "p_X",
      Reventless.Authorization.AllowGroups(["Manager"]),
    )])
    let entry: ReventlessInfra.Api.mutationSchemaEntry = {
      fieldNames: ["p_X"],
      commandSchema: S.unknown,
      authorization: {
        Reventless.ReadModel.tableName: "Tbl",
        group: "Admin",
      },
      fieldPermissions: fp,
    }
    let frag = makeFragment(["p_X(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[entry],
      ~queryEntries=[],
    )
    let parts = decodeFragment(aug)
    let m = parts.mutations->Array.getUnsafe(0)
    expect(m)->toContain(`cognito_groups: ["Manager"]`)
    expect(m)->not_->toContain(`"Admin"`)
  })

  testSync("AllowAuthenticated on a field overrides the legacy authorization (removes directive)", () => {
    let fp = Dict.fromArray([(
      "p_X",
      Reventless.Authorization.AllowAuthenticated,
    )])
    let entry: ReventlessInfra.Api.mutationSchemaEntry = {
      fieldNames: ["p_X"],
      commandSchema: S.unknown,
      authorization: {
        Reventless.ReadModel.tableName: "Tbl",
        group: "Admin",
      },
      fieldPermissions: fp,
    }
    let frag = makeFragment(["p_X(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(
      frag,
      ~mutationEntries=[entry],
      ~queryEntries=[],
    )
    let parts = decodeFragment(aug)
    expect(parts.mutations->Array.getUnsafe(0))->not_->toContain("@aws_auth")
  })
})

// ── Dual-auth (Cognito + IAM) for deploy-time system callers ────────────────
//
// A field flagged `systemCallable` must be reachable by BOTH the console UI
// (Cognito) and the deploy-time SigV4 system caller (AWS_IAM). It switches from
// the single-mode `@aws_auth(...)` form to the multi-auth
// `@aws_cognito_user_pools(...) @aws_iam` form.

describe("AppSync_Adapter.injectAwsAuth — systemCallable dual-auth", () => {
  let makeFragment = (mutationFields, queryFields) =>
    ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: mutationFields,
      queries: queryFields,
      subscriptions: [],
      subscriptionSources: [],
    })

  testSync("systemCallable mutation with a group emits @aws_cognito_user_pools + @aws_iam", () => {
    let entry: ReventlessInfra.Api.mutationSchemaEntry = {
      fieldNames: ["p_Sync"],
      commandSchema: S.unknown,
      fieldPermissions: Dict.fromArray([("p_Sync", Reventless.Authorization.AllowGroups(["Admin"]))]),
      systemCallable: true,
    }
    let frag = makeFragment(["p_Sync(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(frag, ~mutationEntries=[entry], ~queryEntries=[])
    let m = decodeFragment(aug).mutations->Array.getUnsafe(0)
    expect(m)->toContain(`@aws_cognito_user_pools(cognito_groups: ["Admin"])`)
    expect(m)->toContain("@aws_iam")
    // Must NOT emit the single-mode form, which does not admit IAM.
    expect(m)->not_->toContain("@aws_auth")
  })

  testSync("systemCallable mutation without a group restriction stays open to Cognito + IAM", () => {
    let entry: ReventlessInfra.Api.mutationSchemaEntry = {
      fieldNames: ["p_Sync"],
      commandSchema: S.unknown,
      fieldPermissions: Dict.fromArray([("p_Sync", Reventless.Authorization.AllowAuthenticated)]),
      systemCallable: true,
    }
    let frag = makeFragment(["p_Sync(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(frag, ~mutationEntries=[entry], ~queryEntries=[])
    let m = decodeFragment(aug).mutations->Array.getUnsafe(0)
    // Bare @aws_cognito_user_pools (any authenticated Cognito user) + IAM.
    expect(m)->toContain("@aws_cognito_user_pools @aws_iam")
    expect(m)->not_->toContain("cognito_groups")
    expect(m)->not_->toContain("@aws_auth")
  })

  testSync("a non-systemCallable sibling keeps single-mode @aws_auth (no @aws_iam)", () => {
    let entry: ReventlessInfra.Api.mutationSchemaEntry = {
      fieldNames: ["p_Sync", "p_Other"],
      commandSchema: S.unknown,
      fieldPermissions: Dict.fromArray([
        ("p_Sync", Reventless.Authorization.AllowGroups(["Admin"])),
        ("p_Other", Reventless.Authorization.AllowGroups(["Admin"])),
      ]),
      // systemCallable applies to every field in the entry; split the fields so only
      // p_Sync opts in.
      systemCallable: false,
    }
    let iamEntry: ReventlessInfra.Api.mutationSchemaEntry = {
      fieldNames: ["p_Sync"],
      commandSchema: S.unknown,
      fieldPermissions: Dict.fromArray([("p_Sync", Reventless.Authorization.AllowGroups(["Admin"]))]),
      systemCallable: true,
    }
    let frag = makeFragment(["p_Sync(id: ID!): String", "p_Other(id: ID!): String"], [])
    let aug = AppSync_Adapter.injectAwsAuth(frag, ~mutationEntries=[entry, iamEntry], ~queryEntries=[])
    let parts = decodeFragment(aug)
    switch parts.mutations->Array.find(f => f->String.includes("p_Other")) {
    | Some(other) =>
      expect(other)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
      expect(other)->not_->toContain("@aws_iam")
    | None => JsError.throwWithMessage("missing p_Other field")
    }
  })

  testSync("systemCallable query applies dual-auth to BOTH single and list fields", () => {
    let entry: ReventlessInfra.Api.querySchemaEntry = {
      singleFieldName: "p_Item",
      listFieldName: "p_Items",
      returnTypeName: "p_Item",
      stateSchema: S.unknown,
      authorization: None,
      permission: Reventless.Authorization.AllowGroups(["Admin"]),
      systemCallable: true,
    }
    let frag = makeFragment(
      [],
      ["p_Item(id: ID!): Item", "p_Items(first: Int, after: String): ItemConnection!"],
    )
    let aug = AppSync_Adapter.injectAwsAuth(frag, ~mutationEntries=[], ~queryEntries=[entry])
    let parts = decodeFragment(aug)
    switch (
      parts.queries->Array.find(f => f->String.includes("p_Item(")),
      parts.queries->Array.find(f => f->String.includes("p_Items(")),
    ) {
    | (Some(single), Some(list)) =>
      expect(single)->toContain(`@aws_cognito_user_pools(cognito_groups: ["Admin"])`)
      expect(single)->toContain("@aws_iam")
      expect(list)->toContain(`@aws_cognito_user_pools(cognito_groups: ["Admin"])`)
      expect(list)->toContain("@aws_iam")
    | _ => JsError.throwWithMessage("missing query fields")
    }
  })

  testSync("systemCallable dual-auth extends to derived query fields (Items/ByIds/By<Index>)", () => {
    let entry: ReventlessInfra.Api.querySchemaEntry = {
      singleFieldName: "p_Item",
      listFieldName: "p_Items",
      returnTypeName: "p_Item",
      stateSchema: S.unknown,
      authorization: None,
      permission: Reventless.Authorization.AllowGroups(["Admin"]),
      systemCallable: true,
    }
    let frag = makeFragment(
      [],
      [
        "p_ItemItems(id: ID!, first: Int): p_ItemConnection!",
        "p_ItemsByIds(ids: [ID!]!): [p_Item]!",
        "p_ItemByOwner(id: ID!, first: Int): p_ItemConnection!",
        "q_Unrelated(id: ID!): String",
      ],
    )
    let aug = AppSync_Adapter.injectAwsAuth(frag, ~mutationEntries=[], ~queryEntries=[entry])
    let parts = decodeFragment(aug)
    parts.queries->Array.forEach(field =>
      if field->String.includes("q_Unrelated") {
        expect(field)->not_->toContain("@aws_iam")
      } else {
        expect(field)->toContain("@aws_iam")
      }
    )
  })
})

// ── Type-level dual-auth ─────────────────────────────────────────────────────
//
// On a multi-auth API a field directive alone is not enough: response shaping
// walks the return TYPES (Connection → Edge → node → nested state types), each
// of which is default-mode-only without its own directive. Types prefixed by a
// systemCallable entry's returnTypeName get the bare multi-auth pair; shared
// traversal types (PageInfo / CommandResult members) are stamped once on the
// assembled SDL.

describe("AppSync_Adapter — type-level dual-auth", () => {
  let makeFragmentWithTypes = (types, queryFields) =>
    ReventlessCore.GraphQL_Stitcher.encode({
      types,
      mutations: [],
      queries: queryFields,
      subscriptions: [],
      subscriptionSources: [],
    })

  let callableEntry: ReventlessInfra.Api.querySchemaEntry = {
    singleFieldName: "p_Item",
    listFieldName: "p_Items",
    returnTypeName: "p_Item",
    stateSchema: S.unknown,
    authorization: None,
    permission: Reventless.Authorization.AllowGroups(["Admin"]),
    systemCallable: true,
  }

  let types = [
    "type p_Item implements Node {\n  id: ID!\n}",
    "type p_ItemConnection {\n  edges: [p_ItemEdge!]!\n}",
    "type p_ItemEdge {\n  node: p_Item!\n}",
    "type p_ItemNested {\n  x: String\n}",
    "type q_Sibling {\n  id: ID!\n}",
    "input p_ItemItemsFilter {\n  eq: String\n}",
  ]

  testSync("types prefixed by a callable entry's returnTypeName carry the multi-auth pair", () => {
    let frag = makeFragmentWithTypes(types, ["p_Item(id: ID!): p_Item"])
    let aug = AppSync_Adapter.injectAwsAuth(frag, ~mutationEntries=[], ~queryEntries=[callableEntry])
    let parts = decodeFragment(aug)
    parts.types->Array.forEach(decl =>
      if decl->String.startsWith("type p_Item") {
        expect(decl)->toContain("@aws_cognito_user_pools @aws_iam {")
      } else {
        // The sibling view's type and the (non-authorizable) input stay untouched.
        expect(decl)->not_->toContain("@aws_iam")
      }
    )
  })

  testSync("without a systemCallable entry no type is stamped", () => {
    let plainEntry: ReventlessInfra.Api.querySchemaEntry = {
      ...callableEntry,
      systemCallable: false,
    }
    let frag = makeFragmentWithTypes(types, ["p_Item(id: ID!): p_Item"])
    let aug = AppSync_Adapter.injectAwsAuth(frag, ~mutationEntries=[], ~queryEntries=[plainEntry])
    decodeFragment(aug).types->Array.forEach(decl => expect(decl)->not_->toContain("@aws_iam"))
  })

  testSync("stampSharedIamTypes marks PageInfo + CommandResult members on the assembled SDL", () => {
    let sdl = [
      "interface Node {\n  id: ID!\n}",
      "type PageInfo {\n  hasNextPage: Boolean!\n}",
      "union CommandResult = CommandAccepted | CommandRejected | CommandPending",
      "type CommandAccepted {\n  msgId: ID!\n}",
      "type CommandRejected {\n  msgId: ID!\n}",
      "type CommandPending {\n  msgId: ID!\n}",
      "type Untouched {\n  id: ID!\n}",
    ]->Array.join("\n\n")
    let stamped = AppSync_Adapter.stampSharedIamTypes(sdl)
    expect(stamped)->toContain("type PageInfo @aws_cognito_user_pools @aws_iam {")
    expect(stamped)->toContain("type CommandAccepted @aws_cognito_user_pools @aws_iam {")
    expect(stamped)->toContain("type CommandRejected @aws_cognito_user_pools @aws_iam {")
    expect(stamped)->toContain("type CommandPending @aws_cognito_user_pools @aws_iam {")
    expect(stamped)->toContain("type Untouched {")
    // The union declaration itself takes no directive.
    expect(stamped)->toContain("union CommandResult = CommandAccepted | CommandRejected | CommandPending")
  })
})

describe("AppSync_Adapter.injectAwsAuthAll — ~iamFieldNames", () => {
  let baseFragment = ReventlessCore.Platform_AdminApi.baseFragment(~cloner=true)

  testSync("marks only the named field dual-auth, leaving others single-mode", () => {
    // Pick a real mutation field name from the admin base fragment.
    let firstMutationName =
      decodeFragment(baseFragment).mutations
      ->Array.getUnsafe(0)
      ->ReventlessCore.GraphQL_Stitcher.extractLeadingName
    let augmented =
      AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin", ~iamFieldNames=[firstMutationName])
    let parts = decodeFragment(augmented)
    parts.mutations->Array.forEach(field => {
      let name = ReventlessCore.GraphQL_Stitcher.extractLeadingName(field)
      if name == firstMutationName {
        expect(field)->toContain(`@aws_cognito_user_pools(cognito_groups: ["Admin"])`)
        expect(field)->toContain("@aws_iam")
        expect(field)->not_->toContain("@aws_auth")
      } else {
        expect(field)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
        expect(field)->not_->toContain("@aws_iam")
      }
    })
  })

  testSync("default (no ~iamFieldNames) leaves every field single-mode @aws_auth", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    parts.mutations->Array.forEach(field => expect(field)->not_->toContain("@aws_iam"))
    parts.queries->Array.forEach(field => expect(field)->not_->toContain("@aws_iam"))
  })
})

describe("Split mode — empty base fragment", () => {
  testSync("empty stitcher encode produces fragment with no fields", () => {
    let emptyFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [],
      queries: [],
      subscriptions: [],
      subscriptionSources: [],
    })
    let parts = decodeFragment(emptyFragment)
    expect(parts.types)->toHaveLength(0)
    expect(parts.mutations)->toHaveLength(0)
    expect(parts.queries)->toHaveLength(0)
  })

  testSync("stitching with empty base produces only plugin fields", () => {
    let emptyBase = ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [],
      queries: [],
      subscriptions: [],
      subscriptionSources: [],
    })
    let pluginFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [`type MyPlugin_Item { id: ID! }`],
      mutations: [`MyPlugin_Item_Create(id: ID!): String`],
      queries: [`MyPlugin_Item(id: ID!): MyPlugin_Item`],
      subscriptions: [],
      subscriptionSources: [],
    })
    let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
      ~baseFragment=emptyBase,
      ~pluginFragments=[pluginFragment],
    )
    // SDL should contain plugin fields but no admin fields
    expect(sdl)->toContain("MyPlugin_Item_Create")
    expect(sdl)->toContain("MyPlugin_Item")
    // Should NOT contain admin fields
    expect(sdl)->not_->toContain("Platform_Plugin")
  })

  testSync("stitching admin base without plugins produces only admin fields", () => {
    let adminBase = ReventlessCore.Platform_AdminApi.baseFragment(~cloner=false)
    let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
      ~baseFragment=adminBase,
      ~pluginFragments=[],
    )
    expect(sdl)->toContain("Platform_Plugin")
  })
})

// ── Merged mode — canonical source documents ─────────────────────────────────
//
// On the merge path (merged-api-push-free-composition, Phase 3) the platform-
// owned source APIs carry their schemas DECLARATIVELY: the admin base (or, in
// split mode, the bare relay base) stitched with an empty plugin list and
// stamped @canonical. These tests pin the assembled documents' load-bearing
// properties; Platform.res composes exactly this pipeline.

describe("Merged mode — canonical source documents", () => {
  let assembleCanonicalSourceSdl = (~baseFragment) =>
    AppSync_Adapter.stitchStandaloneWithAwsDirectives(~fragment=baseFragment)
    ->AppSync_SdlDecorate.stampCanonicalTypes

  // Mirrors Platform.res's domainBaseFragment: no component fields, one
  // Platform_ping so the Query type is non-empty.
  let domainBaseFragment = ReventlessCore.GraphQL_Stitcher.encode({
    types: [],
    mutations: [],
    queries: ["  Platform_ping: String"],
    subscriptions: [],
    subscriptionSources: [],
  })

  let adminSourceSdl = assembleCanonicalSourceSdl(
    ~baseFragment=AppSync_Adapter.injectAwsAuthAll(
      ReventlessCore.Platform_AdminApi.baseFragment(~cloner=false),
      ~group="Admin",
    ),
  )

  let domainBaseSourceSdl = assembleCanonicalSourceSdl(~baseFragment=domainBaseFragment)

  testSync("no AWS source document carries the global node query (dropped — see plan)", () => {
    expect(adminSourceSdl)->not_->toContain("node(id: ID!): Node")
    expect(domainBaseSourceSdl)->not_->toContain("node(id: ID!): Node")
    // The Node interface and global IDs stay — they are what makes a future
    // node() possible without a schema migration.
    expect(adminSourceSdl)->toContain("interface Node")
  })

  testSync("admin source document stamps @canonical on the shared traversal types", () => {
    expect(adminSourceSdl)->toContain("type PageInfo @aws_cognito_user_pools @aws_iam @canonical {")
    expect(adminSourceSdl)->toContain("interface Node @canonical {")
    expect(adminSourceSdl)->toContain("union CommandResult @canonical =")
    expect(adminSourceSdl)->toContain(
      "type CommandAccepted @aws_cognito_user_pools @aws_iam @canonical {",
    )
  })

  testSync("admin source document keeps admin fields and shared-type IAM stamps", () => {
    expect(adminSourceSdl)->toContain("Platform_Plugin")
    // Type-level dual-auth on the shared traversal types (stampSharedIamTypes);
    // no FIELD carries @aws_iam anymore — the SigV4 register/deregister surface
    // died with the fragment registry.
    expect(adminSourceSdl)->toContain("type PageInfo @aws_cognito_user_pools @aws_iam")
  })

  testSync("Domain base source document (split mode) is relay types + Platform_ping only", () => {
    expect(domainBaseSourceSdl)->toContain("Platform_ping: String")
    expect(domainBaseSourceSdl)->toContain("interface Node @canonical {")
    expect(domainBaseSourceSdl)->toContain("type PageInfo")
    // No admin or plugin fields on the split-mode Domain source.
    expect(domainBaseSourceSdl)->not_->toContain("Platform_Plugin")
    // No mutations → no CommandResult family on this source.
    expect(domainBaseSourceSdl)->not_->toContain("union CommandResult")
  })

  // Phase 4: the plugin-stack subgraph document pushed to the plugin's own
  // source API.
  let pluginFragment = ReventlessCore.GraphQL_Stitcher.encode({
    types: [
      "type MyPlugin_Item implements Node {\n  id: ID!\n  name: String!\n}",
      "type CommandAccepted {\n  msgId: ID!\n  eventCount: Int!\n}",
    ],
    mutations: ["MyPlugin_Item_Create(name: String!): CommandResult"],
    queries: ["MyPlugin_Item(id: ID!): MyPlugin_Item"],
    subscriptions: ["onMyPlugin_Item_Create(id: ID): CommandResult"],
    subscriptionSources: [
      {field: "onMyPlugin_Item_Create", mutations: ["MyPlugin_Item_Create"]},
    ],
  })

  testSync("plugin subgraph document is standalone: relay types included, node omitted", () => {
    let sdl = AppSync_Adapter.stitchStandaloneWithAwsDirectives(~fragment=pluginFragment)
    expect(sdl)->toContain("interface Node")
    expect(sdl)->toContain("type PageInfo")
    expect(sdl)->toContain("MyPlugin_Item_Create")
    expect(sdl)->not_->toContain("node(id: ID!): Node")
  })

  testSync("plugin subgraph document carries @aws_subscribe + shared-type IAM stamps, no @canonical", () => {
    let sdl = AppSync_Adapter.stitchStandaloneWithAwsDirectives(~fragment=pluginFragment)
    expect(sdl)->toContain(`@aws_subscribe(mutations: ["MyPlugin_Item_Create"])`)
    expect(sdl)->toContain("type CommandAccepted @aws_cognito_user_pools @aws_iam {")
    // Plugin subgraphs stay unstamped — the admin source's canonical defs win.
    expect(sdl)->not_->toContain("@canonical")
  })
})

// ── waitForMergeSuccess — association merge-status poll ─────────────────────

describe("AppSync_Adapter.waitForMergeSuccess", () => {
  // Fake AppSync client: `send` yields the canned responses in order and
  // repeats the last one when the poll outruns the script.
  let makeFakeClient = (
    responses: array<AppSync_Adapter.getSourceApiAssociationResult>,
  ): AppSync_Adapter.appSyncClient => {
    let i = ref(0)
    let fake = {
      "send": _cmd => {
        let idx = Math.Int.min(i.contents, responses->Array.length - 1)
        i := i.contents + 1
        Promise.resolve(responses->Array.getUnsafe(idx))
      },
    }
    fake->Obj.magic
  }

  let response = (~status, ~detail=?): AppSync_Adapter.getSourceApiAssociationResult => {
    sourceApiAssociation: Some({
      sourceApiAssociationStatus: Some(status),
      sourceApiAssociationStatusDetail: detail,
    }),
  }

  test("resolves once the association reports MERGE_SUCCESS", async () => {
    let client = makeFakeClient([
      response(~status="MERGE_SCHEDULED"),
      response(~status="MERGE_IN_PROGRESS"),
      response(~status="MERGE_SUCCESS"),
    ])
    await AppSync_Adapter.waitForMergeSuccess(
      client,
      ~associationId="assoc-1",
      ~mergedApiIdentifier="merged-1",
      ~delayMs=1,
    )
  })

  test("throws with the AWS status detail on MERGE_FAILED", async () => {
    let client = makeFakeClient([
      response(
        ~status="MERGE_FAILED",
        ~detail="Unable to resolve conflict on object with name SharedThing.x",
      ),
    ])
    let message = ref("")
    try {
      await AppSync_Adapter.waitForMergeSuccess(
        client,
        ~associationId="assoc-1",
        ~mergedApiIdentifier="merged-1",
        ~delayMs=1,
      )
    } catch {
    | exn =>
      message :=
        exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("(no message)")
    }
    expect(message.contents)->toContain("MERGE_FAILED")
    expect(message.contents)->toContain("SharedThing.x")
  })

  test("times out after maxAttempts on a status that never settles", async () => {
    let client = makeFakeClient([response(~status="MERGE_IN_PROGRESS")])
    let message = ref("")
    try {
      await AppSync_Adapter.waitForMergeSuccess(
        client,
        ~associationId="assoc-1",
        ~mergedApiIdentifier="merged-1",
        ~maxAttempts=2,
        ~delayMs=1,
      )
    } catch {
    | exn =>
      message :=
        exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("(no message)")
    }
    expect(message.contents)->toContain("timed out")
    expect(message.contents)->toContain("MERGE_IN_PROGRESS")
  })
})
