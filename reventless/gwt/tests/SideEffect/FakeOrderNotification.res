// Fixture: a minimal `SideEffect.T` that calls `MockEmail` on `Placed`.
// Mirrors the aggregate example pattern (`Order_EmailNotification` calling
// `EmailService.sendOrderConfirmation`) but in-package so the framework's own
// test suite can exercise it without depending on the example plugin.

module Source = {
  let name = "FakeOrder"
  module Id = Reventless.Id.String

  @schema
  type event =
    | Placed({email: string})
    | Shipped
}

let moduleUrl = "test://FakeOrderNotification"

let execute = async (id, _meta, event, _queryEngine) =>
  switch event {
  | Source.Placed({email}) =>
    MockEmail.recordSend(~email, ~orderId=Source.Id.toString(id))
  | Source.Shipped => ()
  }
