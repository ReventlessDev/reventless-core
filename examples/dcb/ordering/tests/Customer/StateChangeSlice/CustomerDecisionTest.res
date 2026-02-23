// Pure unit tests for Customer StateChangeSlice decision logic.
// Tests reduce and decide functions for RegisterCustomer, UpdateEmail,
// UpdateAddress, and DeactivateCustomer synchronously.

open Jest
open Expect

describe("RegisterCustomer:", () => {
  describe("reduce", () => {
    test("CustomerRegistered sets exists=true", () =>
      expect(
        RegisterCustomer.reduce(
          RegisterCustomer.initialDecisionModel,
          OrderingEventLog.CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
        ),
      )->toEqual({RegisterCustomer.exists: true})
    )

    test("Order events do not change model", () =>
      expect(
        RegisterCustomer.reduce(
          RegisterCustomer.initialDecisionModel,
          OrderingEventLog.OrderPlaced({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1"],
          }),
        ),
      )->toEqual(RegisterCustomer.initialDecisionModel)
    )
  })

  describe("decide", () => {
    test("on non-existent customer produces CustomerRegistered", () =>
      expect(
        RegisterCustomer.decide(
          RegisterCustomer.initialDecisionModel,
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

describe("UpdateEmail:", () => {
  let activeModel: UpdateEmail.decisionModel = {
    exists: true,
    deactivated: false,
    currentEmail: "alice@example.com",
  }

  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        UpdateEmail.decide(
          UpdateEmail.initialDecisionModel,
          UpdateEmail.UpdateEmail({customerId: "cust-1", email: "new@example.com"}),
        ),
      )->toEqual(Error(UpdateEmail.CustomerNotFound))
    )

    test("on deactivated customer returns CustomerAlreadyDeactivated", () =>
      expect(
        UpdateEmail.decide(
          {...activeModel, deactivated: true},
          UpdateEmail.UpdateEmail({customerId: "cust-1", email: "new@example.com"}),
        ),
      )->toEqual(Error(UpdateEmail.CustomerAlreadyDeactivated))
    )

    test("same email produces no events (idempotent)", () =>
      expect(
        UpdateEmail.decide(
          activeModel,
          UpdateEmail.UpdateEmail({customerId: "cust-1", email: "alice@example.com"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new email produces EmailUpdated", () =>
      expect(
        UpdateEmail.decide(
          activeModel,
          UpdateEmail.UpdateEmail({customerId: "cust-1", email: "alice2@example.com"}),
        ),
      )->toEqual(
        Ok([OrderingEventLog.EmailUpdated({customerId: "cust-1", email: "alice2@example.com"})]),
      )
    )
  })
})

describe("UpdateAddress:", () => {
  let activeModel: UpdateAddress.decisionModel = {
    exists: true,
    deactivated: false,
    currentAddress: "123 Main St",
  }

  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        UpdateAddress.decide(
          UpdateAddress.initialDecisionModel,
          UpdateAddress.UpdateAddress({customerId: "cust-1", address: "789 Pine Rd"}),
        ),
      )->toEqual(Error(UpdateAddress.CustomerNotFound))
    )

    test("same address produces no events (idempotent)", () =>
      expect(
        UpdateAddress.decide(
          activeModel,
          UpdateAddress.UpdateAddress({customerId: "cust-1", address: "123 Main St"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new address produces AddressUpdated", () =>
      expect(
        UpdateAddress.decide(
          activeModel,
          UpdateAddress.UpdateAddress({customerId: "cust-1", address: "789 Pine Rd"}),
        ),
      )->toEqual(
        Ok([OrderingEventLog.AddressUpdated({customerId: "cust-1", address: "789 Pine Rd"})]),
      )
    )
  })
})

describe("DeactivateCustomer:", () => {
  describe("decide", () => {
    test("on non-existent customer returns CustomerNotFound", () =>
      expect(
        DeactivateCustomer.decide(
          DeactivateCustomer.initialDecisionModel,
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
