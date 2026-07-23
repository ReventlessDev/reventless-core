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

// Tripwires for docs/plans/aws-scan-connection-cursor-roundtrip.md. The Scan
// resolver's cursor must round-trip DynamoDB's own continuation token, not a
// synthetic index — every list past page 1 was unreachable before this.
describe("listAllItemsConnection — Scan cursor round-trip (paging fixes 1–3)", () => {
  let code = AppSync_Resolver_Retrying.Functions.listAllItemsConnection(~labelField="name")->codeOf

  testSync("Fix 1: response encodes the real nextToken as the cursor", () => {
    expect(code->String.includes("const next = ctx.result?.nextToken ?? null;"))->toBe(true)
    expect(
      code->String.includes("util.base64Encode(JSON.stringify({ token: next, index: i }))"),
    )->toBe(true)
    expect(code->String.includes("hasNextPage: !!next,"))->toBe(true)
  })

  testSync("Fix 1: request decodes `after` back to the DynamoDB token", () => {
    expect(code->String.includes("JSON.parse(util.base64Decode(ctx.args.after))"))->toBe(true)
    expect(code->String.includes("nextToken: after,"))->toBe(true)
  })

  testSync("Fix 1: the old synthetic-index cursor is gone", () => {
    // The regression: `cursor: ctx.args.after ? ctx.args.after + '_' + i : '' + i`.
    expect(code->String.includes("ctx.args.after + '_' + i"))->toBe(false)
  })

  testSync("Fix 2: backward paging (last/before) is rejected, not silently mishandled", () => {
    expect(code->String.includes("ctx.args.before != null || ctx.args.last != null"))->toBe(true)
    expect(code->String.includes("UnsupportedPagination"))->toBe(true)
  })

  testSync("Fix 3: an empty/short filtered page still yields a resumable boundary cursor", () => {
    expect(
      code->String.includes(
        "const boundary = next ? util.base64Encode(JSON.stringify({ token: next, index: -1 })) : null;",
      ),
    )->toBe(true)
    expect(
      code->String.includes("edges.length > 0 ? edges[edges.length - 1].cursor : boundary"),
    )->toBe(true)
  })
})
