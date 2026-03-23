// Pure unit tests for Customer StateChangeSlice decision logic.
// Tests evolve and decide functions for RegisterCustomer, ChangeEmail,
// ChangeAddress, and DeactivateCustomer synchronously.

open Jest
open Expect

describe("RegisterCustomer:", () => {
  describe("evolve", () => {
    test("CustomerRegistered sets exists=true", () =>
      expect(
        RegisterCustomer.evolve(
          RegisterCustomer.initialState,
          OrderingEventLog.CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ),
      )->toEqual({RegisterCustomer.exists: true})
    )

    test("Order events do not change state", () =>
      expect(
        RegisterCustomer.evolve(
          RegisterCustomer.initialState,
          OrderingEventLog.OrderPlaced({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1"],
          }),
        ),
      )->toEqual(RegisterCustomer.initialState)
    )
  })

  describe("decide", () => {
    test("on non-existent customer produces CustomerRegistered", () =>
      expect(
        RegisterCustomer.decide(
          RegisterCustomer.initialState,
          RegisterCustomer.RegisterCustomer({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ),
      )->toEqual(
        Ok([
          OrderingEventLog.CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ]),
      )
    )

    test("on existing customer returns CustomerAlreadyRegistered", () =>
      expect(
        RegisterCustomer.decide(
          {RegisterCustomer.exists: true},
          RegisterCustomer.RegisterCustomer({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ),
      )->toEqual(Error(RegisterCustomer.CustomerAlreadyRegistered))
    )
  })
})

describe("ChangeEmail:", () => {
  let activeState: ChangeEmail.state = {
    exists: true,
    deactivated: false,
    currentEmail: "alice@example.com",
  }

  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        ChangeEmail.decide(
          ChangeEmail.initialState,
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "new@example.com"}),
        ),
      )->toEqual(Error(ChangeEmail.CustomerNotFound))
    )

    test("on deactivated customer returns CustomerAlreadyDeactivated", () =>
      expect(
        ChangeEmail.decide(
          {...activeState, deactivated: true},
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "new@example.com"}),
        ),
      )->toEqual(Error(ChangeEmail.CustomerAlreadyDeactivated))
    )

    test("same email produces no events (idempotent)", () =>
      expect(
        ChangeEmail.decide(
          activeState,
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "alice@example.com"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new email produces EmailChanged", () =>
      expect(
        ChangeEmail.decide(
          activeState,
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "alice2@example.com"}),
        ),
      )->toEqual(
        Ok([OrderingEventLog.EmailChanged({customerId: "cust-1", email: "alice2@example.com"})]),
      )
    )
  })
})

describe("ChangeAddress:", () => {
  let activeState: ChangeAddress.state = {
    exists: true,
    deactivated: false,
    currentAddress: "123 Main St",
  }

  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        ChangeAddress.decide(
          ChangeAddress.initialState,
          ChangeAddress.ChangeAddress({customerId: "cust-1", address: "789 Pine Rd"}),
        ),
      )->toEqual(Error(ChangeAddress.CustomerNotFound))
    )

    test("same address produces no events (idempotent)", () =>
      expect(
        ChangeAddress.decide(
          activeState,
          ChangeAddress.ChangeAddress({customerId: "cust-1", address: "123 Main St"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new address produces AddressChanged", () =>
      expect(
        ChangeAddress.decide(
          activeState,
          ChangeAddress.ChangeAddress({customerId: "cust-1", address: "789 Pine Rd"}),
        ),
      )->toEqual(
        Ok([OrderingEventLog.AddressChanged({customerId: "cust-1", address: "789 Pine Rd"})]),
      )
    )
  })
})

describe("DeactivateCustomer:", () => {
  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        DeactivateCustomer.decide(
          DeactivateCustomer.initialState,
          DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"}),
        ),
      )->toEqual(Error(DeactivateCustomer.CustomerNotFound))
    )

    test("on already deactivated customer returns Ok([]) (idempotent)", () =>
      expect(
        DeactivateCustomer.decide(
          {DeactivateCustomer.exists: true, deactivated: true},
          DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on active customer produces CustomerDeactivated", () =>
      expect(
        DeactivateCustomer.decide(
          {DeactivateCustomer.exists: true, deactivated: false},
          DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"}),
        ),
      )->toEqual(
        Ok([OrderingEventLog.CustomerDeactivated({customerId: "cust-1"})]),
      )
    )
  })
})
