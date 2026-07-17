// Parity harness for the Postgres connection-list push-down (B3.2a-1).
//
// `QueryEnginePostgres.listPage` builds `item->>'field'` predicates + keyset
// WHERE + ORDER BY … LIMIT to serve a page without materialising the whole read
// model. Its result MUST equal `QueryDbListQuery.run` (the shared spec in
// reventless-core that the in-memory backend, the SQLite push-down, and the
// resolver fallback all use) for every shape it claims to handle. This is the
// Postgres twin of reventless-local's `QueryDbListPushdownParityTest` — same
// capability, same rows, same (data, args) matrix — so all three backends are
// held to one spec.
//
// Skipped unless PG_URL is set (like PostgresIntegrationTest), so the default
// `pnpm test` stays dependency-free. Run with e.g.:
//   PG_URL=postgres://postgres:postgres@localhost:5432/postgres pnpm test

open JestGlobals
open ReventlessCore

@val external processEnv: dict<string> = "process.env"

let capability: GraphQL_FragmentGenerator.serverCapability = {
  filterFields: [
    {name: "status", gqlType: "String", range: false},
    {name: "qty", gqlType: "Int", range: true},
  ],
  sortFields: ["name", "qty", "status"],
}

let mk = (id, status, name, qty) => {
  let o = Dict.make()
  o->Dict.set("id", JSON.Encode.string(id))
  o->Dict.set("status", JSON.Encode.string(status))
  o->Dict.set("name", JSON.Encode.string(name))
  o->Dict.set("qty", JSON.Encode.int(qty))
  JSON.Encode.object(o)
}

// Names differ from id-order; status has duplicates (tiebreak); qty exercises the
// numeric-field-as-string comparison the push-down must match.
let rows = [
  ("p-1", "active", "Charlie", 3),
  ("p-2", "active", "Alpha", 1),
  ("p-3", "inactive", "Echo", 5),
  ("p-4", "active", "Bravo", 2),
  ("p-5", "inactive", "Delta", 4),
]

// The exact items seeded, in memory — the spec runs over these (equivalent to a
// full scan of the table, since every save upserts one of these by id).
let seededItems = rows->Array.map(((id, status, name, qty)) => mk(id, status, name, qty))

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
let cur = QueryDbListQuery.encodeCursor

let expectedFor = argsDict =>
  QueryDbListQuery.run(
    ~items=seededItems,
    ~argsDict,
    ~capability,
    ~labelField="name",
    ~decodeLocalId=_ => None,
  )->norm

