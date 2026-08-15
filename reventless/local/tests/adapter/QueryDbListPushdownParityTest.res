// Parity harness for the SQLite connection-list push-down (plan B4).
//
// The SQLite `registerQueryDbListPage` builds json_extract predicates + ORDER BY
// … LIMIT to serve a page without materialising the whole read model. Its result
// MUST equal `QueryDbListQuery.run` (the shared spec the in-memory backend and
// the resolver fallback use) for every shape it claims to handle. This runs a
// matrix of (data, args) through BOTH the push-down and the spec-over-full-scan
// and asserts identical edges + pageInfo — and asserts the push-down returns None
// (→ fallback) for the shapes it deliberately doesn't reproduce in SQL.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability = {
  filterFields: [
    {name: "status", gqlType: "String", range: false},
    {name: "qty", gqlType: "Int", range: true},
  ],
  sortFields: ["name", "qty", "status"],
}

let mk = (id, status, name, qty, owner, archived) => {
  let o = Dict.make()
  o->Dict.set("id", JSON.Encode.string(id))
  o->Dict.set("status", JSON.Encode.string(status))
  o->Dict.set("name", JSON.Encode.string(name))
  o->Dict.set("qty", JSON.Encode.int(qty))
  o->Dict.set("owner", JSON.Encode.string(owner))
  // `archived` is absent on p-5, not false. A row written before the annotation
  // existed has no such attribute, and "absent means not retired" is the rule
  // both the spec and every push-down have to land on — get it wrong and the
  // view empties the day someone adds `@retired`.
  switch archived {
  | Some(b) => o->Dict.set("archived", JSON.Encode.bool(b))
  | None => ()
  }
  JSON.Encode.object(o)
}

// Names differ from id-order; status has duplicates (tiebreak); qty exercises the
// numeric-field-as-string comparison the push-down must match. `owner` is split
// so that no owner holds all the rows and none holds none — a scoped read that
// returned everything and one that returned nothing would both stand out.
//
// Note `owner` is deliberately absent from `capability` below: owner scoping has
// to work on a field the client-visible filter surface does not admit, which is
// the normal case and the reason the predicate travels separately.
let rows = [
  ("p-1", "active", "Charlie", 3, "u-a", Some(false)),
  ("p-2", "active", "Alpha", 1, "u-b", Some(true)),
  ("p-3", "inactive", "Echo", 5, "u-a", Some(false)),
  ("p-4", "active", "Bravo", 2, "u-c", Some(true)),
  ("p-5", "inactive", "Delta", 4, "u-a", None),
]

type setup = {
  listPage: (
    ~argsDict: dict<JSON.t>,
    ~capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability,
    ~labelField: string,
    ~ownerScope: (string, string)=?,
    ~retiredScope: string=?,
  ) => option<JSON.t>,
  fullScan: unit => array<JSON.t>,
}

let build = async (): setup => {
  module TestBus = LocalBus.Make()
  module DbProvider = {
    let db = SqliteDriver.openDb(~path=":memory:")
  }
  module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)
  let s = Storage.make(~name="items", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
  let ops = await s.operations->TestRunner.resolve
  for i in 0 to rows->Array.length - 1 {
    let (id, status, name, qty, owner, archived) = rows->Array.getUnsafe(i)
    let _ = await ops.save(
      id,
      mk(id, status, name, qty, owner, archived),
      ReventlessCore.QueryDb.Any,
      None,
    )
  }
  {
    listPage: TestBus.getQueryDbListPage("items")->Option.getOrThrow,
    fullScan: TestBus.getQueryDbScan("items")->Option.getOrThrow,
  }
}

// ── normalise a connection to a comparable value ────────────────────────────
type normEdge = {id: string, cursor: string}
type normConn = {
  edges: array<normEdge>,
  hasNext: bool,
  hasPrev: bool,
  startCursor: option<string>,
  endCursor: option<string>,
}

let field = (j, k) => j->JSON.Decode.object->Option.flatMap(d => d->Dict.get(k))
let str = (j, k) => j->field(k)->Option.flatMap(JSON.Decode.string)

let norm = (conn: JSON.t): normConn => {
  let edges =
    conn
    ->field("edges")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.map(e => {
      id: e->field("node")->Option.flatMap(n => n->str("id"))->Option.getOr(""),
      cursor: e->str("cursor")->Option.getOr(""),
    })
  let pi = conn->field("pageInfo")->Option.getOr(JSON.Encode.null)
  {
    edges,
    hasNext: pi->field("hasNextPage")->Option.flatMap(JSON.Decode.bool)->Option.getOr(false),
    hasPrev: pi->field("hasPreviousPage")->Option.flatMap(JSON.Decode.bool)->Option.getOr(false),
    startCursor: pi->str("startCursor"),
    endCursor: pi->str("endCursor"),
  }
}

