// Unit tests for Customer aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Customer

include Reventless.BehaviorTest.Make(Customer, CustomerBehavior)

describe("CustomerBehavior:", () => {
  describe("RegisterCustomer", () => {
    test(
      "on new aggregate produces CustomerRegistered",
      () =>
        givenEvents([])
        ->whenCmd(
          RegisterCustomer({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        )
        ->thenEvent(
          CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ),
    )

    test(
      "on existing aggregate returns CustomerAlreadyRegistered error",
      () =>
        givenEvents([
          CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(
          RegisterCustomer({
            customerId: "cust-1",
            email: "bob@example.com",
            address: "456 Oak Ave",
          }),
        )
        ->thenError(CustomerAlreadyRegistered),
    )
  })

  describe("UpdateEmail", () => {
    test(
      "on non-existent aggregate returns CustomerNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(UpdateEmail({customerId: "cust-1", email: "new@example.com"}))
        ->thenError(CustomerNotFound),
    )

    test(
      "on active customer produces EmailUpdated",
      () =>
        givenEvents([
          CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(UpdateEmail({customerId: "cust-1", email: "alice2@example.com"}))
        ->thenEvent(EmailUpdated({customerId: "cust-1", email: "alice2@example.com"})),
    )

    test(
      "on deactivated customer returns CustomerAlreadyDeactivated error",
      () =>
        givenEvents([
          CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
          CustomerDeactivated({customerId: "cust-1"}),
        ])
        ->whenCmd(UpdateEmail({customerId: "cust-1", email: "new@example.com"}))
        ->thenError(CustomerAlreadyDeactivated),
    )
  })

  describe("UpdateAddress", () => {
    test(
      "on active customer produces AddressUpdated",
      () =>
        givenEvents([
          CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(UpdateAddress({customerId: "cust-1", address: "789 Pine Rd"}))
        ->thenEvent(AddressUpdated({customerId: "cust-1", address: "789 Pine Rd"})),
    )
  })

  describe("DeactivateCustomer", () => {
    test(
      "on active customer produces CustomerDeactivated",
      () =>
        givenEvents([
          CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(DeactivateCustomer({customerId: "cust-1"}))
        ->thenEvent(CustomerDeactivated({customerId: "cust-1"})),
    )

    test(
      "on deactivated customer is idempotent (produces no events)",
      () =>
        givenEvents([
          CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
          CustomerDeactivated({customerId: "cust-1"}),
        ])
        ->whenCmd(DeactivateCustomer({customerId: "cust-1"}))
        ->thenNoEvent,
    )
  })
})
