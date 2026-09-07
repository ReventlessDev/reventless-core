@@reventless.gwt

describe("ChangeAddress StateChangeSlice", () => {
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeAddress({customerId: "c1", address: "789 Pine"}))
    ->thenError(CustomerNotFound)
  )

  test("active customer produces AddressChanged", () =>
    givenEvents([CustomerRegistered({address: "123 Main"})])
    ->whenCmd(ChangeAddress({customerId: "c1", address: "789 Pine"}))
    ->thenEvent(AddressChanged({customerId: "c1", address: "789 Pine"}))
  )

  test("same address produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered({address: "123 Main"})])
    ->whenCmd(ChangeAddress({customerId: "c1", address: "123 Main"}))
    ->thenNoEvent
  )

  test("deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([CustomerRegistered({address: "123 Main"}), CustomerDeactivated])
    ->whenCmd(ChangeAddress({customerId: "c1", address: "789 Pine"}))
    ->thenError(CustomerAlreadyDeactivated)
  )
})
