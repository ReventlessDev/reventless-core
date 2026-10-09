// `translate` calls a mailer the framework does not broker, so these scenarios
// answer for it with `whenTranslateMocked`.

@@reventless.gwt

open Ordering_Examples

describe("SendOrderConfirmation OutboundTranslationSlice", () => {
  testSync("collect: OrderPlaced queues an outbound TODO", () =>
    givenEvent(OrderPlaced({orderId: o1, customerId: c1}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: o1, customerId: c1})])
  )

  // scenario-id: f72032f8-25ba-482e-be6e-4c765908bb70
  test("translate success marks the TODO Completed", () =>
    givenTodo("o1", {orderId: o1, customerId: c1})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Ok(None)))
    ->thenTodoStatus("o1", #Completed)
  )

  // scenario-id: a4563058-8777-4756-8e12-983fcd0e8f20
  test("translate failure leaves the TODO Failed for retry", () =>
    givenTodo("o1", {orderId: o1, customerId: c1})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Error("smtp down")))
    ->thenTodoStatus("o1", #Failed)
  )
})
