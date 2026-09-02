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
    expect((DcbTag.deriveEffectiveScope(catalogSlices)).crossPartitionTagKeys)->toEqual([
      "categoryId",
    ])
  )
  testSync("indexes ProductAdded by its own partition only (categoryId is payload)", () =>
    expect(
      (DcbTag.deriveEffectiveScope(catalogSlices)).tagKeysByEventType->Dict.get("ProductAdded"),
    )->toEqual(Some(["productId"]))
  )
  testSync("annotation-only extraction misses it — the pre-fix runtime bug", () =>
    // No `@crossPartition` annotation exists (categoryId is `@ref`), so the old
    // annotation-based derivation the entry point used yields [].
    expect(DcbTag.extractCrossPartitionTagKeys(productAddedEventSchema->S.castToUnknown))->toEqual([])
  )
  testSync("a healthy boundary reports nothing lost", () => {
    let scope = DcbTag.deriveEffectiveScope(catalogSlices)
    expect(scope.ambiguities)->toEqual([])
    expect(scope.droppedCrossPartitionTagKeys)->toEqual([])
  })
})

// The fallback is all-or-nothing, so one unresolvable slice decides the scope of
// every slice beside it. Here a fourth slice reads its own entity's lifecycle arm
// *with* the id on it, which leaves it no partition — and `AddProduct`, untouched,
// loses the `categoryId` read its category check depends on.

@schema
type imagesCommand = AttachProductImage({productId: string, productImage: string})
@schema
type imagesConsumed =
  | ProductAdded({productId: string})
  | ProductImageAttached({productImage: string})
@schema
type imagesEvent = ProductImageAttached({productId: string, productImage: string})

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
    expect((DcbTag.deriveEffectiveScope(withUnresolvableSlice)).crossPartitionTagKeys)->toEqual([])
  )
  testSync("reports the slice that caused it", () =>
    expect(
      (DcbTag.deriveEffectiveScope(withUnresolvableSlice)).ambiguities->Array.map(((s, _)) => s),
    )->toEqual(["ProductImages"])
  )
  testSync("reports categoryId as lost — the harmful part, and what a caller raises on", () =>
    expect(
      (DcbTag.deriveEffectiveScope(withUnresolvableSlice)).droppedCrossPartitionTagKeys->Array.includes(
        "categoryId",
      ),
    )->toEqual(true)
  )
})
