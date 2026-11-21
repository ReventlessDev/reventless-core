// A trail that opts states in with `@trail({index: […]})` adds those states'
// derived dates to the filter and sort surface, the lifecycle field to the
// filter, and `enteredCurrent` for any opted-in trail. The in-memory spec reads
// each name off the attribute it is stored under.

open JestGlobals

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type order = {
  orderId: string,
  lifecycle: lifecycle,
  trail: Reventless.Lifecycle.Trail.t<lifecycle>,
}

let annotated = (~trailIndex: option<array<string>>) =>
  orderSchema
  ->S.Metadata.set(
    ~id=Reventless.StateAnnotations.stateAnnotationsId,
    {
      Reventless.StateAnnotations.ids: ["orderId"],
      compositeIds: [],
      subIds: [],
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
      lifecycle: Some("lifecycle"),
      groupBy: None,
      visibility: None,
      live: None,
      retired: None,
      ?trailIndex,
    },
  )
  ->S.castToUnknown

let capabilityOf = (~trailIndex) =>
  GraphQL_FragmentGenerator.deriveServerCapability(~entityName="Orders", annotated(~trailIndex))

// A row as the save stores it: the trail, and the attributes derived from it.
let row = (id, lifecycle, entries: array<(string, string)>) => {
  let d = Dict.fromArray([
    ("id", JSON.Encode.string(id)),
    ("orderId", JSON.Encode.string(id)),
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
  d->JSON.Encode.object
}

let rows = [
  row("o-1", "Placed", [("Placed", "2026-03-01T09:00:00Z")]),
  row("o-2", "Placed", [("Placed", "2026-03-03T09:00:00Z")]),
  row("o-3", "Shipped", [("Placed", "2026-02-26T09:00:00Z"), ("Shipped", "2026-03-02T09:00:00Z")]),
  row("o-4", "Placed", [("Placed", "2026-03-02T09:00:00Z")]),
  // Reopened: in Placed since its second visit, which the bound excludes.
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

// "In Placed since before Mar 3 noon, longest there first", two to a page.
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

describe("a trail's opted-in states on the filter and sort surface", () => {
  testSync("adds each state's dates, the current state's, and the lifecycle filter", () => {
    let cap = capabilityOf(~trailIndex=Some(["Placed", "Shipped"]))
    let filters = cap.filterFields->Array.map(f => (f.name, f.gqlType, f.range))
    expect(filters)->toEqual([
      ("orderId", "ID", false),
      ("lifecycle", "String", false),
      ("enteredPlaced", "String", true),
      ("enteredPlacedFirst", "String", true),
      ("visitsPlaced", "Int", true),
      ("enteredShipped", "String", true),
      ("enteredShippedFirst", "String", true),
      ("visitsShipped", "Int", true),
      ("enteredCurrent", "String", true),
    ])
    expect(cap.sortFields)->toEqual([
      "orderId",
      "enteredPlaced",
      "enteredPlacedFirst",
      "visitsPlaced",
      "enteredShipped",
      "enteredShippedFirst",
      "visitsShipped",
      "enteredCurrent",
    ])
    let stored = name => GraphQL_FragmentGenerator.storedName(cap, name)
    expect([
      stored("enteredPlaced"),
      stored("enteredPlacedFirst"),
      stored("visitsPlaced"),
      stored("enteredCurrent"),
      stored("lifecycle"),
    ])->toEqual([
      "_entered_Placed",
      "_entered_Placed_first",
      "_visits_Placed",
      "_entered_current",
      "lifecycle",
    ])
  })

  testSync("the lifecycle index alone adds the current state's date and the lifecycle", () => {
    let cap = capabilityOf(~trailIndex=Some([]))
    expect(cap.filterFields->Array.map(f => f.name))->toEqual([
      "orderId",
      "lifecycle",
      "enteredCurrent",
    ])
    expect(cap.sortFields)->toEqual(["orderId", "enteredCurrent"])
  })

  testSync("a trail that opts nothing in adds nothing", () => {
    let cap = capabilityOf(~trailIndex=None)
    expect((cap.filterFields->Array.map(f => f.name), cap.sortFields, cap.stored))->toEqual((
      ["orderId"],
      ["orderId"],
      None,
    ))
  })

  testSync("the filter input and the order field carry the names", () => {
    let cap = capabilityOf(~trailIndex=Some(["Placed"]))
    let filter = GraphQL_FragmentGenerator.deriveConnectionFilterType(
      ~filterTypeName="OrderFilter",
      ~capability=cap,
    )
    expect(filter->String.includes("  lifecycleEq: String\n"))->toBe(true)
    expect(
      filter->String.includes("  enteredCurrentFrom: String\n  enteredCurrentTo: String"),
    )->toBe(true)
    expect(filter->String.includes("  visitsPlacedFrom: Int\n"))->toBe(true)
    let orderBy =
      GraphQL_FragmentGenerator.deriveConnectionOrderByType(
        ~singularTypeName="Order",
        ~capability=cap,
      )->Array.join("\n")
    expect(orderBy->String.includes("  enteredCurrent\n"))->toBe(true)
    expect(orderBy->String.includes("_entered_"))->toBe(false)
  })

  testSync("in-memory: a state and how long rows have been in it, across two pages", () => {
    let cap = capabilityOf(~trailIndex=Some(["Placed"]))
    let run = argsDict =>
      QueryDbListQuery.run(~items=rows, ~argsDict, ~capability=cap, ~labelField="orderId")
    let first = run(request())
    expect((ids(first), pageInfo(first, "hasNextPage")))->toEqual((
      ["o-6", "o-1"],
      JSON.Encode.bool(true),
    ))
    let after = pageInfo(first, "endCursor")->JSON.Decode.string->Option.getOrThrow
    let second = run(request(~after))
    expect((ids(second), pageInfo(second, "hasNextPage")))->toEqual((
      ["o-4", "o-2"],
      JSON.Encode.bool(false),
    ))
  })

  testSync("in-memory: a reopened row counts both visits", () => {
    let cap = capabilityOf(~trailIndex=Some(["Placed"]))
    let conn = QueryDbListQuery.run(
      ~items=rows,
      ~argsDict=Dict.fromArray([
        ("filter", Dict.fromArray([("visitsPlacedFrom", JSON.Encode.int(2))])->JSON.Encode.object),
      ]),
      ~capability=cap,
      ~labelField="orderId",
    )
    expect(ids(conn))->toEqual(["o-5"])
  })
})
