open JestGlobals

// Regression guard for docs/plans/platform-plugins-admin-connection-null-rows.md:
// the Plugins admin RM shares its DynamoDB table with internal bookkeeping rows
// (`deploy-schema:*`, `plugin-info:*`, `deploy-schema-hash:*`) that carry no `name`.
// The auto-generated Connection Scan must exclude them, or `name: String!` resolves
// to null and nulls the entire Platform_PluginConnection ("No data" on the page).

// `Pulumi.Input.make` is `%identity`, so a generated resolver's `Pulumi.Input.t<string>`
// IS the underlying JS string — recover it with Obj.magic for assertion.
let codeOf = (input: Pulumi.Input.t<string>): string => Obj.magic(input)

describe("QueryDbResolvers_AppSync.internalRowRequiredAttr", () => {
  testSync("Plugins RM requires the `name` discriminator", () => {
    expect(QueryDbResolvers_AppSync.internalRowRequiredAttr("Plugins"))->toEqual(Some("name"))
  })

  testSync("ordinary read models require nothing (unchanged behaviour)", () => {
    expect(QueryDbResolvers_AppSync.internalRowRequiredAttr("Products"))->toEqual(None)
    expect(QueryDbResolvers_AppSync.internalRowRequiredAttr("Orders"))->toEqual(None)
  })
})

describe("AppSync_Resolver_Retrying.Functions.listAllItemsConnection", () => {
  testSync("with ~requireAttribute emits an attribute_exists filter that excludes internal rows", () => {
    let code =
      AppSync_Resolver_Retrying.Functions.listAllItemsConnection(
        ~labelField="name",
        ~requireAttribute="name",
      )->codeOf
    expect(code->String.includes("attribute_exists(#name)"))->toBe(true)
    expect(code->String.includes("names['#name'] = 'name'"))->toBe(true)
  })

  testSync("without ~requireAttribute emits no attribute_exists filter (default read models unchanged)", () => {
    let code =
      AppSync_Resolver_Retrying.Functions.listAllItemsConnection(~labelField="name")->codeOf
    expect(code->String.includes("attribute_exists"))->toBe(false)
  })
})
