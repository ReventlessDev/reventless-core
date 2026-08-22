// Behavioural tests for the in-memory connection list resolver
// (QueryDbResolvers_GraphQL). Phase 1.5 — keyset pagination on top of the
// Phase 1 filter / sort wiring.

@@warning("-44")

open JestGlobals

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Test state spec — five-row fixture exercising filter / sort / paginate
// ─────────────────────────────────────────────────────────────

// A union field on an *indexed* view: the by-index door is one of two in the
// mechanism plan's table that no fixture carried a union through. Optional so the
// existing five-row literals below are untouched.
@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({lat: float, lng: float})

let geolocationSchema = Reventless.TaggedUnion.named(~name="Geolocation", geolocationSchema)

@schema
type rowState = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  status: string,
  name: string,
  geolocation?: geolocation,
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
      semantic: [],
      metric: [],
      lifecycle: None,
      groupBy: None,
      visibility: None,
      live: None,
      retired: None,
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

let edges2Find = (edges: array<JSON.t>, pid: string): JSON.t =>
  edges->Array.find(e => e->getField("node")->Option.flatMap(n => n->getString("productId")) === Some(pid))
  ->Option.getOr(JSON.Encode.null)

let edgeNodeJson = (edge: JSON.t, field: string): option<JSON.t> =>
  edge->getField("node")->Option.flatMap(n => n->getField(field))

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

