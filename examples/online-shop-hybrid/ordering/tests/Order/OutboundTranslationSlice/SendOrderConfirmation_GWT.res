// `OutboundTranslation_GWT.Make` expects a single SliceSpec with `collect` at
// the top level. Compose `collect` onto the spec module locally — the real
// `translate` is mocked at test time via `whenTranslateMocked`.

module SendOrderConfirmationSlice = {
  include SendOrderConfirmation
  let collect = SendOrderConfirmation_Translation.collect
}

@@reventless.gwt

describe("SendOrderConfirmation OutboundTranslationSlice", () => {
  testSync("collect: OrderPlaced queues an outbound TODO", () =>
    givenEvent(OrderPlaced({orderId: "o1", customerId: "c1"}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: "o1", customerId: "c1"})])
  )

  test("translate success marks the TODO Completed", () =>
    givenTodo("o1", {orderId: "o1", customerId: "c1"})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Ok(None)))
    ->thenTodoStatus("o1", #Completed)
  )

  test("translate failure leaves the TODO Pending for retry", () =>
    givenTodo("o1", {orderId: "o1", customerId: "c1"})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Error("smtp down")))
    ->thenTodoStatus("o1", #Pending)
  )
})
