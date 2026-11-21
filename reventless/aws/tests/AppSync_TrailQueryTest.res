// On DynamoDB the list door answers "in Placed since before a bound, longest
// there first" as a Query on the lifecycle index: the state and the bound are
// its key condition, not a filter over a Scan. A range on a state's entry
// queries that state's index; everything else stays a Scan.

open JestGlobals

module F = AppSync_Resolver_Retrying.Functions

external asString: Pulumi.Input.t<string> => string = "%identity"

type resolver = {request: JSON.t => JSON.t, response: JSON.t => JSON.t}

// The generated module run with AppSync's `util` stood in.
let evalResolver: string => resolver = %raw(`function(code) {
  const util = {
    dynamodb: { toDynamoDB: v => ({ S: String(v) }) },
    base64Encode: s => Buffer.from(String(s), 'utf8').toString('base64'),
    base64Decode: s => Buffer.from(String(s), 'base64').toString('utf8'),
    error: (m, t) => { throw Object.assign(new Error(m), { errorType: t }) },
  };
  const body = code
    .replace(/^import\s+.*?from\s+['"][^'"]+['"];?\s*/gm, '')
    .replace(/export\s+function\s+(\w+)/g, '__exports.$1 = function $1');
  const __exports = {};
  new Function('util', '__exports', body)(util, __exports);
  return __exports;
}`)

let indexes = Reventless.ReadModel.trailIndexes(
  TrailQueryFixture.annotated(~trailIndex=["Placed"], ~owner=false),
)

let capability = ReventlessCore.GraphQL_FragmentGenerator.deriveServerCapability(
  ~entityName="Orders",
  TrailQueryFixture.annotated(~trailIndex=["Placed"], ~owner=false),
)

let door = (~ownerIndex=false) =>
  F.listAllItemsConnection(
    ~labelField="orderId",
    ~filterFields=capability.filterFields->Array.map(f => f.name),
    ~rangeFields=capability.filterFields->Array.filterMap(f => f.range ? Some(f.name) : None),
    ~sortFields=capability.sortFields,
    ~ownerField=?ownerIndex ? Some("customerId") : None,
    ~elevatedGroups=["Admin"],
    ~ownerIndex=?ownerIndex ? Some("_owner") : None,
    ~ownerIndexSortField=?ownerIndex ? Some("id") : None,
    ~storedNames=?capability.stored,
    ~keyedReads=QueryDbResolvers_Trail.keyedReads(indexes),
  )
  ->asString
  ->evalResolver

let ctx = (~args: array<(string, JSON.t)>, ~groups=["Admin"], ~result=?) =>
  Dict.fromArray([
    ("args", args->Dict.fromArray->JSON.Encode.object),
    (
      "identity",
      Dict.fromArray([
        ("sub", JSON.Encode.string("u-1")),
        (
          "claims",
          Dict.fromArray([
            ("cognito:groups", groups->Array.map(JSON.Encode.string)->JSON.Encode.array),
          ])->JSON.Encode.object,
        ),
      ])->JSON.Encode.object,
    ),
    ("result", result->Option.getOr(JSON.Encode.null)),
  ])->JSON.Encode.object

let obj = entries => entries->Dict.fromArray->JSON.Encode.object
let str = JSON.Encode.string

let inPlacedLongestFirst = (~after=?) =>
  [
    (
      "filter",
      obj([("lifecycleEq", str("Placed")), ("enteredCurrentTo", str("2026-03-03T12:00:00Z"))]),
    ),
    ("orderBy", obj([("field", str("enteredCurrent")), ("direction", str("ASC"))])),
    ("first", JSON.Encode.int(2)),
  ]->Array.concat(
    switch after {
    | Some(c) => [("after", str(c))]
    | None => []
    },
  )

let get = (j: JSON.t, path: array<string>) =>
  path->Array.reduce(Some(j), (acc, k) =>
    acc->Option.flatMap(JSON.Decode.object)->Option.flatMap(d => d->Dict.get(k))
  )

