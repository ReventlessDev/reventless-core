// `OutboundTranslation_GWT.Make` expects a single SliceSpec with `collect` at
// the top level. The split-form production layout keeps `collect` in the
// translation body file, so we compose it onto the spec module locally.
//
// `translate` is supplied at test time via `whenTranslateMocked`; the real
// `translate` (which calls `EmailService`) is exercised in component tests.

module SendOrderConfirmationSlice = {
  include SendOrderConfirmation
  let collect = SendOrderConfirmation_Translation.collect
}

@@reventless.gwt

let cid = CustomerId.make
let oid = OrderId.make

describe("SendOrderConfirmation OutboundTranslationSlice", () => {
  testSync("collect: OrderPlaced queues an outbound TODO", () =>
    givenEvent(OrderPlaced({orderId: oid("o1"), customerId: cid("c1")}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: oid("o1"), customerId: cid("c1")})])
  )

  test("translate success marks the TODO Completed", () =>
    givenTodo("o1", {orderId: oid("o1"), customerId: cid("c1")})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Ok(None)))
    ->thenTodoStatus("o1", #Completed)
  )

  test("translate failure leaves the TODO Pending for retry", () =>
    givenTodo("o1", {orderId: oid("o1"), customerId: cid("c1")})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Error("smtp down")))
    ->thenTodoStatus("o1", #Pending)
  )
})
