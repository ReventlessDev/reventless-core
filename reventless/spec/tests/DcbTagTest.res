// Pins the variant-name extraction on `DcbTag` — the public functions that all
// route through the `variantTagName` helper introduced in plan C4 (the ~14
// inlined TAG-extraction copies collapsed onto one). Covers a schema mixing
// record-payload and payload-less variants, since the payload-less handling is
// exactly where `extractVariantNames` (DCB event-type lookups) and
// `extractAllVariantNames` (every addressable constructor) diverge.

open JestGlobals

@schema
type event =
  | ProductAdded({productId: string, name: string})
  | ProductArchived({productId: string})
  | Discontinued

describe("DcbTag variant extraction (via variantTagName)", () => {
  testSync("extractVariantNames returns record-payload constructors in order", () =>
    expect(DcbTag.extractVariantNames(eventSchema))->toEqual(["ProductAdded", "ProductArchived"])
  )
  testSync("extractVariantNames excludes the payload-less constructor", () =>
    expect(DcbTag.extractVariantNames(eventSchema)->Array.includes("Discontinued"))->toEqual(false)
  )
  testSync("extractAllVariantNames includes the payload-less constructor", () =>
    expect(DcbTag.extractAllVariantNames(eventSchema))->toEqual([
      "ProductAdded",
      "ProductArchived",
      "Discontinued",
    ])
  )
  testSync("isVariantPayloadBearing is true for a record variant", () =>
    expect(DcbTag.isVariantPayloadBearing(eventSchema, "ProductAdded"))->toEqual(true)
  )
  testSync("isVariantPayloadBearing is false for a payload-less variant", () =>
    expect(DcbTag.isVariantPayloadBearing(eventSchema, "Discontinued"))->toEqual(false)
  )
  testSync("isVariantPayloadBearing is false for an unknown constructor name", () =>
    expect(DcbTag.isVariantPayloadBearing(eventSchema, "Nope"))->toEqual(false)
  )
})

// Regression for the deploy/runtime scope drift: a cross-partition `@ref`
// reference read (AddProduct.categoryId) must be *inferred* into the effective
// scope that both Dcb_Builder and the deployed DcbCommandTopicEntryPoint thread —
// re-deriving from `@crossPartition` annotations alone dropped it, so every
// reference-guarded command was rejected on AWS.
// See docs/analysis/dcb-runtime-scope-annotation-drift.md.

@schema
type addCategoryCommand = AddCategory({categoryId: string})
@schema
type addCategoryConsumed = CategoryAdded({categoryId: string})
@schema
type categoryAddedEvent = CategoryAdded({categoryId: string})

@schema
type addProductCommand = AddProduct({productId: string, categoryId: string})
@schema
type addProductConsumed =
  | ProductAdded({productId: string})
  | CategoryAdded({categoryId: string})
  | CategoryArchived({categoryId: string})
@schema
type productAddedEvent = ProductAdded({productId: string, categoryId: string})

let catalogSlices: array<DcbTag.sliceSchemas> = [
  {
    DcbTag.name: "AddCategory",
    commandSchema: addCategoryCommandSchema->S.castToUnknown,
    consumedEventSchema: addCategoryConsumedSchema->S.castToUnknown,
    eventSchema: categoryAddedEventSchema->S.castToUnknown,
  },
  {
    DcbTag.name: "AddProduct",
    commandSchema: addProductCommandSchema->S.castToUnknown,
    consumedEventSchema: addProductConsumedSchema->S.castToUnknown,
    eventSchema: productAddedEventSchema->S.castToUnknown,
  },
]

describe("DcbTag.deriveEffectiveScope (inference vs annotation drift)", () => {
  testSync("infers the cross-partition @ref key (categoryId) into the scope", () =>
    expect(DcbTag.deriveEffectiveScope(catalogSlices).crossPartitionTagKeys)->toEqual([
      "categoryId",
    ])
  )
  testSync("indexes ProductAdded by its own partition only (categoryId is payload)", () =>
    expect(
      DcbTag.deriveEffectiveScope(catalogSlices).tagKeysByEventType->Dict.get("ProductAdded"),
    )->toEqual(Some(["productId"]))
  )
  testSync("annotation-only extraction misses it — the pre-fix runtime bug", () =>
    // No `@crossPartition` annotation exists (categoryId is `@ref`), so the old
    // annotation-based derivation the entry point used yields [].
    expect(
      DcbTag.extractCrossPartitionTagKeys(productAddedEventSchema->S.castToUnknown),
    )->toEqual([])
  )
  testSync("a healthy boundary reports nothing lost", () => {
    let scope = DcbTag.deriveEffectiveScope(catalogSlices)
    expect(scope.ambiguities)->toEqual([])
    expect(scope.droppedCrossPartitionTagKeys)->toEqual([])
  })
})

// The fallback is all-or-nothing, so one unresolvable slice decides the scope of
// every slice beside it. Here a fourth slice writes two ids and reads both off an
// event nothing in the boundary writes, which leaves it no partition — and
// `AddProduct`, untouched, loses the `categoryId` read its category check depends on.

@schema
type imagesCommand = AttachProductImage({productId: string, uploadId: string})
@schema
type imagesConsumed =
  | ImageUploaded({productId: string, uploadId: string})
  | ProductImageAttached({uploadId: string})
@schema
type imagesEvent = ProductImageAttached({productId: string, uploadId: string})

let withUnresolvableSlice: array<DcbTag.sliceSchemas> = catalogSlices->Array.concat([
  {
    DcbTag.name: "ProductImages",
    commandSchema: imagesCommandSchema->S.castToUnknown,
    consumedEventSchema: imagesConsumedSchema->S.castToUnknown,
    eventSchema: imagesEventSchema->S.castToUnknown,
  },
])

