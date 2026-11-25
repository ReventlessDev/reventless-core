// A store that orders by any field sorts every plain field of a read model; one that orders by
// its keys sorts what the annotations name, as before.

open JestGlobals

let spec: Reventless.StateAnnotations.stateAnnotationSpec = {
  ids: ["orderId"],
  compositeIds: [],
  subIds: [],
  compositeSubIds: [],
  indexes: [("placedAt", "byPlaced")],
  hidden: ["secret"],
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
}

let schema =
  S.schema(s =>
    {
      "orderId": s.matches(S.string),
      "total": s.matches(S.float),
      "itemCount": s.matches(S.int),
      "paid": s.matches(S.bool),
      "tags": s.matches(S.array(S.string)),
      "address": s.matches(S.schema(s => {"city": s.matches(S.string)})),
      "secret": s.matches(S.string),
      "email": s.matches(Reventless.Pii.marked(~subject="orderId", S.string)),
      "note": s.matches(S.option(S.string)),
      "placedAt": s.matches(S.string),
    }
  )
  ->S.castToUnknown
  ->S.Metadata.set(~id=Reventless.StateAnnotations.stateAnnotationsId, spec)

let sortFields = ordering =>
  GraphQL_FragmentGenerator.deriveServerCapability(
    ~ordering,
    ~entityName="Orders",
    schema,
  ).sortFields

describe("deriveServerCapability by the store's ordering", () => {
  testSync("Keys sorts the annotated fields only", () =>
    expect(sortFields(Keys))->toEqual(["orderId", "placedAt"])
  )

  testSync(
    "AnyField adds every plain field after them, not lists, objects, hidden or personal",
    () =>
      expect(sortFields(AnyField))->toEqual([
        "orderId",
        "placedAt",
        "total",
        "itemCount",
        "paid",
        "note",
      ]),
  )
})

describe("the generated OrderField", () => {
  let orderField = () => {
    let fragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[],
      ~queryEntries=[
        {
          ReventlessInfra.Api.singleFieldName: "Shop_Order",
          listFieldName: "Shop_Orders",
          returnTypeName: "Shop_Order",
          specName: "Orders",
          stateSchema: schema,
          authorization: None,
          connectionSpec: true,
        },
      ],
    )
    GraphQL_Stitcher.decode(fragment).types->Array.find(t =>
      t->String.startsWith("enum Shop_OrderOrderField")
    )
  }

  afterAll(() => QueryDb_Ordering.set(_ => Keys))

  testSync("lists the annotated fields where the read model's store orders by keys", () => {
    QueryDb_Ordering.set(_ => Keys)
    expect(orderField())->toEqual(Some("enum Shop_OrderOrderField {\n  orderId\n  placedAt\n}"))
  })

  testSync("lists every plain field where the read model's store orders by any field", () => {
    QueryDb_Ordering.set(name => name == "Orders" ? AnyField : Keys)
    expect(orderField())->toEqual(
      Some(
        "enum Shop_OrderOrderField {\n  orderId\n  placedAt\n  total\n  itemCount\n  paid\n  note\n}",
      ),
    )
  })
})

// `total` sorts within one DynamoDB read window only; `orderId` is a key, so its @scanSort holds.
let perWindow =
  S.schema(s =>
    {
      "orderId": s.matches(S.string),
      "total": s.matches(S.float),
      "itemCount": s.matches(S.int),
    }
  )
  ->S.castToUnknown
  ->S.Metadata.set(
    ~id=Reventless.StateAnnotations.stateAnnotationsId,
    {...spec, indexes: [], hidden: [], scanSort: ["total", "orderId"]},
  )

describe("the fields the server orders the whole list by", () => {
  let orders = ordering =>
    GraphQL_FragmentGenerator.wholeListOrders(~ordering, ~entityName="Orders", perWindow)

  testSync(
    "on a store ordering by keys, leave out a per-window @scanSort that OrderField keeps",
    () =>
      expect((
        GraphQL_FragmentGenerator.deriveServerCapability(
          ~ordering=Keys,
          ~entityName="Orders",
          perWindow,
        ).sortFields,
        orders(Keys),
      ))->toEqual((["orderId", "total"], ["orderId"])),
  )

  testSync("on a store ordering any field, are every sort field", () =>
    expect(orders(AnyField))->toEqual(["orderId", "total", "itemCount"])
  )
})

describe("x-reventless-orders on a published read model", () => {
  let published = () =>
    Plugin_Structure.readSideDefFromSpec(
      ~plugin="Shop",
      ~name="Orders",
      ~stateSchema=perWindow,
      ~authorization=AllowAnonymous,
    ).schema
    ->JSON.parseOrThrow
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("x-reventless-orders"))

  afterAll(() => QueryDb_Ordering.set(_ => Keys))

  testSync("lists the keys where the read model's store orders by keys", () => {
    QueryDb_Ordering.set(_ => Keys)
    expect(published())->toEqual(Some(JSON.Encode.array([JSON.Encode.string("orderId")])))
  })

  testSync("lists every plain field where the read model's store orders any field", () => {
    QueryDb_Ordering.set(_ => AnyField)
    expect(published())->toEqual(
      Some(JSON.Encode.array(["orderId", "total", "itemCount"]->Array.map(JSON.Encode.string))),
    )
  })
})
