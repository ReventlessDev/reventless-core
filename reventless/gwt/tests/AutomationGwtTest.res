// Worked example for AutomationSlice_GWT — a "ship order" automation:
// OrderPlaced ⇒ TODO, ShipmentCreated resolves the TODO, process emits
// CreateShipment. Covers the unit combinators (collect / resolve / process)
// and the scenario combinators (sweep / andThenEvents).

@@reventless.gwt

module ShipOrderSlice = {
  let name = "ShipOrder"

  @schema
  type consumedEvent =
    | OrderPlaced({orderId: string, shippingAddress: string})
    | ShipmentCreated({orderId: string})

  @schema
  type todoItem = {orderId: string, shippingAddress: string}

  @schema
  type command = CreateShipment({orderId: string, address: string})

  let collect = event =>
    switch event {
    | OrderPlaced({orderId, shippingAddress}) => [(orderId, {orderId, shippingAddress})]
    | _ => []
    }

  let resolve = event =>
    switch event {
    | ShipmentCreated({orderId}) => Some(orderId)
    | _ => None
    }

  let process = (_id, item) =>
    Some((item.orderId, CreateShipment({orderId: item.orderId, address: item.shippingAddress})))
  let onExhausted = (_id, _item) => None
}

describe("ShipOrder AutomationSlice", () => {
  test("collect: OrderPlaced creates a pending TODO", () =>
    givenEvent(OrderPlaced({orderId: "o1", shippingAddress: "1 Main St"}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: "o1", shippingAddress: "1 Main St"})])
  )

  test("resolve: ShipmentCreated marks the TODO done", () =>
    givenEvent(ShipmentCreated({orderId: "o1"}))
    ->whenResolve
    ->thenResolved(Some("o1"))
  )

  test("process: pending TODO emits CreateShipment", () =>
    givenTodo("o1", {orderId: "o1", shippingAddress: "1 Main St"})
    ->whenProcess
    ->thenCommand("o1", CreateShipment({orderId: "o1", address: "1 Main St"}))
  )

  test("sweep: events → commands, andThenEvents drains todos", () => {
    let s =
      givenEvents([OrderPlaced({orderId: "o1", shippingAddress: "1 Main St"})])
      ->whenSweep
    let commandsOk =
      thenCommands(s, [("o1", CreateShipment({orderId: "o1", address: "1 Main St"}))])
    let drained = andThenEvents(s, [ShipmentCreated({orderId: "o1"})])
    let todosOk = thenScenarioTodos(drained, [])
    switch (commandsOk, todosOk) {
    | (Ok(), Ok()) => Outcome.pass
    | (Error(_) as e, _) => e
    | (_, Error(_) as e) => e
    }
  })
})
