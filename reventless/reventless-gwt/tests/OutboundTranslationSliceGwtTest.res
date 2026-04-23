// Worked example for OutboundTranslationSlice_GWT — a "send tracking email"
// slice. Collect builds a TODO from OrderShipped; translate is mocked to
// exercise both happy path (fire-and-forget success) and failure (retry).

module SendTrackingEmailSlice = {
  let name = "SendTrackingEmail"

  @schema
  type consumedEvent = OrderShipped({orderId: string, email: string})

  @schema
  type outboundItem = {orderId: string, email: string}

  @schema
  type inboundCommand = NoOp

  let collect = event =>
    switch event {
    | OrderShipped({orderId, email}) => [(orderId, {orderId, email})]
    }
}

include OutboundTranslationSlice_GWT.Make(SendTrackingEmailSlice)

describe("SendTrackingEmail OutboundTranslationSlice", () => {
  test("collect: OrderShipped queues an outbound TODO", async () =>
    givenEvent(OrderShipped({orderId: "o1", email: "x@y"}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: "o1", email: "x@y"})])
  )

  test("translate success is fire-and-forget → #Completed", () =>
    givenTodo("o1", {orderId: "o1", email: "x@y"})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Ok(None)))
    ->thenTodoStatus("o1", #Completed)
  )

  test("translate failure records a retry → #Pending", () =>
    givenTodo("o1", {orderId: "o1", email: "x@y"})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Error("smtp down")))
    ->thenTodoStatus("o1", #Pending)
  )
})
