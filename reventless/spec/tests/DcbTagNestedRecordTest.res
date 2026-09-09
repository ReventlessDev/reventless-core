// A record inside an array is still a consistency key.
//
// A command that carries its order lines as records — `lineItems: array<lineItem>`
// — puts every `productId` one record deeper than the walk used to look. Nothing
// about that shape fails loudly: the compiler accepts it, sury accepts it, the SDL
// and the JSON Schema both come out valid, and the first sign of trouble is a
// decision query with no product clause in it and every order rejected at runtime.
//
// So the tags are asserted here **directly**, against the extractors, rather than
// through a slice whose behaviour a redundant flat field could keep passing.

open JestGlobals

let unk = s => s->S.castToUnknown

@schema
type lineItem = {
  productId: @s.matches(DcbTag.string) string,
  quantity: int,
}

@schema
type command =
  PlaceOrder({orderId: @s.matches(DcbTag.partition) string, lineItems: array<lineItem>})

@schema
type consumedEvent =
  | OrderPlaced({orderId: @s.matches(DcbTag.string) string})
  | CatalogProductSynced({productId: @s.matches(DcbTag.string) string})

@schema
type orderLine = {
  productId: @s.matches(DcbTag.string) string,
  quantity: int,
}

// Declared after `consumedEvent` so its own `OrderPlaced` is the one an
// unannotated literal below resolves to.
@schema
type event = OrderPlaced({orderId: @s.matches(DcbTag.partition) string, lines: array<orderLine>})

// The key an author asked for rather than the one the field is called, at depth.
module Renamed = {
  @schema
  type member = {sku: @s.matches(DcbTag.stringForKey(~key="productId")) string}

  @schema
  type command = Restock({members: array<member>})
}

// A record the field holds directly, not through an array — the same descent,
// with no fan-out.
module Single = {
  @schema
  type shipTo = {customerId: @s.matches(DcbTag.string) string}

  @schema
  type command = Deliver({orderId: @s.matches(DcbTag.string) string, destination: shipTo})
}

let keys = tags => tags->Array.map(({DcbTag.key: k}) => k)
let pairs = tags => tags->Array.map(({DcbTag.key: k, value}) => (k, value))

describe("DcbTag over a record inside an array", () => {
  // The decisive assertion. The tag key is the NESTED field's name, which is what
  // makes it the same tag the producing slice writes; a key derived from
  // `lineItems` would name a tag nobody writes, and the read would come back empty
  // — the identical symptom to extracting nothing, from a different cause.
  testSync("the command's nested tags carry the nested field's key", () => {
    let value = PlaceOrder({
      orderId: "o1",
      lineItems: [{productId: "p1", quantity: 2}, {productId: "p2", quantity: 1}],
    })
    expect(DcbTag.extractTags(commandSchema, value)->pairs)->toEqual([
      ("orderId", "o1"),
      ("productId", "p1"),
      ("productId", "p2"),
    ])
  })

  // Two lines for the same product are one tag. A flat field could never produce
  // a duplicate, so nothing downstream guards against one: a repeated clause in a
  // decision query and a repeated write index entry are both made here.
  testSync("two lines for the same product collapse to one tag", () => {
    let value = PlaceOrder({
      orderId: "o1",
      lineItems: [{productId: "p1", quantity: 2}, {productId: "p1", quantity: 1}],
    })
    expect(DcbTag.extractTags(commandSchema, value)->pairs)->toEqual([
      ("orderId", "o1"),
      ("productId", "p1"),
    ])
  })

  // The write side reads through the *expanded* extractor, so it has to agree.
  // The two walks differ on a scalar array — one stringified tag against one per
  // element — and a reader must not generalise that difference: a stringified
  // line-item list is not a value any producer could match.
  testSync("the expanded extractor agrees on the emitted event", () => {
    let value = OrderPlaced({
      orderId: "o1",
      lines: [{productId: "p1", quantity: 2}, {productId: "p2", quantity: 1}],
    })
    expect(DcbTag.extractTagsExpanded(eventSchema, value)->pairs)->toEqual([
      ("orderId", "o1"),
      ("productId", "p1"),
      ("productId", "p2"),
    ])
  })

  // A record array fans out, so the query builder has to read it as the
  // multi-clause shape a tagged scalar array already is. Reading it as a single
  // AND clause is what silently ANDs `orderId` with one product.
  testSync("a record array puts the command in the fan-out query mode", () =>
    expect(DcbTag.hasTaggedArrayFields(commandSchema))->toBe(true)
  )

  testSync("an explicit key override on a nested field is honoured", () => {
    let value = Renamed.Restock({members: [{sku: "p1"}]})
    expect(DcbTag.extractTags(Renamed.commandSchema, value)->pairs)->toEqual([("productId", "p1")])
  })

  // A plain nested record is the same descent without the fan-out, so its tag is
  // found and the command still reads as single-clause.
  testSync("a record held directly is descended into but does not fan out", () => {
    let value = Single.Deliver({orderId: "o1", destination: {customerId: "c1"}})
    expect((
      DcbTag.extractTags(Single.commandSchema, value)->pairs,
      DcbTag.hasTaggedArrayFields(Single.commandSchema),
    ))->toEqual(([("orderId", "o1"), ("customerId", "c1")], false))
  })

  // The produced tag-key map is what drops vacuous (event type, tag) pairings
  // from a query. An event type whose only carrier of a key is a nested record
  // would otherwise be narrowed away from the clause that reads it.
  testSync("the produced tag keys include the nested one", () =>
    expect(DcbTag.extractTagKeysByEventType(eventSchema)->Dict.get("OrderPlaced"))->toEqual(
      Some(["orderId", "productId"]),
    )
  )
})

describe("DcbScopeInference shapes over a record inside an array", () => {
  let shape = DcbTag.sliceShapeFromSchemas(
    ~name="PlaceOrder",
    ~commandSchema=commandSchema->unk,
    ~consumedEventSchema=consumedEventSchema->unk,
    ~eventSchema=eventSchema->unk,
  )

  // `isList: true` is the answer that matters. The inference reasons about keys,
  // and a key reached per line fans out exactly as one reached per array element
  // does — reporting it single-valued would make a line-item list read as a scalar
  // foreign reference and derive the wrong partition for the slice.
  testSync("a nested id field is reported as a list under its own name", () =>
    expect(shape.command)->toEqual([
      {DcbScopeInference.name: "orderId", isList: false},
      {DcbScopeInference.name: "productId", isList: true},
    ])
  )

  // That the boundary type needed no change is the evidence the split was drawn
  // in the right place: the descent is a fact about schemas, which is `DcbTag`'s
  // half, and `infer` sees exactly what it saw before.
  testSync("the slice is still partitioned by its own key", () => {
    let derived = DcbScopeInference.infer([shape])
    expect((
      derived.partitionBySlice->Dict.get("PlaceOrder"),
      derived.crossPartitionTagKeys,
      derived.ambiguities,
    ))->toEqual((Some("orderId"), [], []))
  })
})
