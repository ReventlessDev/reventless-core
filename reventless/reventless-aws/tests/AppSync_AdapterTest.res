open TestHelpers

describe("AppSync_Adapter.sha256Hex", () => {
  test("returns a 64-character hex string", () => {
    let hash = AppSync_Adapter.sha256Hex("hello")
    expect(hash->String.length)->toBe(64)
  })

  test("is stable — same input produces same digest", () => {
    let sdl = "type Query { ping: String }"
    expect(AppSync_Adapter.sha256Hex(sdl))->toBe(AppSync_Adapter.sha256Hex(sdl))
  })

  test("differs for inputs that differ by one character", () => {
    let sdlA = "type Query { ping: String }"
    let sdlB = "type Query { pong: String }"
    expect(AppSync_Adapter.sha256Hex(sdlA))->not_->toBe(AppSync_Adapter.sha256Hex(sdlB))
  })
})

// Helper to decode a schema fragment for inspection.
let decodeFragment = (fragment: Reventless.Plugin.apiSchemaFragment) =>
  ReventlessCore.GraphQL_Stitcher.decode(fragment)

describe("AppSync_Adapter.injectAwsAuthAll", () => {
  let baseFragment = ReventlessCore.AdminApi.baseFragment(~cloner=true)

  test("adds @aws_auth directive to all mutation fields", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    parts.mutations->Array.forEach(field => {
      expect(field)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
    })
  })

  test("adds @aws_auth directive to all query fields", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    parts.queries->Array.forEach(field => {
      expect(field)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
    })
  })

  test("preserves type definitions unchanged", () => {
    let original = decodeFragment(baseFragment)
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    expect(parts.types)->toEqual(original.types)
  })

  test("uses specified group name", () => {
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
  test("preserves subscription fields with @aws_auth directive", () => {
    let original = decodeFragment(baseFragment)
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    expect(parts.subscriptions->Array.length)->toBe(original.subscriptions->Array.length)
    expect(parts.subscriptions->Array.length)->toBeGreaterThan(0)
    parts.subscriptions->Array.forEach(field => {
      expect(field)->toContain(`@aws_auth(cognito_groups: ["Admin"])`)
    })
  })

  test("admin Plugin aggregate subscription fields survive the round-trip", () => {
    let augmented = AppSync_Adapter.injectAwsAuthAll(baseFragment, ~group="Admin")
    let parts = decodeFragment(augmented)
    let joined = parts.subscriptions->Array.join("\n")
    expect(joined)->toContain("onPlatform_Plugin_Activate")
    expect(joined)->toContain("onPlatform_Plugin_Deactivate")
  })
})

describe("AppSync_Adapter.injectAwsAuth", () => {
  test("injects auth only on entries with authorization", () => {
    // Build a fragment with known entries
    let mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry> =
      ReventlessCore.AdminApi.mutationEntries(~cloner=false)
    let queryEntries = ReventlessCore.PluginBaseFragment.queryEntries

    let baseFragment = ReventlessCore.AdminApi.baseFragment(~cloner=false)
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
  test("produces fragment with auth directives from entries", () => {
    let mutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=false)
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

  test("AllowGroups([\"Admin\"]) emits cognito_groups: [\"Admin\"] on mutation", () => {
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

  test("AllowGroups multi-group emits comma-separated groups", () => {
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

  test("AllowAuthenticated emits no directive", () => {
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

  test("DenyAll emits sentinel __deny_all__ group", () => {
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

  test("Per-field permissions: only annotated fields get directives", () => {
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

  test("Query permission applies to BOTH single and list field names", () => {
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

  test("Spec-level permission wins over legacy authorization field", () => {
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

  test("AllowAuthenticated on a field overrides the legacy authorization (removes directive)", () => {
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

describe("Split mode — empty base fragment", () => {
  test("empty stitcher encode produces fragment with no fields", () => {
    let emptyFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [],
      queries: [],
      subscriptions: [],
    })
    let parts = decodeFragment(emptyFragment)
    expect(parts.types)->toHaveLength(0)
    expect(parts.mutations)->toHaveLength(0)
    expect(parts.queries)->toHaveLength(0)
  })

  test("stitching with empty base produces only plugin fields", () => {
    let emptyBase = ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [],
      queries: [],
      subscriptions: [],
    })
    let pluginFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [`type MyPlugin_Item { id: ID! }`],
      mutations: [`MyPlugin_Item_Create(id: ID!): String`],
      queries: [`MyPlugin_Item(id: ID!): MyPlugin_Item`],
      subscriptions: [],
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

  test("stitching admin base without plugins produces only admin fields", () => {
    let adminBase = ReventlessCore.AdminApi.baseFragment(~cloner=false)
    let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
      ~baseFragment=adminBase,
      ~pluginFragments=[],
    )
    expect(sdl)->toContain("Platform_Plugin")
  })
})
