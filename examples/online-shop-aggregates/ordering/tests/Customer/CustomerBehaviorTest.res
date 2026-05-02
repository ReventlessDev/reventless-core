// Unit tests for Customer aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Customer

include ReventlessGwt.Behavior_GWT.MakeFromAggregate(Customer, CustomerBehavior)

describe("CustomerBehavior:", () => {
  describe("Register", () => {
    test(
      "on new aggregate produces Registered",
      () =>
        givenEvents([])
        ->whenCmd(
          Register({
            email: "alice@example.com",
            address: "123 Main St",
          }),
        )
        ->thenEvent(
          Registered({
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ),
    )

    test(
      "on existing aggregate returns CustomerAlreadyRegistered error",
      () =>
        givenEvents([
          Registered({
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(
          Register({
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
        ->whenCmd(UpdateEmail({email: "new@example.com"}))
        ->thenError(CustomerNotFound),
    )

    test(
      "on active customer produces EmailUpdated",
      () =>
        givenEvents([
          Registered({
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(UpdateEmail({email: "alice2@example.com"}))
        ->thenEvent(EmailUpdated({email: "alice2@example.com"})),
    )

    test(
      "on deactivated customer returns CustomerAlreadyDeactivated error",
      () =>
        givenEvents([
          Registered({
            email: "alice@example.com",
            address: "123 Main St",
          }),
          Deactivated,
        ])
        ->whenCmd(UpdateEmail({email: "new@example.com"}))
        ->thenError(CustomerAlreadyDeactivated),
    )
  })

  describe("UpdateAddress", () => {
    test(
      "on active customer produces AddressUpdated",
      () =>
        givenEvents([
          Registered({
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(UpdateAddress({address: "789 Pine Rd"}))
        ->thenEvent(AddressUpdated({address: "789 Pine Rd"})),
    )
  })

  describe("Deactivate", () => {
    test(
      "on active customer produces Deactivated",
      () =>
        givenEvents([
          Registered({
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ])
        ->whenCmd(Deactivate)
        ->thenEvent(Deactivated),
    )

    test(
      "on deactivated customer is idempotent (produces no events)",
      () =>
        givenEvents([
          Registered({
            email: "alice@example.com",
            address: "123 Main St",
          }),
          Deactivated,
        ])
        ->whenCmd(Deactivate)
        ->thenNoEvent,
    )
  })
})
