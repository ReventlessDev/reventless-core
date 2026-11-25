// The Postgres twin of reventless-local's QueryDbListPagingParityTest: a list ordered by a field
// with repeated and missing values, paged both ways, gives every row once in the same order.
// Skipped unless PG_URL is set, like the other Postgres suites.

open JestGlobals
open ReventlessCore

@val external processEnv: dict<string> = "process.env"

let capability = GraphQL_FragmentGenerator.deriveServerCapability(
  ~ordering=QueryDbStorage_Postgres_Ops.ordering,
  ~entityName="Items",
  S.schema(s =>
    {
      "id": s.matches(S.string),
      "rank": s.matches(S.option(S.string)),
      "qty": s.matches(S.option(S.int)),
      "done": s.matches(S.option(S.bool)),
    }
  )->S.castToUnknown,
)

let rows = [
  ("p-1", Some("b"), Some(10), Some(true)),
  ("p-2", None, Some(9), None),
  ("p-3", Some("a"), None, Some(false)),
  ("p-4", Some("b"), Some(9), Some(true)),
  ("p-5", None, Some(1), Some(false)),
  ("p-6", Some("a"), Some(10), None),
  ("p-7", Some("c"), None, Some(true)),
]

let item = ((id, rank, qty, done)) => {
  let o = Dict.make()
  o->Dict.set("id", JSON.Encode.string(id))
  rank->Option.forEach(r => o->Dict.set("rank", JSON.Encode.string(r)))
  qty->Option.forEach(q => o->Dict.set("qty", JSON.Encode.int(q)))
  done->Option.forEach(d => o->Dict.set("done", JSON.Encode.bool(d)))
  JSON.Encode.object(o)
}

let field = (j, k) => j->JSON.Decode.object->Option.flatMap(d => d->Dict.get(k))
let ids = conn =>
  conn
  ->field("edges")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(e => e->field("node")->Option.flatMap(n => n->field("id")))
  ->Array.filterMap(JSON.Decode.string)
let pageInfo = (conn, k) => conn->field("pageInfo")->Option.flatMap(pi => pi->field(k))
let flag = (conn, k) => conn->pageInfo(k)->Option.flatMap(JSON.Decode.bool)->Option.getOr(false)
let cursor = (conn, k) => conn->pageInfo(k)->Option.flatMap(JSON.Decode.string)
let orderBy = (f, dir) =>
  JSON.Encode.object(
    Dict.fromArray([("field", JSON.Encode.string(f)), ("direction", JSON.Encode.string(dir))]),
  )

let cases = [
  ("rank", "ASC", ["p-3", "p-6", "p-1", "p-4", "p-7", "p-2", "p-5"]),
  ("rank", "DESC", ["p-7", "p-1", "p-4", "p-3", "p-6", "p-2", "p-5"]),
  ("qty", "ASC", ["p-5", "p-2", "p-4", "p-1", "p-6", "p-3", "p-7"]),
  ("qty", "DESC", ["p-1", "p-6", "p-2", "p-4", "p-5", "p-3", "p-7"]),
  ("done", "ASC", ["p-3", "p-5", "p-1", "p-4", "p-7", "p-2", "p-6"]),
  ("done", "DESC", ["p-1", "p-4", "p-7", "p-3", "p-5", "p-2", "p-6"]),
]

switch processEnv->Dict.get("PG_URL") {
| None =>
  testSync("Postgres paging parity (skipped — set PG_URL to run)", () => expect(true)->toBe(true))
| Some(url) =>
  let pool = PgDriver.makePool({connectionString: url})
  module Eng = QueryEnginePostgres.Make({
    let pool = pool
  })
  let name = "pagingparity"

  beforeAllAsync(async () => {
    let ops = QueryDbStorage_Postgres.makeOperations(~pool, ~name, ~indexes=[], ~subIdField=None)
    for i in 0 to rows->Array.length - 1 {
      let row = rows->Array.getUnsafe(i)
      let (id, _, _, _) = row
      let _ = await ops.save(id, item(row), QueryDb.Any, None)
    }
  })
  afterAll(() => {
    let _ = pool->PgDriver.endPool
  })

  // The push-down, falling back to the spec over every row where it declines.
  let page = async argsDict =>
    switch await Eng.listPage(~readModelName=name, ~argsDict, ~capability, ~labelField="id") {
    | Some(conn) => conn
    | None =>
      QueryDbListQuery.run(~items=rows->Array.map(item), ~argsDict, ~capability, ~labelField="id")
    }

  let forward = async (~field, ~dir) => {
    let seen = []
    let after = ref(None)
    let more = ref(true)
    let guard = ref(10)
    while more.contents && guard.contents > 0 {
      let args = [("orderBy", orderBy(field, dir)), ("first", JSON.Encode.int(2))]
      let args =
        after.contents->Option.mapOr(args, c =>
          args->Array.concat([("after", JSON.Encode.string(c))])
        )
      let conn = await page(Dict.fromArray(args))
      seen->Array.pushMany(ids(conn))
      more := flag(conn, "hasNextPage")
      after := cursor(conn, "endCursor")
      guard := guard.contents - 1
    }
    seen
  }

  let backward = async (~field, ~dir) => {
    let pages = []
    let before = ref(None)
    let more = ref(true)
    let guard = ref(10)
    while more.contents && guard.contents > 0 {
      let args = [("orderBy", orderBy(field, dir)), ("last", JSON.Encode.int(2))]
      let args =
        before.contents->Option.mapOr(args, c =>
          args->Array.concat([("before", JSON.Encode.string(c))])
        )
      let conn = await page(Dict.fromArray(args))
      pages->Array.unshift(ids(conn))
      more := flag(conn, "hasPreviousPage")
      before := cursor(conn, "startCursor")
      guard := guard.contents - 1
    }
    pages->Array.flat
  }

  describe("paging a list ordered by any field on Postgres", () =>
    cases->Array.forEach(((field, dir, expected)) =>
      testPromise(
        `${field} ${dir}, forward and backward`,
        async () => {
          let f = await forward(~field, ~dir)
          let b = await backward(~field, ~dir)
          expect((f, b))->toEqual((expected, expected))
        },
      )
    )
  )
}
