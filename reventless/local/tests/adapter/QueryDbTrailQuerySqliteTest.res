// The SQLite list push-down reads a trail's derived dates under the attributes
// they are stored as: "in Placed since before a bound, longest there first",
// across two pages, the same rows in the same order as the in-memory spec.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability = {
  filterFields: [
    {name: "lifecycle", gqlType: "String", range: false},
    {name: "enteredPlaced", gqlType: "String", range: true},
    {name: "visitsPlaced", gqlType: "Int", range: true},
    {name: "enteredShipped", gqlType: "String", range: true},
    {name: "enteredCurrent", gqlType: "String", range: true},
  ],
  sortFields: ["enteredPlaced", "visitsPlaced", "enteredShipped", "enteredCurrent"],
  stored: Dict.fromArray([
    ("enteredPlaced", "_entered_Placed"),
    ("visitsPlaced", "_visits_Placed"),
    ("enteredShipped", "_entered_Shipped"),
    ("enteredCurrent", "_entered_current"),
  ]),
  numeric: ["visitsPlaced"],
  reached: ["enteredPlaced", "visitsPlaced", "enteredShipped"],
}

let row = (id, lifecycle, entries: array<(string, string)>) => {
  let d = Dict.fromArray([
    ("id", JSON.Encode.string(id)),
    ("lifecycle", JSON.Encode.string(lifecycle)),
    (
      "trail",
      entries
      ->Array.map(((state, at)) =>
        Dict.fromArray([
          ("state", JSON.Encode.string(state)),
          ("at", JSON.Encode.string(at)),
        ])->JSON.Encode.object
      )
      ->JSON.Encode.array,
    ),
  ])
  Reventless.Lifecycle.Trail.writeDerived(d, ~field="trail")
  (id, d->JSON.Encode.object)
}

let rows = [
  row("o-1", "Placed", [("Placed", "2026-03-01T09:00:00Z")]),
  row("o-2", "Placed", [("Placed", "2026-03-03T09:00:00Z")]),
  row("o-3", "Shipped", [("Placed", "2026-02-26T09:00:00Z"), ("Shipped", "2026-03-02T09:00:00Z")]),
  row("o-4", "Placed", [("Placed", "2026-03-02T09:00:00Z")]),
  row(
    "o-5",
    "Placed",
    [
      ("Placed", "2026-02-28T09:00:00Z"),
      ("Cancelled", "2026-03-01T09:00:00Z"),
      ("Placed", "2026-03-04T09:00:00Z"),
    ],
  ),
  row("o-6", "Placed", [("Placed", "2026-02-27T09:00:00Z")]),
]

// A row in Placed after `n` visits, Cancelled between them.
let visitsRow = (id, n) => {
  let pad = i => i < 10 ? "0" ++ Int.toString(i) : Int.toString(i)
  row(
    id,
    "Placed",
    Array.fromInitializer(~length=2 * n - 1, i => (
      mod(i, 2) == 0 ? "Placed" : "Cancelled",
      `2026-01-01T${pad(i)}:00:00Z`,
    )),
  )
}

let visitsRows = [visitsRow("v-2", 2), visitsRow("v-9", 9), visitsRow("v-10", 10)]

let ordered = (~filter=[], ~first=?, ~after=?, field) =>
  Dict.fromArray(
    [
      ("filter", Dict.fromArray(filter)->JSON.Encode.object),
      (
        "orderBy",
        Dict.fromArray([
          ("field", JSON.Encode.string(field)),
          ("direction", JSON.Encode.string("ASC")),
        ])->JSON.Encode.object,
      ),
    ]
    ->Array.concat(
      switch first {
      | Some(n) => [("first", JSON.Encode.int(n))]
      | None => []
      },
    )
    ->Array.concat(
      switch after {
      | Some(c) => [("after", JSON.Encode.string(c))]
      | None => []
      },
    ),
  )

