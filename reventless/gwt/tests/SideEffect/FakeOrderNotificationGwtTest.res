// Smoke test for SideEffect_GWT. Folder `SideEffect/` triggers the PPX kind
// inference; filename `FakeOrderNotification_GWT.res` resolves the SE under
// test to the sibling `FakeOrderNotification.res` (a `SideEffect.T`).

@@reventless.gwt

describe("FakeOrderNotification SideEffect", () => {
  JestGlobals.beforeEach(MockEmail.reset)

  test("Placed records a confirmation send", () =>
    givenEventForId(
      Source.Id.makeFromString("o1"),
      Source.Placed({email: "alice@example.com"}),
    )
    ->whenExecuted(MockEmail.mock)
    ->thenExternalCalls([
      MockEmail.SendConfirmation({email: "alice@example.com", orderId: "o1"}),
    ])
  )

  test("Shipped is a no-op", () =>
    givenEvent(Source.Shipped)
    ->whenExecuted(MockEmail.mock)
    ->thenNoExternalCalls
  )

  test("Two distinct Placed events record two calls", async () => {
    let _ =
      await givenEventForId(Source.Id.makeFromString("o1"), Source.Placed({email: "a@a"}))
      ->whenExecuted(MockEmail.mock)
    await givenEventForId(Source.Id.makeFromString("o2"), Source.Placed({email: "b@b"}))
    ->whenExecuted(MockEmail.mock)
    ->thenExternalCallCount(2)
  })
})
