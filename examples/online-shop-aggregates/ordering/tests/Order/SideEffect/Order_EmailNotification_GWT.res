// GWT for the aggregate-style egress `Order_EmailNotification`. Mirrors the
// hybrid example's DCB-side `SendOrderConfirmation_GWT` (OutboundTranslation).
// The folder `SideEffect/` is what the PPX uses to infer the DSL kind.

@@reventless.gwt

// Each test installs the recording backend at the start of its pipeline; the
// install also resets the recorded-calls ref, so tests stay isolated without
// pulling rescript-jest's `beforeEach` into the example's dependencies.

describe("Order_EmailNotification SideEffect", () => {
  test("Placed triggers a confirmation email", () => {
    EmailService_Mock.install()
    givenEventForId(
      Order.Id.makeFromString("o1"),
      Order.Placed({customerId: "alice@example.com", productIds: ["p1"]}),
    )
    ->whenExecuted(EmailService_Mock.mock)
    ->thenExternalCalls([
      EmailService_Mock.SendOrderConfirmation({email: "alice@example.com", orderId: "o1"}),
    ])
  })

  test("Shipped is a no-op", () => {
    EmailService_Mock.install()
    givenEvent(Order.Shipped)
    ->whenExecuted(EmailService_Mock.mock)
    ->thenNoExternalCalls
  })

  test("Cancelled is a no-op", () => {
    EmailService_Mock.install()
    givenEvent(Order.Cancelled({productIds: ["p1"]}))
    ->whenExecuted(EmailService_Mock.mock)
    ->thenNoExternalCalls
  })
})