switch processEnv->Dict.get("PG_URL") {
| None =>
  testSync("Postgres list push-down parity (skipped — set PG_URL to run)", () =>
    expect(true)->toBe(true)
  )
| Some(url) =>
  let pool = PgDriver.makePool({connectionString: url})
  module Eng = QueryEnginePostgres.Make({
    let pool = pool
  })
  let name = "listparity"

  // Seed via the real storage ops (upsert by id → table converges to the 5 rows).
  beforeAllAsync(async () => {
    let ops = QueryDbStorage_Postgres.makeOperations(~pool, ~name, ~indexes=[], ~subIdField=None)
    for i in 0 to rows->Array.length - 1 {
      let (id, status, nm, qty) = rows->Array.getUnsafe(i)
      let _ = await ops.save(id, mk(id, status, nm, qty), QueryDb.Any, None)
    }
  })
  afterAll(() => {
    let _ = pool->PgDriver.endPool
  })

  // Assert the push-down serves this shape AND matches the spec exactly.
  let checkPushed = async (~label, args) => {
    let argsDict = argsOf(args)
    switch await Eng.listPage(~readModelName=name, ~argsDict, ~capability, ~labelField="name") {
    | Some(actual) => expect(actual->norm)->toEqual(expectedFor(argsDict))
    | None => expect("push-down for " ++ label)->toBe("returned None")
    }
  }

  // Assert the push-down declines this shape (resolver falls back to the spec).
  let checkFallback = async args => {
    let r = await Eng.listPage(~readModelName=name, ~argsDict=argsOf(args), ~capability, ~labelField="name")
    expect(r->Option.isSome)->toBe(false)
  }

  describe("QueryDb list push-down parity (Postgres ≡ QueryDbListQuery spec)", () => {
    testPromise("bare page", () => checkPushed(~label="bare", []))
    testPromise("first:2", () => checkPushed(~label="first", [("first", JSON.Encode.int(2))]))
    testPromise("first:2 + after", () =>
      checkPushed(
        ~label="after",
        [("first", JSON.Encode.int(2)), ("after", JSON.Encode.string(cur("p-2")))],
      )
    )
    testPromise("statusEq active", () =>
      checkPushed(~label="eq", [("filter", filterOf([("statusEq", JSON.Encode.string("active"))]))])
    )
    testPromise("statusEq active + first:2", () =>
      checkPushed(
        ~label="eq+first",
        [
          ("filter", filterOf([("statusEq", JSON.Encode.string("active"))])),
          ("first", JSON.Encode.int(2)),
        ],
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
    // qty is numeric → exercises `item->>'qty'` (text) vs Float.toString string parity.
    testPromise("qty range From/To (numeric-as-string)", () =>
      checkPushed(
        ~label="range",
        [
          (
            "filter",
            filterOf([("qtyFrom", JSON.Encode.string("2")), ("qtyTo", JSON.Encode.string("4"))]),
          ),
        ],
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
      checkFallback([("filter", filterOf([("ids", JSON.Encode.array([JSON.Encode.string("p-1")]))]))])
    )
    testPromise("backward (last/before) → fallback", () =>
      checkFallback([("last", JSON.Encode.int(2)), ("before", JSON.Encode.string(cur("p-4")))])
    )
  })

  // ── indexLookup / byIds push-downs ────────────────────────────────────────
  let idsOf = (items: array<JSON.t>): array<string> =>
    items->Array.filterMap(i => i->str("id"))->Array.toSorted(String.compare)

  describe("QueryEnginePostgres index / batch push-downs", () => {
    testPromise("indexLookup by status = active", async () => {
      let items = await Eng.indexLookup(~readModelName=name, "status", "active")
      expect(items->idsOf)->toEqual(["p-1", "p-2", "p-4"])
    })
    testPromise("indexLookup miss → empty", async () => {
      let items = await Eng.indexLookup(~readModelName=name, "status", "nope")
      expect(items->Array.length)->toBe(0)
    })
    testPromise("byIds returns matches, drops missing", async () => {
      let items = await Eng.byIds(~readModelName=name, ["p-1", "p-3", "absent"])
      expect(items->idsOf)->toEqual(["p-1", "p-3"])
    })
    testPromise("byIds [] → empty (no query)", async () => {
      let items = await Eng.byIds(~readModelName=name, [])
      expect(items->Array.length)->toBe(0)
    })
  })

  // ── itemsPage (sub-id connection) ─────────────────────────────────────────
  // A sub-id read model: partition "order-1" holds 5 lines keyed by `seq`.
  let itemsName = "itemsparity"
  let mkLine = seq => {
    let o = Dict.make()
    o->Dict.set("id", JSON.Encode.string("order-1"))
    o->Dict.set("seq", JSON.Encode.string(seq))
    JSON.Encode.object(o)
  }
  let seqs = ["a", "b", "c", "d", "e"]
  beforeAllAsync(async () => {
    let ops = QueryDbStorage_Postgres.makeOperations(
      ~pool,
      ~name=itemsName,
      ~indexes=[],
      ~subIdField=Some("seq"),
    )
    for i in 0 to seqs->Array.length - 1 {
      let _ = await ops.save("order-1", mkLine(seqs->Array.getUnsafe(i)), QueryDb.Any, None)
    }
  })

  // Extract node `seq` values in edge order.
  let itemSeqs = (conn: JSON.t) =>
    conn
    ->field("edges")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(e => e->field("node")->Option.flatMap(n => n->str("seq")))

  let pageInfoBool = (conn, key) =>
    conn->field("pageInfo")->Option.getOr(JSON.Encode.null)->field(key)->Option.flatMap(JSON.Decode.bool)->Option.getOr(false)

  let itemsPage = args =>
    Eng.itemsPage(~readModelName=itemsName, ~subIdField="seq", ~id="order-1", ~argsDict=argsOf(args))

  describe("QueryEnginePostgres itemsPage (sub-id keyset)", () => {
    testPromise("bare → all lines ASC, no next page", async () => {
      let r = await itemsPage([])
      expect(r->itemSeqs)->toEqual(["a", "b", "c", "d", "e"])
      expect(pageInfoBool(r, "hasNextPage"))->toBe(false)
    })
    testPromise("first:2 → [a,b], hasNextPage", async () => {
      let r = await itemsPage([("first", JSON.Encode.int(2))])
      expect(r->itemSeqs)->toEqual(["a", "b"])
      expect(pageInfoBool(r, "hasNextPage"))->toBe(true)
    })
    testPromise("first:2 after b → [c,d]", async () => {
      let r = await itemsPage([("first", JSON.Encode.int(2)), ("after", JSON.Encode.string(cur("b")))])
      expect(r->itemSeqs)->toEqual(["c", "d"])
    })
    testPromise("order DESC → [e..a]", async () => {
      let r = await itemsPage([("filter", filterOf([("order", JSON.Encode.string("DESC"))]))])
      expect(r->itemSeqs)->toEqual(["e", "d", "c", "b", "a"])
    })
    testPromise("filter eq c → [c]", async () => {
      let r = await itemsPage([("filter", filterOf([("eq", JSON.Encode.string("c"))]))])
      expect(r->itemSeqs)->toEqual(["c"])
    })
    testPromise("filter from b to d → [b,c,d]", async () => {
      let r = await itemsPage([
        ("filter", filterOf([("from", JSON.Encode.string("b")), ("to", JSON.Encode.string("d"))])),
      ])
      expect(r->itemSeqs)->toEqual(["b", "c", "d"])
    })
    testPromise("prefix c → [c]", async () => {
      let r = await itemsPage([("filter", filterOf([("prefix", JSON.Encode.string("c"))]))])
      expect(r->itemSeqs)->toEqual(["c"])
    })
    testPromise("backward last:2 before d → [b,c] (logical ASC)", async () => {
      let r = await itemsPage([("last", JSON.Encode.int(2)), ("before", JSON.Encode.string(cur("d")))])
      expect(r->itemSeqs)->toEqual(["b", "c"])
      expect(pageInfoBool(r, "hasPreviousPage"))->toBe(true)
    })
  })
}
