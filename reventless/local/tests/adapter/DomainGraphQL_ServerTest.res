// Tests for DomainGraphQL_Server's plugin=subgraph scoped registry (Phase 6
// of the merged-API composition plan). Mirrors the AWS model locally: each
// plugin scope's registrations form a standalone subgraph document that is
// validated in isolation and composed with graphql-tools merge semantics at
// start()/composeSchema().

open JestGlobals

module Server = DomainGraphQL_Server

// Execute a query directly against a composed schema (no HTTP server needed).
type executionResult = {data: Nullable.t<JSON.t>, errors: Nullable.t<array<JSON.t>>}
@module("graphql")
external graphqlExecute: {"schema": GraphqlYoga.schema, "source": string} => promise<executionResult> =
  "graphql"

let intResolver = (value: int): Server.resolverFn =>
  async (_root, _args, _ctx) =>
    JSON.Encode.object(Dict.fromArray([("x", JSON.Encode.int(value))]))

let resolversOf = (entries: array<(string, Server.resolverFn)>) => Dict.fromArray(entries)

let sharedTypeSdl = `type SharedThing {\n  x: Int\n}`

let dataField = (result: executionResult, ~field: string): option<int> =>
  result.data
  ->Nullable.toOption
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get(field))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("x"))
  ->Option.flatMap(JSON.Decode.float)
  ->Option.map(Float.toInt)

let exnMessage = (err: JsExn.t): string => JsExn.message(err)->Option.getOr("")

beforeEach(() => Server.reset())
afterAll(() => Server.reset())

// ── (a) identical shared-type copies compose; both plugins' fields resolve ──

test("two scopes with identical shared-type copies compose and both fields resolve", async () => {
  Server.setScope("PluginA")
  Server.registerTypes(~sdlTypes=[sharedTypeSdl])
  Server.registerQueries(
    ~sdlFields=["  aItem: SharedThing"],
    ~resolvers=resolversOf([("aItem", intResolver(1))]),
  )
  Server.setScope("PluginB")
  Server.registerTypes(~sdlTypes=[sharedTypeSdl])
  Server.registerQueries(
    ~sdlFields=["  bItem: SharedThing"],
    ~resolvers=resolversOf([("bItem", intResolver(2))]),
  )
  Server.resetScope()

  // Cross-bucket resolver lookup (MCP_Server path) sees both scopes.
  expect(Server.getQueryResolver("aItem")->Option.isSome)->toBe(true)
  expect(Server.getQueryResolver("bItem")->Option.isSome)->toBe(true)

  let schema = Server.composeSchema()
  let result = await graphqlExecute({"schema": schema, "source": "{ aItem { x } bItem { x } }"})
  expect(result.errors->Nullable.toOption->Option.isNone)->toBe(true)
  expect(dataField(result, ~field="aItem"))->toEqual(Some(1))
  expect(dataField(result, ~field="bItem"))->toEqual(Some(2))
})

// ── (b) standalone-invalid scope fails with plugin-name attribution ─────────

testSync("scope referencing an undefined type fails standalone validation naming the plugin", () => {
  // Register under a construction token, then relabel to the plugin name —
  // exercising the Platform.res flow (name only known after construction).
  Server.setScope("plugin-token-1")
  Server.registerQueries(
    ~sdlFields=["  broken: MissingType"],
    ~resolvers=resolversOf([("broken", intResolver(0))]),
  )
  Server.relabelScope(~from="plugin-token-1", ~to_="BrokenPlugin")
  Server.resetScope()

  switch Server.composeSchema() {
  | _ => Runner.fail("expected composeSchema to throw")
  | exception JsExn(err) => {
      expect(exnMessage(err))->toContain(
        `Plugin "BrokenPlugin" subgraph document is not valid standalone`,
      )
      expect(exnMessage(err))->toContain("MissingType")
    }
  }
})

// ── (c) conflicting same-named type across scopes fails the merge ────────────

testSync("two scopes defining the same type name with conflicting fields fail composition", () => {
  Server.setScope("PluginA")
  Server.registerTypes(~sdlTypes=[`type SharedThing {\n  x: Int\n}`])
  Server.registerQueries(
    ~sdlFields=["  aItem: SharedThing"],
    ~resolvers=resolversOf([("aItem", intResolver(1))]),
  )
  Server.setScope("PluginB")
  Server.registerTypes(~sdlTypes=[`type SharedThing {\n  x: String\n}`])
  Server.registerQueries(
    ~sdlFields=["  bItem: SharedThing"],
    ~resolvers=resolversOf([("bItem", intResolver(2))]),
  )
  Server.resetScope()

  switch Server.composeSchema() {
  | _ => Runner.fail("expected composeSchema to throw")
  | exception JsExn(err) =>
    expect(exnMessage(err))->toContain("Cross-plugin schema merge failed (mirrors AWS MERGE_FAILED)")
  }
})

// ── (d) reset clears buckets and restores the platform scope ────────────────

testSync("reset clears all scope buckets and restores the platform scope", () => {
  Server.setScope("PluginA")
  Server.registerTypes(~sdlTypes=[sharedTypeSdl])
  Server.registerQueries(
    ~sdlFields=["  aItem: SharedThing"],
    ~resolvers=resolversOf([("aItem", intResolver(1))]),
  )

  Server.reset()

  expect(Server.currentScope.contents)->toBe("platform")
  expect(Server.getQueryResolver("aItem")->Option.isNone)->toBe(true)
  let d = Server.diagnostics()
  expect(d.typeCount)->toBe(0)
  expect(d.sdlQueryCount)->toBe(0)
  expect(d.resolverQueryCount)->toBe(0)
  // Post-reset registrations land in the platform bucket again.
  Server.registerQueries(
    ~sdlFields=["  pItem: String"],
    ~resolvers=resolversOf([("pItem", intResolver(0))]),
  )
  expect(Server.buildSdl()->String.includes("pItem"))->toBe(true)
})

// ── per-scope shared types keep plugin subgraphs standalone-valid ────────────

test("scope missing its own shared-type copy fails standalone even when platform defines it", async () => {
  // The platform bucket defines SharedThing; the plugin bucket references it
  // without carrying its own copy — standalone-invalid, mirroring an AWS
  // source API that leans on another API's types.
  Server.registerTypes(~sdlTypes=[sharedTypeSdl]) // platform scope
  Server.setScope("Leaner")
  Server.registerQueries(
    ~sdlFields=["  leanItem: SharedThing"],
    ~resolvers=resolversOf([("leanItem", intResolver(3))]),
  )
  Server.resetScope()

  switch Server.composeSchema() {
  | _ => Runner.fail("expected composeSchema to throw")
  | exception JsExn(err) =>
    expect(exnMessage(err))->toContain(`Plugin "Leaner" subgraph document is not valid standalone`)
  }
})