let buildFixture = async (~name: string, ~indexes: array<Reventless.ReadModel.indexConfig>=[]) => {
  module Bus = LocalBus.Make()
  module Storage = LocalQueryDbStorage.Make(Bus)
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
    ~indexes,
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
    // p-1 carries the union; the rest leave it absent, which also proves an
    // absent optional union is not stamped into something.
    let state: rowState =
      pid === "p-1"
        ? {productId: pid, status, name: n, geolocation: Located({lat: 48.2082, lng: 16.3738})}
        : {productId: pid, status, name: n}
    let _ = await ops.save(pid, state, Init, None)
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

// The by-index door answers a Relay connection, keyed on the index's column.
// Both halves used to be wrong here and in the opposite direction on AppSync:
// this backend promised `[String]` and returned whole rows, so every call failed
// to serialise before a caller could reach the rows at all.
describe("QueryDb by-index resolver", () => {
  let statusIndex: array<Reventless.ReadModel.indexConfig> = [
    {index: "status", type_: "S", projectionType: ALL},
  ]

  let indexResolver = async (~name) => {
    let _ = await buildFixture(~name, ~indexes=statusIndex)
    switch DomainGraphQL_Server.getQueryResolver(name ++ "ByStatus") {
    | Some(r) => r
    | None => JsError.throwWithMessage("index resolver not registered: " ++ name ++ "ByStatus")
    }
  }

  beforeEach(() => {
    DomainGraphQL_Server.reset()
  })

  testPromise("answers the rows carrying the index value, as edges", async () => {
    let resolver = await indexResolver(~name="IdxA")
    let response = await resolver(JSON.Encode.null, argsOf([("status", strJson("active"))]), emptyCtx)
    let edges = getEdges(response)
    expect(edges->Array.length)->toBe(3)
    expect(edgeNodeField(edges->Array.getUnsafe(0), "productId"))->toBe("p-1")
  })

  testPromise("pages forward on first/after like every other connection", async () => {
    let resolver = await indexResolver(~name="IdxB")
    let page1 =
      await resolver(
        JSON.Encode.null,
        argsOf([("status", strJson("active")), ("first", numJson(2))]),
        emptyCtx,
      )
    expect(getEdges(page1)->Array.length)->toBe(2)
    expect(pageInfoBool(page1, "hasNextPage"))->toBe(true)

    let page2 =
      await resolver(
        JSON.Encode.null,
        argsOf([
          ("status", strJson("active")),
          ("first", numJson(2)),
          ("after", strJson(pageInfoString(page1, "endCursor")->Option.getOr(""))),
        ]),
        emptyCtx,
      )
    let edges2 = getEdges(page2)
    expect(edges2->Array.length)->toBe(1)
    expect(edgeNodeField(edges2->Array.getUnsafe(0), "productId"))->toBe("p-4")
    expect(pageInfoBool(page2, "hasNextPage"))->toBe(false)
  })

  // The gap this fixture exists to close: a union field reaching a caller through
  // the by-index door, carrying the `__typename` the write-time stamp put on it.
  // A member without one resolves to null and takes its non-nullable parent with
  // it, so the whole row would vanish rather than error.
  testPromise("carries a union field's member type through", async () => {
    let resolver = await indexResolver(~name="IdxU")
    let response = await resolver(JSON.Encode.null, argsOf([("status", strJson("active"))]), emptyCtx)
    let edges = getEdges(response)
    let seeded =
      edges->Array.find(e => edgeNodeField(e, "productId") === "p-1")->Option.getOr(JSON.Encode.null)
    let geo = edgeNodeJson(seeded, "geolocation")->Option.flatMap(JSON.Decode.object)
    expect(geo->Option.flatMap(o => o->Dict.get("__typename"))->Option.flatMap(JSON.Decode.string))
    ->toEqual(Some("GeolocationLocated"))
    expect(
      geo
      ->Option.flatMap(o => o->Dict.get("lat"))
      ->Option.flatMap(JSON.Decode.float),
    )->toEqual(Some(48.2082))
  })

  // An absent optional union is left absent rather than stamped into an arm.
  testPromise("leaves an absent union absent", async () => {
    let resolver = await indexResolver(~name="IdxV")
    let response = await resolver(JSON.Encode.null, argsOf([("status", strJson("active"))]), emptyCtx)
    let other = edges2Find(getEdges(response), "p-2")
    // Assert the row is real first, so an absent field cannot pass as an absent row.
    expect(edgeNodeField(other, "name"))->toBe("Alpha")
    expect(edgeNodeJson(other, "geolocation")->Option.isNone)->toBe(true)
  })

  // Refused rather than ignored, and refused here because AppSync cannot do it:
  // a door that paged backward on one backend and quietly returned the forward
  // page on the other is the divergence this whole field was rebuilt to remove.
  testPromise("refuses backward paging instead of answering forward", async () => {
    let resolver = await indexResolver(~name="IdxC")
    let outcome = try {
      let _ =
        await resolver(
          JSON.Encode.null,
          argsOf([("status", strJson("active")), ("last", numJson(2))]),
          emptyCtx,
        )
      Ok()
    } catch {
    | e => Error(e->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(""))
    }
    switch outcome {
    | Ok() => expect("no error")->toBe("a BAD_USER_INPUT refusal")
    | Error(message) =>
      expect(message->String.includes("Backward pagination (last/before) is not supported"))->toBe(true)
    }
  })
})

// ─────────────────────────────────────────────────────────────
// Sub-id view — the `{name}Items` door
// ─────────────────────────────────────────────────────────────

// The door only exists when a view declares a sub-id, and no fixture declared one
// alongside a union field, so it was the last door in the mechanism plan's table
// carrying a union nowhere.

@schema
type lineState = {
  orderId: @s.matches(Reventless.DcbTag.string) string,
  lineNo: string,
  label: string,
  geolocation?: geolocation,
}

let lineStateSchemaWithAnnotations =
  lineStateSchema->S.Metadata.set(
    ~id=Reventless.StateAnnotations.stateAnnotationsId,
    {
      ids: ["orderId"],
      compositeIds: [],
      subIds: ["lineNo"],
      compositeSubIds: [],
      indexes: [],
      hidden: [],
      summary: [],
      drillTargets: [],
      drillTargetKeys: [],
      collapsed: [],
      scan: [],
      scanSort: [],
      semantic: [],
      metric: [],
      lifecycle: None,
      groupBy: None,
      visibility: None,
      live: None,
      retired: None,
    },
  )

let buildSubIdFixture = async (~name: string) => {
  module Bus = LocalBus.Make()
  module Storage = LocalQueryDbStorage.Make(Bus)
  module Resolvers = QueryDbResolvers_GraphQL.Make(Bus)

  module Spec = {
    module Id = Reventless.Id.StringPure
    let name = name
    let moduleUrl: string = %raw(`import.meta.url`)
    @schema
    type state = lineState
    let config = Reventless.ReadModel.config()
    let subIdConfig = Some({
      Reventless.ReadModel.subIdField: "lineNo",
      getSubId: (state: lineState) => state.lineNo,
    })
    let authorization: Reventless.Authorization.permission = AllowAuthenticated
    let visibility: Reventless.Visibility.t = Public
  }

  module QDbResolversAdapter = ReventlessCore.QueryDb_Adapter.NoResolvers(Storage)
  module Maker = ReventlessCore.QueryDb_Builder.Make(Spec, Storage, QDbResolversAdapter)

  ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry->Dict.set(
    name,
    {
      singleFieldName: name,
      listFieldName: name ++ "s",
      returnTypeName: name,
      pluralTypeName: "[" ++ name ++ "]",
      includeIdParam: true,
      connectionSpec: true,
    },
  )
  ReventlessCore.Plugin_Helpers.stateSchemaRegistry->Dict.set(
    name,
    lineStateSchemaWithAnnotations->S.castToUnknown,
  )

  let queryDb = Maker.make(~api=(), ~apiRole=())
  let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve

  let _: ReventlessCore.QueryDb_Adapter.resolvers = Resolvers.make(
    ~name,
    ~api=(),
    ~apiRole=(),
    ~dataSourceName=""->Pulumi.Output.make,
    ~indexes=[],
    ~subIdField=Some("lineNo"),
    ~idResolverConfigs=[],
    ~idsResolverConfigs=[],
    ~authorization=Reventless.Authorization.AllowAuthenticated,
    ~opts=({}: Pulumi.CustomResourceOptions.t),
  )

  // Two lines under one order: the first carries the union, the second leaves the
  // optional field absent.
  let _ = await ops.save(
    "o-1",
    {orderId: "o-1", lineNo: "l-1", label: "First", geolocation: Located({lat: 48.2082, lng: 16.3738})},
    Init,
    None,
  )
  let _ = await ops.save("o-1", {orderId: "o-1", lineNo: "l-2", label: "Second"}, Init, None)

  switch DomainGraphQL_Server.getQueryResolver(name ++ "Items") {
  | Some(r) => r
  | None => JsError.throwWithMessage("items resolver not registered: " ++ name ++ "Items")
  }
}

describe("QueryDb sub-id resolver — the Items door", () => {
  beforeEach(() => {
    DomainGraphQL_Server.reset()
  })

  testPromise("answers the sub-items of one id, as edges", async () => {
    let resolver = await buildSubIdFixture(~name="ItemA")
    let response = await resolver(JSON.Encode.null, argsOf([("id", strJson("o-1"))]), emptyCtx)
    let edges = getEdges(response)
    expect(edges->Array.length)->toBe(2)
    expect(edgeNodeField(edges->Array.getUnsafe(0), "lineNo"))->toBe("l-1")
  })

  // The gap this fixture exists to close, mirroring the by-index case above: a
  // union reaching a caller through the Items door with the member type the
  // write-time stamp put on it. Without it the member resolves to null and takes
  // its non-nullable parent, so the row leaves the connection rather than erroring.
  testPromise("carries a union field's member type through", async () => {
    let resolver = await buildSubIdFixture(~name="ItemB")
    let response = await resolver(JSON.Encode.null, argsOf([("id", strJson("o-1"))]), emptyCtx)
    let first = getEdges(response)->Array.getUnsafe(0)
    let geo = edgeNodeJson(first, "geolocation")->Option.flatMap(JSON.Decode.object)
    expect(geo->Option.flatMap(o => o->Dict.get("__typename"))->Option.flatMap(JSON.Decode.string))
    ->toEqual(Some("GeolocationLocated"))
    expect(geo->Option.flatMap(o => o->Dict.get("lat"))->Option.flatMap(JSON.Decode.float))
    ->toEqual(Some(48.2082))
  })

  testPromise("leaves an absent union absent", async () => {
    let resolver = await buildSubIdFixture(~name="ItemC")
    let response = await resolver(JSON.Encode.null, argsOf([("id", strJson("o-1"))]), emptyCtx)
    let second = getEdges(response)->Array.getUnsafe(1)
    expect(edgeNodeField(second, "label"))->toBe("Second")
    expect(edgeNodeJson(second, "geolocation")->Option.isNone)->toBe(true)
  })
})
