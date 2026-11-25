// Paging a list ordered by a field with repeated and missing values, page by page in both
// directions: every row once, in one order, on the shared spec and on SQLite. Rows without the
// value come last either way; ties go by id. The Postgres twin is QueryEnginePostgresListPageTest.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let capability = ReventlessCore.GraphQL_FragmentGenerator.deriveServerCapability(
  ~ordering=AnyField,
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

// (id, rank, qty, done): rank repeats and is missing on two rows; qty has 10 above 9 as a number;
// done is a boolean.
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

type store = dict<JSON.t> => JSON.t

// The spec over every row, as the in-memory store answers.
let spec: store = argsDict =>
  ReventlessCore.QueryDbListQuery.run(
    ~items=rows->Array.map(item),
    ~argsDict,
    ~capability,
    ~labelField="id",
  )

// SQLite's push-down, falling back to the spec where it declines, as its resolver does.
let sqlite = async (): store => {
  module TestBus = LocalBus.Make()
  module DbProvider = {
    let db = SqliteDriver.openDb(~path=":memory:")
  }
  module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)
  let s = Storage.make(~name="items", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
  let ops = await s.operations->TestRunner.resolve
  for i in 0 to rows->Array.length - 1 {
    let row = rows->Array.getUnsafe(i)
    let (id, _, _, _) = row
    let _ = await ops.save(id, item(row), ReventlessCore.QueryDb.Any, None)
  }
  let listPage = TestBus.getQueryDbListPage("items")->Option.getOrThrow
  let fullScan = TestBus.getQueryDbScan("items")->Option.getOrThrow
  argsDict =>
    switch listPage(~argsDict, ~capability, ~labelField="id") {
    | Some(conn) => conn
    | None =>
      ReventlessCore.QueryDbListQuery.run(
        ~items=fullScan(),
        ~argsDict,
        ~capability,
        ~labelField="id",
      )
    }
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

// Every page from the first forward, two rows a page.
let forward = (store: store, ~field, ~dir) => {
  let seen = []
  let rec walk = (after, guard) => {
    let args = [("orderBy", orderBy(field, dir)), ("first", JSON.Encode.int(2))]
    let args =
      after->Option.mapOr(args, c => args->Array.concat([("after", JSON.Encode.string(c))]))
    let conn = store(Dict.fromArray(args))
    seen->Array.pushMany(ids(conn))
    if flag(conn, "hasNextPage") && guard > 0 {
      walk(cursor(conn, "endCursor"), guard - 1)
    }
  }
  walk(None, 10)
  seen
}

// Every page from the last backward, two rows a page, read back in list order.
let backward = (store: store, ~field, ~dir) => {
  let pages = []
  let rec walk = (before, guard) => {
    let args = [("orderBy", orderBy(field, dir)), ("last", JSON.Encode.int(2))]
    let args =
      before->Option.mapOr(args, c => args->Array.concat([("before", JSON.Encode.string(c))]))
    let conn = store(Dict.fromArray(args))
    pages->Array.unshift(ids(conn))
    if flag(conn, "hasPreviousPage") && guard > 0 {
      walk(cursor(conn, "startCursor"), guard - 1)
    }
  }
  walk(None, 10)
  pages->Array.flat
}

let cases = [
  ("rank", "ASC", ["p-3", "p-6", "p-1", "p-4", "p-7", "p-2", "p-5"]),
  ("rank", "DESC", ["p-7", "p-1", "p-4", "p-3", "p-6", "p-2", "p-5"]),
  ("qty", "ASC", ["p-5", "p-2", "p-4", "p-1", "p-6", "p-3", "p-7"]),
  ("qty", "DESC", ["p-1", "p-6", "p-2", "p-4", "p-5", "p-3", "p-7"]),
  ("done", "ASC", ["p-3", "p-5", "p-1", "p-4", "p-7", "p-2", "p-6"]),
  ("done", "DESC", ["p-1", "p-4", "p-7", "p-3", "p-5", "p-2", "p-6"]),
]

describe("paging a list ordered by any field", () => {
  cases->Array.forEach(((field, dir, expected)) => {
    testSync(
      `the spec, ${field} ${dir}, forward and backward`,
      () =>
        expect((forward(spec, ~field, ~dir), backward(spec, ~field, ~dir)))->toEqual((
          expected,
          expected,
        )),
    )
    testPromise(
      `SQLite, ${field} ${dir}, forward and backward`,
      async () => {
        let store = await sqlite()
        expect((forward(store, ~field, ~dir), backward(store, ~field, ~dir)))->toEqual((
          expected,
          expected,
        ))
      },
    )
  })
})
