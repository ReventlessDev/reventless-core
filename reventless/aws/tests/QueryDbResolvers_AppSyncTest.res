open JestGlobals

// The Plugins admin RM shares its table with bookkeeping rows (`deploy-schema:*`,
// `plugin-info:*`, `deploy-schema-hash:*`) carrying no `name`. The Connection Scan
// must exclude them, or `name: String!` nulls the whole connection.

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

// Tripwires for the Scan connection's paging. The behaviour itself is exercised
// against the evaluated resolver in `rescript/pulumi-aws`; these guard the wiring
// this package is responsible for emitting.
describe("listAllItemsConnection — paging", () => {
  let code = AppSync_Resolver_Retrying.Functions.listAllItemsConnection(~labelField="name")->codeOf

  testSync("the cursor round-trips a read window, not a synthetic index", () => {
    expect(code->String.includes("JSON.parse(util.base64Decode(ctx.args.after))"))->toBe(true)
    expect(code->String.includes("nextToken: _window,"))->toBe(true)
    // The regression: `cursor: ctx.args.after ? ctx.args.after + '_' + i : '' + i`.
    expect(code->String.includes("ctx.args.after + '_' + i"))->toBe(false)
  })

  testSync("a filtered read examines more rows than it serves", () => {
    // The budget reads as deep as the page needs, which for a backward cut is
    // `_upTo` rather than `_first + _from`.
    expect(
      code->String.includes("parts.length > 0 ? ((_backward ? _upTo : _first + _from) > 1000"),
    )->toBe(true)
    expect(code->String.includes("const _page = _backward ? _rest : _rest.slice(0, _first);"))
    ->toBe(true)
    expect(code->String.includes("hasNextPage: _more || !!_next,"))->toBe(true)
  })

  // `before` is served by re-reading the window the cursor names; only a previous
  // page lying in an EARLIER window is out of reach, and `last` — which needs the
  // end of the list — stays refused.
  testSync("backward paging is served, and its one limit is named", () => {
    expect(code->String.includes("ctx.args.before != null && ctx.args.before !== ''"))->toBe(true)
    expect(code->String.includes("_backward && _upTo <= 0 && _window !== null"))->toBe(true)
    expect(code->String.includes("UnsupportedPagination"))->toBe(true)
  })

  // The door must not advertise a previous page it cannot serve — that is what
  // put a live Prev button in front of an error.
  testSync("only a reachable previous page is advertised", () => {
    expect(code->String.includes("hasPreviousPage: _from > 0,"))->toBe(true)
    expect(code->String.includes("hasPreviousPage: !!ctx.args.after,"))->toBe(false)
  })

  testSync("a window emptied by the filter still yields a resumable boundary cursor", () => {
    expect(
      code->String.includes(
        "const _boundary = _next ? util.base64Encode(JSON.stringify({ t: _next, n: -1 })) : null;",
      ),
    )->toBe(true)
    expect(
      code->String.includes("edges.length > 0 ? edges[edges.length - 1].cursor : _boundary"),
    )->toBe(true)
  })
})
