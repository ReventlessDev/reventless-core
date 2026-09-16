// Pins `DcbScopeInference` — the pure, correctness-critical derivation that
// decides each DCB tag key's scope (partition / cross-partition / payload). It
// is what lets the framework infer the "forgot @crossPartition on a cross-entity
// reference" case instead of requiring a hand annotation, so its rules are worth
// pinning directly. Also re-ported verbatim by external tooling (plan C3), which
// makes a shared spec of behaviour doubly valuable.

open JestGlobals

module I = DcbScopeInference

let id = (name): I.idField => {name, isList: false}
let ids = (name): I.idField => {name, isList: true}
let ev = (eventType, idFields): I.eventShape => {eventType, idFields}
let slice = (~name, ~command=[], ~consumed=[], ~produced=[], ~hint=None): I.sliceShape => {
  sliceName: name,
  command,
  consumed,
  produced,
  partitionHint: hint,
}

describe("DcbScopeInference.tagKeyOf", () => {
  testSync("a scalar *Id uses the field name verbatim", () =>
    expect(I.tagKeyOf(id("productId")))->toEqual("productId")
  )
  testSync("a plural *Ids array strips the trailing s to share the producer's key", () =>
    expect(I.tagKeyOf(ids("productIds")))->toEqual("productId")
  )
  testSync("a list field not ending in s is left verbatim", () =>
    expect(I.tagKeyOf(ids("data")))->toEqual("data")
  )
})

describe("DcbScopeInference.commandScalarKeys", () => {
  testSync("keeps scalar command keys and drops array-only ones", () =>
    expect(
      I.commandScalarKeys(slice(~name="PlaceOrder", ~command=[id("orderId"), ids("productIds")])),
    )->toEqual(["orderId"])
  )
})

describe("DcbScopeInference.foreignConsumedKeys", () => {
  testSync("a consumed arm the slice also produces is NOT foreign", () =>
    expect(
      I.foreignConsumedKeys(
        slice(
          ~name="Order",
          ~consumed=[ev("OrderPlaced", [id("orderId")])],
          ~produced=[ev("OrderPlaced", [id("orderId")])],
        ),
      ),
    )->toEqual([])
  )
  testSync("a consumed arm the slice does not produce IS foreign", () =>
    expect(
      I.foreignConsumedKeys(
        slice(
          ~name="Product",
          ~consumed=[
            ev("ProductAdded", [id("productId")]),
            ev("CategoryAdded", [id("categoryId")]),
          ],
          ~produced=[ev("ProductAdded", [id("productId")])],
        ),
      ),
    )->toEqual(["categoryId"])
  )
})

// A self-contained slice: reads and writes only its own event, so nothing is
// cross-partition and its produced key is its partition.
let orderSlice = slice(
  ~name="Order",
  ~command=[id("orderId")],
  ~consumed=[ev("OrderPlaced", [id("orderId")])],
  ~produced=[ev("OrderPlaced", [id("orderId")])],
)

// A cross-entity reference: Product reads Category's lifecycle by a scalar
// categoryId it does not itself produce.
let productSlice = slice(
  ~name="Product",
  ~command=[id("productId"), id("categoryId")],
  ~consumed=[ev("ProductAdded", [id("productId")]), ev("CategoryAdded", [id("categoryId")])],
  ~produced=[ev("ProductAdded", [id("productId")])],
)
let categorySlice = slice(
  ~name="Category",
  ~command=[id("categoryId")],
  ~consumed=[ev("CategoryAdded", [id("categoryId")])],
  ~produced=[ev("CategoryAdded", [id("categoryId")])],
)

describe("DcbScopeInference.crossPartitionForSlice", () => {
  testSync("a self-contained slice has no cross-partition keys", () =>
    expect(I.crossPartitionForSlice(orderSlice))->toEqual([])
  )
  testSync("a scalar foreign reference is cross-partition", () =>
    expect(I.crossPartitionForSlice(productSlice))->toEqual(["categoryId"])
  )
  testSync("an array-only foreign key auto-fans and stays partition-scoped", () => {
    // Same shape as productSlice, but the command carries the foreign categoryId
    // only as an array (categoryIds). An array-only foreign read auto-fans per
    // element and must NOT be promoted to cross-partition — the contrast with the
    // scalar productSlice case above.
    let productArrayRef = slice(
      ~name="Product",
      ~command=[id("productId"), ids("categoryIds")],
      ~consumed=[ev("ProductAdded", [id("productId")]), ev("CategoryAdded", [id("categoryId")])],
      ~produced=[ev("ProductAdded", [id("productId")])],
    )
    expect(I.crossPartitionForSlice(productArrayRef))->toEqual([])
  })
})