describe("DcbTag.deriveEffectiveScope (one unresolvable slice degrades the boundary)", () => {
  testSync("falls back to the annotations, which carry no cross-partition key", () =>
    expect(DcbTag.deriveEffectiveScope(withUnresolvableSlice).crossPartitionTagKeys)->toEqual([])
  )
  testSync("reports the slice that caused it", () =>
    expect(
      DcbTag.deriveEffectiveScope(withUnresolvableSlice).ambiguities->Array.map(((s, _)) => s),
    )->toEqual(["ProductImages"])
  )
  testSync("reports categoryId as lost — the harmful part, and what a caller raises on", () =>
    expect(
      DcbTag.deriveEffectiveScope(
        withUnresolvableSlice,
      ).droppedCrossPartitionTagKeys->Array.includes("categoryId"),
    )->toEqual(true)
  )
})

describe("DcbTag.chapterOfModuleUrl", () => {
  testSync("reads the chapter off a package specifier", () =>
    expect(
      DcbTag.chapterOfModuleUrl(
        "@reventlessdev/online-shop-hybrid-ordering/src/Order/StateChange/PlaceOrder.res.mjs",
      ),
    )->toEqual(Some("Order"))
  )
  testSync("uses the last src/ of a file URL", () =>
    expect(
      DcbTag.chapterOfModuleUrl(
        "file:///home/dev/src/shop/ordering/src/Order/StateChange/X.res.mjs",
      ),
    )->toEqual(Some("Order"))
  )
  testSync("a slice directly under its kind folder has no chapter", () =>
    expect(DcbTag.chapterOfModuleUrl("@x/plugin/src/StateChange/PlaceOrder.res.mjs"))->toEqual(None)
  )
  testSync("a URL with no src/ has no chapter", () =>
    expect(DcbTag.chapterOfModuleUrl("ep-test://EpTestSlice"))->toEqual(None)
  )
})

// Rule 4 end to end: a command key no decision reads by leaves the query, so the
// clause selects the order's history rather than only events naming the carrier.

@schema
type shipOrderCommand =
  | ShipOrder({
      orderId: @s.matches(DcbTag.string) string,
      carrierId: @s.matches(DcbTag.string) string,
    })
@schema
type shipOrderConsumed =
  | OrderPlaced({orderId: @s.matches(DcbTag.string) string})
  | OrderShipped({orderId: @s.matches(DcbTag.string) string})
@schema
type orderShippedEvent =
  | OrderShipped({
      orderId: @s.matches(DcbTag.string) string,
      carrierId: @s.matches(DcbTag.string) string,
    })
@schema
type shipOrderDeclaredCommand =
  | ShipOrder({
      orderId: @s.matches(DcbTag.string) string,
      carrierId: @s.matches(DcbTag.declared) string,
    })

let shipOrderShape = (~commandSchema) =>
  DcbTag.sliceShapeFromSchemas(
    ~name="ShipOrder",
    ~commandSchema,
    ~consumedEventSchema=shipOrderConsumedSchema,
    ~eventSchema=orderShippedEventSchema,
  )

describe("DcbTag.commandPayloadTagKeys", () => {
  let byOrder = Some(DcbTag.Simple({key: "orderId"}))

  testSync("a reference the slice does not decide by is payload", () =>
    expect(
      shipOrderShape(~commandSchema=shipOrderCommandSchema)->DcbTag.commandPayloadTagKeys(
        ~partitionTag=byOrder,
        ~crossPartitionTagKeys=[],
      ),
    )->toEqual(["carrierId"])
  )

  testSync("@dcbTag's declared marker keeps it in the query", () =>
    expect(
      shipOrderShape(~commandSchema=shipOrderDeclaredCommandSchema)->DcbTag.commandPayloadTagKeys(
        ~partitionTag=byOrder,
        ~crossPartitionTagKeys=[],
      ),
    )->toEqual([])
  )

  testSync("a composite boundary keeps every tag", () =>
    expect(
      shipOrderShape(~commandSchema=shipOrderCommandSchema)->DcbTag.commandPayloadTagKeys(
        ~partitionTag=Some(DcbTag.Composite({keys: ["orderId", "carrierId"], seps: ["/"]})),
        ~crossPartitionTagKeys=[],
      ),
    )->toEqual([])
  )
})

describe("DcbTag.buildQueryFromCommand with payload keys", () => {
  let command: shipOrderCommand = ShipOrder({orderId: "o1", carrierId: "c1"})

  testSync("without them the clause ANDs the carrier in", () =>
    expect(
      DcbTag.buildQueryFromCommand(
        ~eventTypes=["OrderPlaced", "OrderShipped"],
        ~schema=shipOrderCommandSchema,
        ~value=command,
      ),
    )->toEqual([
      {
        DcbTag.eventTypes: ["OrderPlaced", "OrderShipped"],
        tags: [{key: "orderId", value: "o1"}, {key: "carrierId", value: "c1"}],
      },
    ])
  )

  testSync("with them the clause is the order alone", () =>
    expect(
      DcbTag.buildQueryFromCommand(
        ~eventTypes=["OrderPlaced", "OrderShipped"],
        ~schema=shipOrderCommandSchema,
        ~value=command,
        ~payloadTagKeys=["carrierId"],
      ),
    )->toEqual([
      {DcbTag.eventTypes: ["OrderPlaced", "OrderShipped"], tags: [{key: "orderId", value: "o1"}]},
    ])
  )
})
