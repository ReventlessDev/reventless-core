@@reventless.gwt

let cid = CustomerId.make

describe("ChangeAddress StateChangeSlice", () => {
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeAddress({customerId: cid("c1"), address: "789 Pine"}))
    ->thenError(CustomerNotFound)
  )

  test("active customer produces AddressChanged", () =>
    givenEvents([CustomerRegistered({address: "123 Main"})])
    ->whenCmd(ChangeAddress({customerId: cid("c1"), address: "789 Pine"}))
    ->thenEvent(AddressChanged({customerId: cid("c1"), address: "789 Pine"}))
  )

  test("same address produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered({address: "123 Main"})])
    ->whenCmd(ChangeAddress({customerId: cid("c1"), address: "123 Main"}))
    ->thenNoEvent
  )

  test("deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([CustomerRegistered({address: "123 Main"}), CustomerDeactivated])
    ->whenCmd(ChangeAddress({customerId: cid("c1"), address: "789 Pine"}))
    ->thenError(CustomerAlreadyDeactivated)
  )
})
