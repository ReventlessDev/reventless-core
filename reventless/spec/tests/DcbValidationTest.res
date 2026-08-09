// Regression tests for the A8 fix to `DcbValidation.schemasAreCompatible`.
// Before A8 any `(Object, Object)` / `(Union, Union)` pair was treated as
// compatible, so a producer and consumer that agreed on variant tags but
// disagreed on payload field types (or nested payloads) drifted silently.
// These pin the recursion: field-type drift, field-name drift, and NESTED
// payload drift must all be reported incompatible.

open JestGlobals

let u = DcbTag.toUnknownSchema

@schema type flat = {productId: string, qty: int}
@schema type flatSameShape = {productId: string, qty: int}
@schema type flatTypeDrift = {productId: string, qty: string}
@schema type flatNameDrift = {productId: string, quantity: int}

@schema type inner = {tag: string}
@schema type innerDrift = {tag: int}
@schema type nested = {productId: string, meta: inner}
@schema type nestedDrift = {productId: string, meta: innerDrift}

describe("DcbValidation.schemasAreCompatible", () => {
  testSync("identical object shapes are compatible", () =>
    expect(DcbValidation.schemasAreCompatible(u(flatSchema), u(flatSameShapeSchema)))->toEqual(true)
  )
  testSync("a differing field type is incompatible (the A8 fix — not every Object pair passes)", () =>
    expect(DcbValidation.schemasAreCompatible(u(flatSchema), u(flatTypeDriftSchema)))->toEqual(false)
  )
  testSync("a differing field name is incompatible", () =>
    expect(DcbValidation.schemasAreCompatible(u(flatSchema), u(flatNameDriftSchema)))->toEqual(false)
  )
  testSync("identical nested payloads are compatible", () =>
    expect(DcbValidation.schemasAreCompatible(u(nestedSchema), u(nestedSchema)))->toEqual(true)
  )
  testSync("nested payload drift is caught by the recursion", () =>
    expect(DcbValidation.schemasAreCompatible(u(nestedSchema), u(nestedDriftSchema)))->toEqual(false)
  )
})

// The message a field-type mismatch produces. `schemaTypeName` alone renders any
// two unions as "union", so the report named neither side's actual shape — the
// case that made a real producer/consumer drift unreadable in a deploy log.
@schema type priorTypeCarrier = NoPriorType | PriorType(string)

describe("DcbValidation.describeSchema", () => {
  testSync("a tagged union is described by its variant tags, not just 'union'", () =>
    expect(DcbValidation.describeSchema(u(priorTypeCarrierSchema)))->toEqual(
      "union[NoPriorType | PriorType]",
    )
  )
  testSync("a union with untagged members falls back to member kinds", () =>
    expect(DcbValidation.describeSchema(S.option(S.string)->DcbTag.toUnknownSchema))->toEqual(
      "union[string | unknown]",
    )
  )
  testSync("the two sides of the real drift no longer read identically", () => {
    let consumed = DcbValidation.describeSchema(S.option(S.string)->DcbTag.toUnknownSchema)
    let produced = DcbValidation.describeSchema(u(priorTypeCarrierSchema))
    expect(consumed == produced)->toEqual(false)
  })
  testSync("an object is described by its field names", () =>
    expect(DcbValidation.describeSchema(u(flatSchema)))->toEqual("object{productId, qty}")
  )
})

// The compatibility consequence of seeing payload-less arms: two unions that
// differ only by one are no longer indistinguishable.
@schema type onlyPayloadArm = PriorType(string)

describe("DcbValidation payload-less variants inside a mixed union", () => {
  testSync("both arms are extracted", () =>
    expect(
      DcbValidation.extractAllVariants(u(priorTypeCarrierSchema))->Array.map(v => v.tagName),
    )->toEqual(["NoPriorType", "PriorType"])
  )
  testSync("dropping a payload-less arm is now an incompatibility", () =>
    expect(
      DcbValidation.schemasAreCompatible(u(priorTypeCarrierSchema), u(onlyPayloadArmSchema)),
    )->toEqual(false)
  )
})
