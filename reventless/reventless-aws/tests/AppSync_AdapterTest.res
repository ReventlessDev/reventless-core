open TestHelpers

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

describe("Split mode — empty base fragment", () => {
  test("empty stitcher encode produces fragment with no fields", () => {
    let emptyFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [],
      mutations: [],
      queries: [],
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
    })
    let pluginFragment = ReventlessCore.GraphQL_Stitcher.encode({
      types: [`type MyPlugin_Item { id: ID! }`],
      mutations: [`MyPlugin_Item_Create(id: ID!): String`],
      queries: [`MyPlugin_Item(id: ID!): MyPlugin_Item`],
    })
    let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
      ~baseFragment=emptyBase,
      ~pluginFragments=[pluginFragment],
    )
    // SDL should contain plugin fields but no admin fields
    expect(sdl)->toContain("MyPlugin_Item_Create")
    expect(sdl)->toContain("MyPlugin_Item")
    // Should NOT contain admin fields
    expect(sdl)->not_->toContain("Admin_Plugin")
  })

  test("stitching admin base without plugins produces only admin fields", () => {
    let adminBase = ReventlessCore.AdminApi.baseFragment(~cloner=false)
    let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
      ~baseFragment=adminBase,
      ~pluginFragments=[],
    )
    expect(sdl)->toContain("Admin_Plugin")
  })
})
