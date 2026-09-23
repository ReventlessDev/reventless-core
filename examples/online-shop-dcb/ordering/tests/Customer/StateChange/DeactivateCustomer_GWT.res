@@reventless.gwt

open Ordering_Examples

describe("DeactivateCustomer StateChangeSlice", () => {
  // scenario-id: 1baa12f3-6e24-4660-8b23-aaabcf0de1e3
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(DeactivateCustomer({customerId: c1}))
    ->thenError(CustomerNotFound)
  )

  // scenario-id: 0e52a2a6-9424-474d-b3be-b6c3c8d12bbe
  test("existing customer produces CustomerDeactivated", () =>
    givenEvents([CustomerRegistered])
    ->whenCmd(DeactivateCustomer({customerId: c1}))
    ->thenEvent(CustomerDeactivated({customerId: c1}))
  )

  // scenario-id: c4b62b80-ea23-4d1a-a937-68409af297ec
  test("already deactivated customer produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered, CustomerDeactivated])
    ->whenCmd(DeactivateCustomer({customerId: c1}))
    ->thenNoEvent
  )
})
