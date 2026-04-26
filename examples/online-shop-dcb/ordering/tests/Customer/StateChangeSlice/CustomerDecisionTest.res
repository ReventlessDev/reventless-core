// Pure unit tests for Customer StateChangeSlice decision logic.
// Tests evolve and decide functions for RegisterCustomer, ChangeEmail,
// ChangeAddress, and DeactivateCustomer synchronously.

open Jest
open Expect

describe("RegisterCustomer:", () => {
  describe("evolve", () => {
    test("CustomerRegistered sets exists=true", () =>
      expect(
        RegisterCustomer_Behavior.evolve(
          RegisterCustomer_Behavior.initialState,
          RegisterCustomer.CustomerRegistered,
        ),
      )->toEqual({RegisterCustomer_Behavior.exists: true})
    )
  })

  describe("decide", () => {
    test("on non-existent customer produces CustomerRegistered", () =>
      expect(
        RegisterCustomer_Behavior.decide(
          RegisterCustomer_Behavior.initialState,
          RegisterCustomer.RegisterCustomer({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ),
      )->toEqual(
        Ok([
          RegisterCustomer.CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ]),
      )
    )

    test("on existing customer returns CustomerAlreadyRegistered", () =>
      expect(
        RegisterCustomer_Behavior.decide(
          {RegisterCustomer_Behavior.exists: true},
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
  let activeState: ChangeEmail_Behavior.state = {
    exists: true,
    deactivated: false,
    currentEmail: "alice@example.com",
  }

  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        ChangeEmail_Behavior.decide(
          ChangeEmail_Behavior.initialState,
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "new@example.com"}),
        ),
      )->toEqual(Error(ChangeEmail.CustomerNotFound))
    )

    test("on deactivated customer returns CustomerAlreadyDeactivated", () =>
      expect(
        ChangeEmail_Behavior.decide(
          {...activeState, deactivated: true},
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "new@example.com"}),
        ),
      )->toEqual(Error(ChangeEmail.CustomerAlreadyDeactivated))
    )

    test("same email produces no events (idempotent)", () =>
      expect(
        ChangeEmail_Behavior.decide(
          activeState,
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "alice@example.com"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new email produces EmailChanged", () =>
      expect(
        ChangeEmail_Behavior.decide(
          activeState,
          ChangeEmail.ChangeEmail({customerId: "cust-1", email: "alice2@example.com"}),
        ),
      )->toEqual(
        Ok([ChangeEmail.EmailChanged({customerId: "cust-1", email: "alice2@example.com"})]),
      )
    )
  })
})

describe("ChangeAddress:", () => {
  let activeState: ChangeAddress_Behavior.state = {
    exists: true,
    deactivated: false,
    currentAddress: "123 Main St",
  }

  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        ChangeAddress_Behavior.decide(
          ChangeAddress_Behavior.initialState,
          ChangeAddress.ChangeAddress({customerId: "cust-1", address: "789 Pine Rd"}),
        ),
      )->toEqual(Error(ChangeAddress.CustomerNotFound))
    )

    test("same address produces no events (idempotent)", () =>
      expect(
        ChangeAddress_Behavior.decide(
          activeState,
          ChangeAddress.ChangeAddress({customerId: "cust-1", address: "123 Main St"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new address produces AddressChanged", () =>
      expect(
        ChangeAddress_Behavior.decide(
          activeState,
          ChangeAddress.ChangeAddress({customerId: "cust-1", address: "789 Pine Rd"}),
        ),
      )->toEqual(
        Ok([ChangeAddress.AddressChanged({customerId: "cust-1", address: "789 Pine Rd"})]),
      )
    )
  })
})

describe("DeactivateCustomer:", () => {
  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        DeactivateCustomer_Behavior.decide(
          DeactivateCustomer_Behavior.initialState,
          DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"}),
        ),
      )->toEqual(Error(DeactivateCustomer.CustomerNotFound))
    )

    test("on already deactivated customer returns Ok([]) (idempotent)", () =>
      expect(
        DeactivateCustomer_Behavior.decide(
          {DeactivateCustomer_Behavior.exists: true, deactivated: true},
          DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on active customer produces CustomerDeactivated", () =>
      expect(
        DeactivateCustomer_Behavior.decide(
          {DeactivateCustomer_Behavior.exists: true, deactivated: false},
          DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"}),
        ),
      )->toEqual(
        Ok([DeactivateCustomer.CustomerDeactivated({customerId: "cust-1"})]),
      )
    )
  })
})
