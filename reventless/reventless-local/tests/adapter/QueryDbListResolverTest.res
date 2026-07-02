// Behavioural tests for the in-memory connection list resolver
// (QueryDbResolvers_GraphQL). Phase 1.5 — keyset pagination on top of the
// Phase 1 filter / sort wiring.

@@warning("-44")

open JestGlobals

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Test state spec — five-row fixture exercising filter / sort / paginate
// ─────────────────────────────────────────────────────────────

@schema
type rowState = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  status: string,
  name: string,
}

let rowStateSchemaWithAnnotations =
  rowStateSchema->S.Metadata.set(
    ~id=Reventless.StateAnnotations.stateAnnotationsId,
    {
      ids: ["productId"],
      compositeIds: [],
      subIds: [],
      compositeSubIds: [],
      indexes: [],
      hidden: [],
      summary: [],
      drillTargets: [],
      drillTargetKeys: [],
      collapsed: [],
      scan: ["status"],
      scanSort: ["name"],
      status: None,
      visibility: None,
    },
  )

// ─────────────────────────────────────────────────────────────
// Helpers — invoke a registered resolver with synthetic args/ctx
// ─────────────────────────────────────────────────────────────

// Inject a synthetic authenticated identity so the resolver's spec-level
// authorization check (AllowAuthenticated, see Resolvers.make below) lets
// these list-resolver mechanics tests through.
let emptyCtx: JSON.t = JSON.Encode.object(Dict.fromArray([
  ("request", JSON.Encode.object(Dict.fromArray([
    ("headers", JSON.Encode.object(Dict.make())),
  ]))),
  ("identity", ({...Reventless.Identity.anonymous, userId: "test-user", username: "test-user", groups: ["User"]}: Reventless.Identity.t)->Obj.magic),
]))

let argsOf = (entries: array<(string, JSON.t)>): JSON.t =>
  JSON.Encode.object(Dict.fromArray(entries))

let strJson = JSON.Encode.string
let numJson = (n: int) => JSON.Encode.float(Int.toFloat(n))

let getField = (json: JSON.t, key: string): option<JSON.t> =>
  json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))

let getString = (json: JSON.t, key: string): option<string> =>
  json->getField(key)->Option.flatMap(JSON.Decode.string)

let getEdges = (response: JSON.t): array<JSON.t> =>
  response
  ->getField("edges")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])

let edgeCursor = (edge: JSON.t): string => edge->getString("cursor")->Option.getOr("")

let edgeNodeField = (edge: JSON.t, field: string): string =>
  edge
  ->getField("node")
  ->Option.flatMap(n => n->getString(field))
  ->Option.getOr("")

let pageInfo = (response: JSON.t): JSON.t =>
  response->getField("pageInfo")->Option.getOr(JSON.Encode.null)

let pageInfoBool = (response: JSON.t, key: string): bool =>
  response
  ->pageInfo
  ->getField(key)
  ->Option.flatMap(JSON.Decode.bool)
  ->Option.getOr(false)

let pageInfoString = (response: JSON.t, key: string): option<string> =>
  response->pageInfo->getString(key)

// ─────────────────────────────────────────────────────────────
// Per-test fixture — fresh Bus + storage + registry + resolver
// ─────────────────────────────────────────────────────────────

