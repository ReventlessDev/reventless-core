@@reventless.gwt

open Ordering_Examples

describe("SetShippingFee StateChangeSlice", () => {
  // scenario-id: 79368841-b475-4619-881e-3d4526f5383a
  test("a shipping method gets its fee", () =>
    givenEvents([])
    ->whenCmd(SetShippingFee({shippingMethod: Standard, fee: standardFee}))
    ->thenEvent(ShippingFeeSet({shippingMethodId: "Standard", fee: standardFee}))
  )

  // scenario-id: 68d9cc8e-d7dd-4646-867f-d33f6055f826
  test("a new fee replaces the method's fee", () =>
    givenEvents([ShippingFeeSet({shippingMethodId: "Standard", fee: standardFee})])
    ->whenCmd(SetShippingFee({shippingMethod: Standard, fee: raisedStandardFee}))
    ->thenEvent(ShippingFeeSet({shippingMethodId: "Standard", fee: raisedStandardFee}))
  )

  // scenario-id: 0a2db289-0899-440c-a390-a5326cde70a6
  test("the same fee produces no events (idempotent)", () =>
    givenEvents([ShippingFeeSet({shippingMethodId: "Standard", fee: standardFee})])
    ->whenCmd(SetShippingFee({shippingMethod: Standard, fee: standardFee}))
    ->thenNoEvent
  )

  // Another method's fee is no fee of this one.
  // scenario-id: 11287660-4a1f-44c9-9132-0cfb7b4b8829
  test("another method's equal fee does not make this one set", () =>
    givenEvents([ShippingFeeSet({shippingMethodId: "Express", fee: standardFee})])
    ->whenCmd(SetShippingFee({shippingMethod: Standard, fee: standardFee}))
    ->thenEvent(ShippingFeeSet({shippingMethodId: "Standard", fee: standardFee}))
  )

  // scenario-id: ea94cfad-5c1e-45cf-932e-2b3cda021bcf
  test("a negative fee is refused", () =>
    givenEvents([])
    ->whenCmd(SetShippingFee({shippingMethod: Express, fee: negativeFee}))
    ->thenError(NegativeFee)
  )
})