describe("a trail's indexes on DynamoDB", () => {
  testSync("derives the lifecycle index and one per named state", () =>
    expect(indexes->Array.map(ic => (ic.index, ic.idField, ic.subIdField, ic.derived)))->toEqual([
      ("_lifecycle", Some("lifecycle"), Some("_entered_current"), Some(true)),
      ("_entered_Placed", Some("_trail"), Some("_entered_Placed"), Some(true)),
    ])
  )

  testSync("a state and how long rows have been in it is a Query on the lifecycle index", () => {
    let req = door().request(ctx(~args=inPlacedLongestFirst()))
    expect((
      req->get(["operation"]),
      req->get(["index"]),
      req->get(["query", "expression"]),
      req->get(["query", "expressionNames"]),
      req->get(["query", "expressionValues"]),
      req->get(["scanIndexForward"]),
      req->get(["filter"]),
    ))->toEqual((
      Some(str("Query")),
      Some(str("_lifecycle")),
      Some(str("#kh = :kh AND #ks <= :kt")),
      Some(obj([("#kh", str("lifecycle")), ("#ks", str("_entered_current"))])),
      Some(
        obj([
          (":kh", obj([("S", str("Placed"))])),
          (":kt", obj([("S", str("2026-03-03T12:00:00Z"))])),
        ]),
      ),
      Some(JSON.Encode.bool(true)),
      None,
    ))
  })

  testSync("the index's order is the page's order, and its cursors say which read", () => {
    let rows = [
      obj([("id", str("o-6")), ("_entered_current", str("2026-02-27T09:00:00Z"))]),
      obj([("id", str("o-1")), ("_entered_current", str("2026-03-01T09:00:00Z"))]),
      obj([("id", str("o-4")), ("_entered_current", str("2026-03-02T09:00:00Z"))]),
    ]
    let page = door().response(
      ctx(
        ~args=inPlacedLongestFirst(),
        ~result=obj([("items", JSON.Encode.array(rows)), ("nextToken", JSON.Encode.null)]),
      ),
    )
    let ids =
      page
      ->get(["edges"])
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(e => e->get(["node", "id"]))
    expect((ids, page->get(["pageInfo", "hasNextPage"])))->toEqual((
      [str("o-6"), str("o-1")],
      Some(JSON.Encode.bool(true)),
    ))
    // The second page resumes the same Query; a cursor from it on a Scan is refused.
    let after =
      page->get(["pageInfo", "endCursor"])->Option.flatMap(JSON.Decode.string)->Option.getOrThrow
    let next = door().request(ctx(~args=inPlacedLongestFirst(~after)))
    expect(next->get(["index"]))->toEqual(Some(str("_lifecycle")))
    let refused = try {
      let _ = door().request(ctx(~args=[("after", str(after))]))
      false
    } catch {
    | _ => true
    }
    expect(refused)->toBe(true)
  })

  testSync("descending order reads the index backward", () => {
    let args = [
      ("filter", obj([("lifecycleEq", str("Placed"))])),
      ("orderBy", obj([("field", str("enteredCurrent")), ("direction", str("DESC"))])),
    ]
    let req = door().request(ctx(~args))
    expect((req->get(["query", "expression"]), req->get(["scanIndexForward"])))->toEqual((
      Some(str("#kh = :kh")),
      Some(JSON.Encode.bool(false)),
    ))
  })

  testSync("a range on a state's entry queries that state's index", () => {
    let args = [("filter", obj([("enteredPlacedFrom", str("2026-03-01"))]))]
    let req = door().request(ctx(~args))
    expect((
      req->get(["index"]),
      req->get(["query", "expression"]),
      req->get(["query", "expressionNames"]),
    ))->toEqual((
      Some(str("_entered_Placed")),
      Some(str("#kh = :kh AND #ks >= :kf")),
      Some(obj([("#kh", str("_trail")), ("#ks", str("_entered_Placed"))])),
    ))
  })

  testSync("another state's range rides the lifecycle Query as a filter", () => {
    let args = [
      (
        "filter",
        obj([("lifecycleEq", str("Cancelled")), ("enteredPlacedFrom", str("2026-03-01"))]),
      ),
    ]
    let req = door().request(ctx(~args))
    expect((
      req->get(["index"]),
      req->get(["filter", "expression"]),
      req->get(["filter", "expressionNames"]),
    ))->toEqual((
      Some(str("_lifecycle")),
      Some(str("#enteredPlaced >= :enteredPlacedFrom")),
      Some(obj([("#enteredPlaced", str("_entered_Placed"))])),
    ))
  })

  testSync("a request naming no trail key stays a Scan", () =>
    expect(door().request(ctx(~args=[]))->get(["operation"]))->toEqual(Some(str("Scan")))
  )

  testSync("a caller the owner index scopes keeps that Query", () => {
    let customer = door(~ownerIndex=true).request(ctx(~args=inPlacedLongestFirst(), ~groups=[]))
    let staff = door(~ownerIndex=true).request(ctx(~args=inPlacedLongestFirst()))
    expect((customer->get(["index"]), staff->get(["index"])))->toEqual((
      Some(str("_owner")),
      Some(str("_lifecycle")),
    ))
  })
})

describe("the table's index count", () => {
  let ic = (index, ~derived=false): Reventless.ReadModel.indexConfig => {
    index,
    type_: "S",
    projectionType: ALL,
    derived,
  }

  testSync("refuses more than DynamoDB allows, naming where each came from", () => {
    let indexes =
      Array.fromInitializer(~length=18, i => ic("by" ++ Int.toString(i)))
      ->Array.concat([ic("_owner", ~derived=true)])
      ->Array.concat(
        Reventless.ReadModel.trailIndexes(
          TrailQueryFixture.annotated(~trailIndex=["Placed", "Shipped"], ~owner=false),
        ),
      )
    let problem = QueryDbStorage_DynamoDb.indexCountProblem(~name="Orders", indexes)
    expect(
      problem->Option.map(
        p => (
          p->String.includes("asks for 22 global secondary indexes"),
          p->String.includes("by0 (@index)"),
          p->String.includes("_owner (@owner)"),
          p->String.includes("_lifecycle (@trail)"),
          p->String.includes("_entered_Shipped (@trail)"),
        ),
      ),
    )->toEqual(Some((true, true, true, true, true)))
  })

  testSync("lets twenty through", () =>
    expect(
      QueryDbStorage_DynamoDb.indexCountProblem(
        ~name="Orders",
        Array.fromInitializer(~length=20, i => ic("by" ++ Int.toString(i))),
      ),
    )->toEqual(None)
  )
})