let buildFixture = async (~name: string) => {
  module Bus = LocalBus.Make()
  module Storage = QueryDbStorage_InMemory.Make(Bus)
  module Resolvers = QueryDbResolvers_GraphQL.Make(Bus)

  module Spec = {
    module Id = Reventless.Id.StringPure
    let name = name
    let moduleUrl: string = %raw(`import.meta.url`)
    @schema
    type state = rowState
    let config = Reventless.ReadModel.config()
    let subIdConfig = None
    let authorization: Reventless.Authorization.permission = AllowAuthenticated
    let visibility: Reventless.Visibility.t = Public
  }

  module QDbResolversAdapter = ReventlessCore.QueryDb_Adapter.NoResolvers(Storage)
  module Maker = ReventlessCore.QueryDb_Builder.Make(Spec, Storage, QDbResolversAdapter)

  let listFieldName = name ++ "s"

  // Populate registries so the resolver can derive server capability and
  // resolve query field names.
  ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry->Dict.set(
    name,
    {
      singleFieldName: name,
      listFieldName,
      returnTypeName: name,
      pluralTypeName: "[" ++ name ++ "]",
      includeIdParam: true,
      connectionSpec: true,
    },
  )
  ReventlessCore.Plugin_Helpers.stateSchemaRegistry->Dict.set(
    name,
    rowStateSchemaWithAnnotations->S.castToUnknown,
  )

  let queryDb = Maker.make(~api=(), ~apiRole=())
  let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve

  // Register the resolver into DomainGraphQL_Server (the default target).
  let _: ReventlessCore.QueryDb_Adapter.resolvers = Resolvers.make(
    ~name,
    ~api=(),
    ~apiRole=(),
    ~dataSourceName=""->Pulumi.Output.make,
    ~indexes=[],
    ~subIdField=None,
    ~idResolverConfigs=[],
    ~idsResolverConfigs=[],
    ~authorization=Reventless.Authorization.AllowAuthenticated,
    ~opts=({}: Pulumi.CustomResourceOptions.t),
  )

  let resolver = switch DomainGraphQL_Server.getQueryResolver(listFieldName) {
  | Some(r) => r
  | None => JsError.throwWithMessage("resolver not registered: " ++ listFieldName)
  }

  // Seed a five-row fixture. Names are chosen so id-ascending order and
  // name-ascending order differ — useful for orderBy tests.
  let rows = [
    ("p-1", "active", "Charlie"),
    ("p-2", "active", "Alpha"),
    ("p-3", "inactive", "Echo"),
    ("p-4", "active", "Bravo"),
    ("p-5", "inactive", "Delta"),
  ]
  for i in 0 to rows->Array.length - 1 {
    let (pid, status, n) = rows->Array.getUnsafe(i)
    let _ = await ops.save(pid, ({productId: pid, status, name: n}: rowState), Init, None)
  }

  (resolver, listFieldName)
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("QueryDb list resolver — keyset pagination", () => {
  beforeEach(() => {
    DomainGraphQL_Server.reset()
  })

  testPromise("first: 2 over a 5-row fixture returns 2 edges and hasNextPage = true", async () => {
    let (resolver, _) = await buildFixture(~name="PageA")
    let response =
      await resolver(JSON.Encode.null, argsOf([("first", numJson(2))]), emptyCtx)
    let edges = getEdges(response)
    expect(edges->Array.length)->toBe(2)
    expect(pageInfoBool(response, "hasNextPage"))->toBe(true)
    expect(pageInfoBool(response, "hasPreviousPage"))->toBe(false)
    // Default sort is id-ascending, so we expect p-1 then p-2.
    expect(edgeNodeField(edges->Array.getUnsafe(0), "productId"))->toBe("p-1")
    expect(edgeNodeField(edges->Array.getUnsafe(1), "productId"))->toBe("p-2")
  })

  testPromise("after: <endCursor> walks forward without overlap", async () => {
    let (resolver, _) = await buildFixture(~name="PageB")
    let page1 =
      await resolver(JSON.Encode.null, argsOf([("first", numJson(2))]), emptyCtx)
    let endCursor1 = pageInfoString(page1, "endCursor")->Option.getOr("")

    let page2 =
      await resolver(
        JSON.Encode.null,
        argsOf([("first", numJson(2)), ("after", strJson(endCursor1))]),
        emptyCtx,
      )
    let edges2 = getEdges(page2)
    expect(edges2->Array.length)->toBe(2)
    expect(edgeNodeField(edges2->Array.getUnsafe(0), "productId"))->toBe("p-3")
    expect(edgeNodeField(edges2->Array.getUnsafe(1), "productId"))->toBe("p-4")
    expect(pageInfoBool(page2, "hasNextPage"))->toBe(true)

    let endCursor2 = pageInfoString(page2, "endCursor")->Option.getOr("")
    let page3 =
      await resolver(
        JSON.Encode.null,
        argsOf([("first", numJson(2)), ("after", strJson(endCursor2))]),
        emptyCtx,
      )
    let edges3 = getEdges(page3)
    expect(edges3->Array.length)->toBe(1)
    expect(edgeNodeField(edges3->Array.getUnsafe(0), "productId"))->toBe("p-5")
    expect(pageInfoBool(page3, "hasNextPage"))->toBe(false)
  })

  testPromise("last + before walks backward and flips hasPreviousPage", async () => {
    let (resolver, _) = await buildFixture(~name="PageC")
    // Walk to page 3 first to grab a startCursor we can walk back from.
    let page1 =
      await resolver(JSON.Encode.null, argsOf([("first", numJson(2))]), emptyCtx)
    let endCursor1 = pageInfoString(page1, "endCursor")->Option.getOr("")
    let page2 =
      await resolver(
        JSON.Encode.null,
        argsOf([("first", numJson(2)), ("after", strJson(endCursor1))]),
        emptyCtx,
      )
    let endCursor2 = pageInfoString(page2, "endCursor")->Option.getOr("")
    let page3 =
      await resolver(
        JSON.Encode.null,
        argsOf([("first", numJson(2)), ("after", strJson(endCursor2))]),
        emptyCtx,
      )
    let startCursor3 = pageInfoString(page3, "startCursor")->Option.getOr("")

    // last: 2 + before: <startCursor3> should return p-3, p-4 in forward order.
    let backPage =
      await resolver(
        JSON.Encode.null,
        argsOf([("last", numJson(2)), ("before", strJson(startCursor3))]),
        emptyCtx,
      )
    let backEdges = getEdges(backPage)
    expect(backEdges->Array.length)->toBe(2)
    expect(edgeNodeField(backEdges->Array.getUnsafe(0), "productId"))->toBe("p-3")
    expect(edgeNodeField(backEdges->Array.getUnsafe(1), "productId"))->toBe("p-4")
    expect(pageInfoBool(backPage, "hasPreviousPage"))->toBe(true)
    expect(pageInfoBool(backPage, "hasNextPage"))->toBe(false)

    // Walk one more step back — should land on p-1, p-2 with hasPreviousPage = false.
    let backStart = pageInfoString(backPage, "startCursor")->Option.getOr("")
    let firstPage =
      await resolver(
        JSON.Encode.null,
        argsOf([("last", numJson(2)), ("before", strJson(backStart))]),
        emptyCtx,
      )
    let firstEdges = getEdges(firstPage)
    expect(firstEdges->Array.length)->toBe(2)
    expect(edgeNodeField(firstEdges->Array.getUnsafe(0), "productId"))->toBe("p-1")
    expect(edgeNodeField(firstEdges->Array.getUnsafe(1), "productId"))->toBe("p-2")
    expect(pageInfoBool(firstPage, "hasPreviousPage"))->toBe(false)
  })

  testPromise("filter.<field>Eq + first / after paginates only the narrowed subset", async () => {
    let (resolver, _) = await buildFixture(~name="PageD")
    let activeFilter = JSON.Encode.object(Dict.fromArray([("statusEq", strJson("active"))]))
    let page1 =
      await resolver(
        JSON.Encode.null,
        argsOf([("filter", activeFilter), ("first", numJson(2))]),
        emptyCtx,
      )
    let edges1 = getEdges(page1)
    expect(edges1->Array.length)->toBe(2)
    // active rows: p-1, p-2, p-4 (id-ascending). First page should be p-1, p-2.
    expect(edgeNodeField(edges1->Array.getUnsafe(0), "productId"))->toBe("p-1")
    expect(edgeNodeField(edges1->Array.getUnsafe(1), "productId"))->toBe("p-2")
    expect(pageInfoBool(page1, "hasNextPage"))->toBe(true)

    let endCursor1 = pageInfoString(page1, "endCursor")->Option.getOr("")
    let page2 =
      await resolver(
        JSON.Encode.null,
        argsOf([
          ("filter", activeFilter),
          ("first", numJson(2)),
          ("after", strJson(endCursor1)),
        ]),
        emptyCtx,
      )
    let edges2 = getEdges(page2)
    expect(edges2->Array.length)->toBe(1)
    expect(edgeNodeField(edges2->Array.getUnsafe(0), "productId"))->toBe("p-4")
    expect(pageInfoBool(page2, "hasNextPage"))->toBe(false)
  })

  testPromise("orderBy DESC + first / after paginates the reverse-sorted view", async () => {
    let (resolver, _) = await buildFixture(~name="PageE")
    // orderBy field: name, direction: DESC. Names sorted DESC:
    //   Echo (p-3), Delta (p-5), Charlie (p-1), Bravo (p-4), Alpha (p-2).
    let orderBy = JSON.Encode.object(Dict.fromArray([
      ("field", strJson("name")),
      ("direction", strJson("DESC")),
    ]))
    let page1 =
      await resolver(
        JSON.Encode.null,
        argsOf([("orderBy", orderBy), ("first", numJson(2))]),
        emptyCtx,
      )
    let edges1 = getEdges(page1)
    expect(edges1->Array.length)->toBe(2)
    expect(edgeNodeField(edges1->Array.getUnsafe(0), "name"))->toBe("Echo")
    expect(edgeNodeField(edges1->Array.getUnsafe(1), "name"))->toBe("Delta")
    expect(pageInfoBool(page1, "hasNextPage"))->toBe(true)

    let endCursor1 = pageInfoString(page1, "endCursor")->Option.getOr("")
    let page2 =
      await resolver(
        JSON.Encode.null,
        argsOf([
          ("orderBy", orderBy),
          ("first", numJson(2)),
          ("after", strJson(endCursor1)),
        ]),
        emptyCtx,
      )
    let edges2 = getEdges(page2)
    expect(edges2->Array.length)->toBe(2)
    expect(edgeNodeField(edges2->Array.getUnsafe(0), "name"))->toBe("Charlie")
    expect(edgeNodeField(edges2->Array.getUnsafe(1), "name"))->toBe("Bravo")
  })

  testPromise("bare request (no first / after) returns a single bounded page", async () => {
    let (resolver, _) = await buildFixture(~name="PageF")
    let response = await resolver(JSON.Encode.null, argsOf([]), emptyCtx)
    let edges = getEdges(response)
    // Default page size is 50; fixture has 5 rows so we expect all 5 in one page.
    expect(edges->Array.length)->toBe(5)
    expect(pageInfoBool(response, "hasNextPage"))->toBe(false)
    expect(pageInfoBool(response, "hasPreviousPage"))->toBe(false)
  })
})

// End-to-end under SQLite: the storage registers the list push-down, so the
// resolver takes the pushed path (json_extract + ORDER BY … LIMIT) rather than
// the JS fallback. Same fixture, same expectations → proves the resolver wiring
// (capability derivation + args → push-down) yields identical output. Unit-level
// SQL≡spec parity across the full arg matrix lives in QueryDbListPushdownParityTest.
describe("QueryDb list resolver — SQLite push-down path", () => {
  beforeEach(() => {
    DomainGraphQL_Server.reset()
  })

  let withSqlite = async fn => {
    let db = SqliteDriver.openDb(~path=":memory:")
    BackendState.setSqlite(~db, ~path=":memory:")
    let r = await fn()
    BackendState.setMemory()
    db->SqliteDriver.close
    r
  }

  testPromise("first:2 then after walks forward without overlap", () =>
    withSqlite(async () => {
      let (resolver, _) = await buildFixture(~name="SqlPageA")
      let page1 = await resolver(JSON.Encode.null, argsOf([("first", numJson(2))]), emptyCtx)
      let edges1 = getEdges(page1)
      expect(edges1->Array.length)->toBe(2)
      expect(edgeNodeField(edges1->Array.getUnsafe(0), "productId"))->toBe("p-1")
      expect(edgeNodeField(edges1->Array.getUnsafe(1), "productId"))->toBe("p-2")
      expect(pageInfoBool(page1, "hasNextPage"))->toBe(true)

      let endCursor1 = pageInfoString(page1, "endCursor")->Option.getOr("")
      let page2 =
        await resolver(
          JSON.Encode.null,
          argsOf([("first", numJson(2)), ("after", strJson(endCursor1))]),
          emptyCtx,
        )
      let edges2 = getEdges(page2)
      expect(edges2->Array.length)->toBe(2)
      expect(edgeNodeField(edges2->Array.getUnsafe(0), "productId"))->toBe("p-3")
      expect(edgeNodeField(edges2->Array.getUnsafe(1), "productId"))->toBe("p-4")
    })
  )

  testPromise("orderBy name DESC + first:2 returns the reverse-sorted head", () =>
    withSqlite(async () => {
      let (resolver, _) = await buildFixture(~name="SqlPageB")
      let orderBy = JSON.Encode.object(
        Dict.fromArray([("field", strJson("name")), ("direction", strJson("DESC"))]),
      )
      let page1 =
        await resolver(
          JSON.Encode.null,
          argsOf([("orderBy", orderBy), ("first", numJson(2))]),
          emptyCtx,
        )
      let edges1 = getEdges(page1)
      expect(edges1->Array.length)->toBe(2)
      expect(edgeNodeField(edges1->Array.getUnsafe(0), "name"))->toBe("Echo")
      expect(edgeNodeField(edges1->Array.getUnsafe(1), "name"))->toBe("Delta")
    })
  )

  testPromise("statusEq active narrows the pushed page", () =>
    withSqlite(async () => {
      let (resolver, _) = await buildFixture(~name="SqlPageC")
      let activeFilter = JSON.Encode.object(Dict.fromArray([("statusEq", strJson("active"))]))
      let response =
        await resolver(JSON.Encode.null, argsOf([("filter", activeFilter)]), emptyCtx)
      let edges = getEdges(response)
      expect(edges->Array.length)->toBe(3)
      expect(edgeNodeField(edges->Array.getUnsafe(0), "productId"))->toBe("p-1")
      expect(edgeNodeField(edges->Array.getUnsafe(2), "productId"))->toBe("p-4")
    })
  )
})
