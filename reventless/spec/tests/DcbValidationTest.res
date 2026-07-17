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
