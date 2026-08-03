// Worked example for OutboundTranslationSlice_GWT — a "send tracking email"
// slice. Collect builds a TODO from OrderShipped; translate is mocked to
// exercise both happy path (fire-and-forget success) and failure (retry).

@@reventless.gwt

module SendTrackingEmailSlice = {
  let name = "SendTrackingEmail"

  @schema
  type consumedEvent = OrderShipped({orderId: string, email: string})

  @schema
  type outboundItem = {orderId: string, email: string}

  @schema
  type inboundCommand = NoOp

  let collect = (event, ~sourceId as _) =>
    switch event {
    | OrderShipped({orderId, email}) => [(orderId, {orderId, email})]
    }
}

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

  test("retrying translate succeeds on the third attempt → 2 retries recorded", () => {
    let calls = ref(0)
    givenTodo("o1", {orderId: "o1", email: "x@y"})
    ->whenTranslateRetrying(~maxRetries=3, (_id, _item) => {
      calls := calls.contents + 1
      Promise.resolve(calls.contents < 3 ? Error("smtp down") : Ok(None))
    })
    ->thenRetryRecorded(2)
  })

  test("translate that keeps failing exhausts maxRetries", () =>
    givenTodo("o1", {orderId: "o1", email: "x@y"})
    ->whenTranslateRetrying(~maxRetries=3, (_id, _item) => Promise.resolve(Error("smtp down")))
    ->thenRetryRecorded(3)
  )
})