describe("DcbScopeInference.infer", () => {
  testSync("infers each slice's own partition from its produced key", () => {
    let d = I.infer([orderSlice])
    expect(d.partitionBySlice->Dict.get("Order"))->toEqual(Some("orderId"))
  })

  testSync("a scalar cross-entity reference becomes a cross-partition key", () => {
    let d = I.infer([productSlice, categorySlice])
    expect(d.crossPartitionTagKeys)->toEqual(["categoryId"])
  })

  testSync("categoryId is owned by the Category slice", () => {
    let d = I.infer([productSlice, categorySlice])
    expect(d.ownerByKey->Dict.get("categoryId"))->toEqual(Some("Category"))
  })

  testSync("a slice producing two owned keys is ambiguous without a hint", () => {
    let demand = slice(
      ~name="RecordProductDemand",
      ~command=[id("productId"), id("orderId")],
      ~produced=[ev("ProductDemandRecorded", [id("productId"), id("orderId")])],
    )
    let d = I.infer([demand])
    expect(d.partitionBySlice->Dict.get("RecordProductDemand"))->toEqual(None)
    expect(d.ambiguities->Array.length)->toEqual(1)
  })

  testSync("an explicit @partitionTag hint resolves the ambiguity", () => {
    let demand = slice(
      ~name="RecordProductDemand",
      ~command=[id("productId"), id("orderId")],
      ~produced=[ev("ProductDemandRecorded", [id("productId"), id("orderId")])],
      ~hint=Some("productId"),
    )
    let d = I.infer([demand])
    expect(d.partitionBySlice->Dict.get("RecordProductDemand"))->toEqual(Some("productId"))
    expect(d.ambiguities)->toEqual([])
  })

  testSync("tagKeysByEventType indexes the producer's own partition key", () => {
    let d = I.infer([orderSlice])
    expect(d.tagKeysByEventType->Dict.get("OrderPlaced"))->toEqual(Some(["orderId"]))
  })
})

// A slice reading its own entity's lifecycle — `ProductImages` folding
// `ProductAdded` to learn the product exists. Its events carry one key, so it is
// partitioned by that key whatever its consumed arms declare.
let imagesReadingOwnLifecycle = slice(
  ~name="ProductImages",
  ~command=[id("productId")],
  ~consumed=[ev("ProductAdded", [id("productId")]), ev("ProductImageAttached", [])],
  ~produced=[ev("ProductImageAttached", [id("productId")])],
)

// Two keys, both named on an arm whose producer is out of sight. Seen alone the
// slice cannot tell identity from reference, and the arm is what to change.
let cancelReadingPlacedIds = slice(
  ~name="CancelOrder",
  ~command=[id("orderId")],
  ~consumed=[ev("OrderPlaced", [id("orderId"), ids("productIds")])],
  ~produced=[ev("OrderCancelled", [id("orderId"), ids("productIds")])],
)

describe("DcbScopeInference.partitionBlockers", () => {
  testSync("names the foreign arm that claimed each produced key", () =>
    expect(I.partitionBlockers(cancelReadingPlacedIds))->toEqual([
      ("orderId", ["OrderPlaced"]),
      ("productId", ["OrderPlaced"]),
    ])
  )

  testSync("a slice with a partition has nothing to explain", () => {
    expect(I.partitionBlockers(orderSlice))->toEqual([])
    expect(I.partitionBlockers(imagesReadingOwnLifecycle))->toEqual([])
  })
})

describe("DcbScopeInference.infer — a consumed arm naming the slice's own id", () => {
  testSync("a single-key slice keeps its partition", () => {
    let d = I.infer([imagesReadingOwnLifecycle])
    expect(d.partitionBySlice->Dict.get("ProductImages"))->toEqual(Some("productId"))
    expect(d.ambiguities)->toEqual([])
  })

  testSync("a two-key slice seen alone is left with none, and the reason names the arm", () => {
    let d = I.infer([cancelReadingPlacedIds])
    expect(d.partitionBySlice->Dict.get("CancelOrder"))->toEqual(None)
    expect(
      d.ambiguities->Array.some(
        ((slice, reason)) =>
          slice == "CancelOrder" && reason->String.includes("OrderPlaced declares orderId"),
      ),
    )->toEqual(true)
  })

  testSync("dropping the field from the consumed arm resolves it", () => {
    let fixed = slice(
      ~name="CancelOrder",
      ~command=[id("orderId")],
      ~consumed=[ev("OrderPlaced", [ids("productIds")])],
      ~produced=[ev("OrderCancelled", [id("orderId"), ids("productIds")])],
    )
    let d = I.infer([fixed])
    expect(d.partitionBySlice->Dict.get("CancelOrder"))->toEqual(Some("orderId"))
    expect(d.ambiguities)->toEqual([])
  })
})