let argsOf = (entries: array<(string, JSON.t)>): dict<JSON.t> => Dict.fromArray(entries)
let filterOf = (entries: array<(string, JSON.t)>): JSON.t =>
  JSON.Encode.object(Dict.fromArray(entries))
let orderBy = (f, dir) =>
  JSON.Encode.object(
    Dict.fromArray([("field", JSON.Encode.string(f)), ("direction", JSON.Encode.string(dir))]),
  )
let cur = ReventlessCore.QueryDbListQuery.encodeCursor

// Assert the push-down serves this shape AND matches the spec exactly.
let checkPushed = async (~label, ~ownerScope=?, ~retiredScope=?, args) => {
  let s = await build()
  let argsDict = argsOf(args)
  let expected =
    ReventlessCore.QueryDbListQuery.run(
      ~items=s.fullScan(),
      ~argsDict,
      ~capability,
      ~labelField="name",
      ~decodeLocalId=_ => None,
      ~ownerScope?,
      ~retiredScope?,
    )->norm
  switch s.listPage(~argsDict, ~capability, ~labelField="name", ~ownerScope?, ~retiredScope?) {
  | Some(actual) => expect(actual->norm)->toEqual(expected)
  | None => expect("push-down for " ++ label)->toBe("returned None")
  }
}

// Assert the push-down declines this shape (resolver falls back to the spec).
let checkFallback = async args => {
  let s = await build()
  expect(s.listPage(~argsDict=argsOf(args), ~capability, ~labelField="name")->Option.isSome)->toBe(false)
}

// The ids a retirement-narrowed read returns, from the push-down.
let liveIds = async args => {
  let s = await build()
  switch s.listPage(~argsDict=argsOf(args), ~capability, ~labelField="name", ~retiredScope="archived") {
  | Some(conn) => (conn->norm).edges->Array.map(e => e.id)
  | None => []
  }
}

// The ids a scoped read actually returns, from the push-down.
let scopedIds = async (~owner, args) => {
  let s = await build()
  switch s.listPage(
    ~argsDict=argsOf(args),
    ~capability,
    ~labelField="name",
    ~ownerScope=("owner", owner),
  ) {
  | Some(conn) => (conn->norm).edges->Array.map(e => e.id)
  | None => []
  }
}

