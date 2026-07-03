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