let request = (~after=?) =>
  Dict.fromArray(
    [
      (
        "filter",
        Dict.fromArray([
          ("lifecycleEq", JSON.Encode.string("Placed")),
          ("enteredCurrentTo", JSON.Encode.string("2026-03-03T12:00:00Z")),
        ])->JSON.Encode.object,
      ),
      (
        "orderBy",
        Dict.fromArray([
          ("field", JSON.Encode.string("enteredCurrent")),
          ("direction", JSON.Encode.string("ASC")),
        ])->JSON.Encode.object,
      ),
      ("first", JSON.Encode.int(2)),
    ]->Array.concat(
      switch after {
      | Some(c) => [("after", JSON.Encode.string(c))]
      | None => []
      },
    ),
  )

let field = (j, k) => j->JSON.Decode.object->Option.flatMap(d => d->Dict.get(k))
let ids = conn =>
  conn
  ->field("edges")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(e =>
    e->field("node")->Option.flatMap(n => n->field("id"))->Option.flatMap(JSON.Decode.string)
  )
let pageInfo = (conn, k) =>
  conn->field("pageInfo")->Option.flatMap(p => p->field(k))->Option.getOr(JSON.Encode.null)

let spec = argsDict =>
  ReventlessCore.QueryDbListQuery.run(
    ~items=rows->Array.map(((_, item)) => item),
    ~argsDict,
    ~capability,
    ~labelField="id",
  )

testPromise("SQLite: a state and how long rows have been in it, across two pages", async () => {
  module TestBus = LocalBus.Make()
  module DbProvider = {
    let db = SqliteDriver.openDb(~path=":memory:")
  }
  module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)
  let s = Storage.make(~name="orders", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
  let ops = await s.operations->TestRunner.resolve
  for i in 0 to rows->Array.length - 1 {
    let (id, item) = rows->Array.getUnsafe(i)
    let _ = await ops.save(id, item, ReventlessCore.QueryDb.Any, None)
  }
  let listPage = TestBus.getQueryDbListPage("orders")->Option.getOrThrow
  let page = argsDict => listPage(~argsDict, ~capability, ~labelField="id")->Option.getOrThrow

  let first = page(request())
  expect((ids(first), pageInfo(first, "hasNextPage")))->toEqual((
    ["o-6", "o-1"],
    JSON.Encode.bool(true),
  ))
  expect(first)->toEqual(spec(request()))
  let after = pageInfo(first, "endCursor")->JSON.Decode.string->Option.getOrThrow
  let second = page(request(~after))
  expect((ids(second), pageInfo(second, "hasNextPage")))->toEqual((
    ["o-4", "o-2"],
    JSON.Encode.bool(false),
  ))
  expect(second)->toEqual(spec(request(~after)))
})

testPromise(
  "SQLite: visits compare as numbers, and a state's date lists only rows that entered it",
  async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = SqliteDriver.openDb(~path=":memory:")
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)
    let s = Storage.make(~name="orders", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve
    let all = rows->Array.concat(visitsRows)
    for i in 0 to all->Array.length - 1 {
      let (id, item) = all->Array.getUnsafe(i)
      let _ = await ops.save(id, item, ReventlessCore.QueryDb.Any, None)
    }
    let listPage = TestBus.getQueryDbListPage("orders")->Option.getOrThrow
    let page = argsDict => listPage(~argsDict, ~capability, ~labelField="id")->Option.getOrThrow
    let specAll = argsDict =>
      ReventlessCore.QueryDbListQuery.run(
        ~items=all->Array.map(((_, item)) => item),
        ~argsDict,
        ~capability,
        ~labelField="id",
      )

    let visits = ordered(~filter=[("visitsPlacedFrom", JSON.Encode.int(3))], "visitsPlaced")
    expect(ids(page(visits)))->toEqual(["v-9", "v-10"])
    expect(page(visits))->toEqual(specAll(visits))

    // Two to a page across the numeric order, the cursor compared as a number.
    let byVisits = ordered(~first=2, "visitsPlaced")
    let first = page(byVisits)
    expect(first)->toEqual(specAll(byVisits))
    let after = pageInfo(first, "endCursor")->JSON.Decode.string->Option.getOrThrow
    let next = ordered(~first=2, ~after, "visitsPlaced")
    expect(page(next))->toEqual(specAll(next))

    let shipped = ordered("enteredShipped")
    expect(ids(page(shipped)))->toEqual(["o-3"])
    expect(page(shipped))->toEqual(specAll(shipped))
  },
)