describe("QueryDb list push-down parity (SQLite ≡ QueryDbListQuery spec)", () => {
  testPromise("bare page", () => checkPushed(~label="bare", []))
  testPromise("first:2", () => checkPushed(~label="first", [("first", JSON.Encode.int(2))]))
  testPromise("first:2 + after", () =>
    checkPushed(~label="after", [("first", JSON.Encode.int(2)), ("after", JSON.Encode.string(cur("p-2")))])
  )
  testPromise("statusEq active", () =>
    checkPushed(~label="eq", [("filter", filterOf([("statusEq", JSON.Encode.string("active"))]))])
  )
  testPromise("statusEq active + first:2", () =>
    checkPushed(
      ~label="eq+first",
      [("filter", filterOf([("statusEq", JSON.Encode.string("active"))])), ("first", JSON.Encode.int(2))],
    )
  )
  testPromise("orderBy name ASC", () =>
    checkPushed(~label="order-asc", [("orderBy", orderBy("name", "ASC"))])
  )
  testPromise("orderBy name DESC", () =>
    checkPushed(~label="order-desc", [("orderBy", orderBy("name", "DESC"))])
  )
  testPromise("orderBy name DESC + first:2 + after", () =>
    checkPushed(
      ~label="order-desc-after",
      [
        ("orderBy", orderBy("name", "DESC")),
        ("first", JSON.Encode.int(2)),
        ("after", JSON.Encode.string(cur("Delta"))),
      ],
    )
  )
  // status has duplicate values → exercises the id tiebreak in ORDER BY.
  testPromise("orderBy status ASC (tiebreak by id)", () =>
    checkPushed(~label="order-tiebreak", [("orderBy", orderBy("status", "ASC"))])
  )
  // qty is numeric → exercises CAST(... AS TEXT) vs Float.toString string parity.
  testPromise("qty range From/To (numeric-as-string)", () =>
    checkPushed(
      ~label="range",
      [("filter", filterOf([("qtyFrom", JSON.Encode.string("2")), ("qtyTo", JSON.Encode.string("4"))]))],
    )
  )
  testPromise("orderBy qty ASC (numeric-as-string sort)", () =>
    checkPushed(~label="order-qty", [("orderBy", orderBy("qty", "ASC"))])
  )

  // Shapes the push-down declines → resolver uses the JS fallback.
  testPromise("search → fallback", () =>
    checkFallback([("filter", filterOf([("search", JSON.Encode.string("alp"))]))])
  )
  testPromise("searchPrefix → fallback", () =>
    checkFallback([("filter", filterOf([("searchPrefix", JSON.Encode.string("A"))]))])
  )
  testPromise("ids → fallback", () =>
    checkFallback([
      ("filter", filterOf([("ids", JSON.Encode.array([JSON.Encode.string("p-1")]))])),
    ])
  )
  testPromise("backward (last/before) → fallback", () =>
    checkFallback([("last", JSON.Encode.int(2)), ("before", JSON.Encode.string(cur("p-4")))])
  )

  // ── Retirement narrowing ──────────────────────────────────────────────────
  // Same parity argument as owner scoping below: the push-down is the path a
  // deployment takes and the spec is the path the tests reach, so a predicate
  // implemented in one of them is a hole every fallback-based test calls green.
  describe("retirement narrowing", () => {
    testPromise("bare page, narrowed", () =>
      checkPushed(~label="retired-bare", ~retiredScope="archived", [])
    )
    testPromise("narrowed + orderBy", () =>
      checkPushed(
        ~label="retired-order",
        ~retiredScope="archived",
        [("orderBy", orderBy("name", "DESC"))],
      )
    )
    testPromise("narrowed + the caller's own filter", () =>
      checkPushed(
        ~label="retired-filter",
        ~retiredScope="archived",
        [("filter", filterOf([("statusEq", JSON.Encode.string("active"))]))],
      )
    )
    testPromise("narrowed + owner-scoped together", () =>
      checkPushed(
        ~label="retired-owner",
        ~ownerScope=("owner", "u-a"),
        ~retiredScope="archived",
        [],
      )
    )

    // The rows, not just the parity: p-2 and p-4 are archived, p-5 carries no
    // flag at all. Parity alone would pass if BOTH implementations were wrong
    // the same way.
    testPromise("drops the archived rows and keeps the one with no flag", async () => {
      let ids = await liveIds([])
      expect(ids)->toEqual(["p-1", "p-3", "p-5"])
    })

    // The reason the predicate is pushed into the SQL rather than applied to the
    // page: `first: 2` must yield two LIVE rows, not two rows of which some were
    // filtered away afterwards.
    testPromise("a page of first:2 is two live rows, not two rows minus the archived", async () => {
      let ids = await liveIds([("first", JSON.Encode.int(2))])
      expect(ids)->toEqual(["p-1", "p-3"])
    })
  })

  // ── Owner scoping ─────────────────────────────────────────────────────────
  // Parity matters more here than anywhere else in this file. The push-down is
  // the path a deployment actually takes; the spec is the path the tests most
  // easily reach. A predicate implemented in only one of them is a hole that
  // every fallback-based test would still call green.
  describe("owner scoping", () => {
    testPromise("bare page, scoped", () =>
      checkPushed(~label="owner-bare", ~ownerScope=("owner", "u-a"), [])
    )
    testPromise("scoped + orderBy", () =>
      checkPushed(
        ~label="owner-order",
        ~ownerScope=("owner", "u-a"),
        [("orderBy", orderBy("name", "DESC"))],
      )
    )
    // The client's own filter must survive alongside the scope, not be replaced
    // by it — a scoped read is still a filtered read.
    testPromise("scoped + client filter compose", () =>
      checkPushed(
        ~label="owner-and-filter",
        ~ownerScope=("owner", "u-a"),
        [("filter", filterOf([("statusEq", JSON.Encode.string("inactive"))]))],
      )
    )

    testPromise("a scoped read returns exactly that owner's rows", async () =>
      expect(await scopedIds(~owner="u-a", []))->toEqual(["p-1", "p-3", "p-5"])
    )

    // The control: a different owner sees a different, also non-empty, set. An
    // implementation that scoped to nothing would pass an "is not everything"
    // assertion and fail this one.
    testPromise("a second owner sees their own rows, not the first's", async () =>
      expect(await scopedIds(~owner="u-b", []))->toEqual(["p-2"])
    )

    // The case that catches a predicate applied AFTER the page rather than
    // inside the SQL: u-a owns 3 of 5 rows, so a LIMIT 2 taken before scoping
    // would return p-1 alone (p-2 belongs to u-b and would be dropped), not the
    // two rows actually asked for.
    testPromise("paging a scoped read fills each page from owned rows only", async () =>
      expect(await scopedIds(~owner="u-a", [("first", JSON.Encode.int(2))]))->toEqual([
        "p-1",
        "p-3",
      ])
    )

    testPromise("the second page continues the scoped sequence", async () =>
      expect(
        await scopedIds(
          ~owner="u-a",
          [("first", JSON.Encode.int(2)), ("after", JSON.Encode.string(cur("p-3")))],
        ),
      )->toEqual(["p-5"])
    )
  })
})
