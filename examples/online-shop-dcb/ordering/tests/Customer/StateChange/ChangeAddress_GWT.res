@@reventless.gwt

open OrderingExamples

describe("ChangeAddress StateChangeSlice", () => {
  // scenario-id: c948f0e0-ef17-4731-a26b-4439a38140fb
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeAddress({customerId: c1, address: pineStreet}))
    ->thenError(CustomerNotFound)
  )

  // scenario-id: a0268783-c043-4c2e-ad16-063b08f9d3f3
  test("active customer produces AddressChanged", () =>
    givenEvents([CustomerRegistered({address: mainStreet})])
    ->whenCmd(ChangeAddress({customerId: c1, address: pineStreet}))
    ->thenEvent(AddressChanged({customerId: c1, address: pineStreet}))
  )

  // scenario-id: 9c652691-a3f7-4aee-b1a7-0055db84d836
  test("same address produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered({address: mainStreet})])
    ->whenCmd(ChangeAddress({customerId: c1, address: mainStreet}))
    ->thenNoEvent
  )

  // scenario-id: 909078a3-adc9-479e-85cc-88549075d963
  test("deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([CustomerRegistered({address: mainStreet}), CustomerDeactivated])
    ->whenCmd(ChangeAddress({customerId: c1, address: pineStreet}))
    ->thenError(CustomerAlreadyDeactivated)
  )
})
