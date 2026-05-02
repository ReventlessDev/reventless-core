// Send an order confirmation email when an order is placed.
@@reventless.spec

module Source = {
  let name = Order.name
  module Id = Order.Id
  @schema type event = Order.event
}

let execute = async (orderId, _meta, event, _queryEngine) =>
  switch event {
  | Order.Placed({customerId}) =>
    await EmailService.sendOrderConfirmation(
      ~email=customerId,
      ~orderId=orderId->Order.Id.toString,
    )
  | _ => ()
  }
