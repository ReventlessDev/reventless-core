// Automation_GWT.FromSlice over a two-source slice written as the framework
// takes it: a Spec, and a body with per-source mappings, `process` and
// `onExhausted`. The second source's events do not name the order, so its
// mapping keys the to-do by `~sourceId`.

module ShipPaid = {
  let name = "ShipPaid"
  let moduleUrl = ""

  @schema
  type todoItem = {orderId: string}

  @schema
  type command =
    | Ship({orderId: string})
    | GiveUp({orderId: string})

  let maxRetries = 3
  let heartbeatInterval = 60
  let targetName = "Order"
}

module ShipPaid_Automation = {
  module M = Reventless.AutomationSlice.Mappings.Make(ShipPaid)
  module type Mapping = M.Mapping
  let moduleUrl = ""

  module Orders = {
    module Id = Reventless.Id.String
    let name = "Orders"
    @schema
    type event =
      | OrderPlaced({orderId: string})
      | OrderCancelled({orderId: string})
  }

  module Payments = {
    module Id = Reventless.Id.String
    let name = "Payments"
    @schema
    type event =
      | Captured({amount: int})
      | Refunded({amount: int})
  }

  module FromOrders = Reventless.AutomationSlice.Mapping.Make(
    Orders,
    ShipPaid,
    {
      let collect = (event, ~sourceId as _, _ctx) =>
        switch event {
        | Orders.OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: ShipPaid.todoItem))]
        | OrderCancelled(_) => []
        }
      let resolve = event =>
        switch event {
        | Orders.OrderCancelled({orderId}) => Some(orderId)
        | OrderPlaced(_) => None
        }
    },
  )

  module FromPayments = Reventless.AutomationSlice.Mapping.Make(
    Payments,
    ShipPaid,
    {
      let collect = (event, ~sourceId, _ctx) =>
        switch event {
        | Payments.Captured(_) => [(sourceId, ({orderId: sourceId}: ShipPaid.todoItem))]
        | Refunded(_) => []
        }
      let resolve = event =>
        switch event {
        | Payments.Refunded(_) => None
        | Captured(_) => None
        }
    },
  )

  let mappings: array<module(Mapping)> = [module(FromOrders), module(FromPayments)]

  let process = (id, _item: ShipPaid.todoItem) => Some((id, ShipPaid.Ship({orderId: id})))
  let onExhausted = (id, _item: ShipPaid.todoItem) => Some((id, ShipPaid.GiveUp({orderId: id})))
}

open ShipPaid
open ShipPaid_Automation
include Automation_GWT.FromSlice(ShipPaid, ShipPaid_Automation)
module O = Mapping(FromOrders)
module P = Mapping(FromPayments)

describe("Automation_GWT.FromSlice", () => {
  test("collect through one mapping", () =>
    O.givenEvent(OrderPlaced({orderId: "o1"}))
    ->O.whenCollect
    ->thenTodos([("o1", {orderId: "o1"})])
  )

  test("collect keys by the source id where the event does not name it", () =>
    P.givenEvent(Captured({amount: 5}))
    ->P.whenCollect(~sourceId="o2")
    ->thenTodos([("o2", {orderId: "o2"})])
  )

  test("resolve through one mapping", () =>
    O.givenEvent(OrderCancelled({orderId: "o1"}))
    ->O.whenResolve
    ->thenResolved(Some("o1"))
  )

  test("process", () =>
    givenTodo("o1", {orderId: "o1"})->whenProcess->thenCommand("o1", Ship({orderId: "o1"}))
  )

  test("exhausted: onExhausted is what the domain hears", () =>
    givenTodo("o1", {orderId: "o1"})->whenExhausted->thenCommand("o1", GiveUp({orderId: "o1"}))
  )

  test("sweep: both sources route by name, in event order", () =>
    givenEvents([
      P.event(Captured({amount: 5}), ~sourceId="o2"),
      O.event(OrderPlaced({orderId: "o1"})),
    ])
    ->whenSweep
    ->thenCommands([("o2", Ship({orderId: "o2"})), ("o1", Ship({orderId: "o1"}))])
  )

  test("sweep: a resolve completes only a row that exists", () =>
    givenEvents([
      O.event(OrderCancelled({orderId: "o1"})),
      O.event(OrderPlaced({orderId: "o1"})),
      O.event(OrderPlaced({orderId: "o3"})),
      O.event(OrderCancelled({orderId: "o3"})),
    ])
    ->whenSweep
    ->thenScenarioTodos([("o1", {orderId: "o1"})])
  )

  test("andThenEvents drains what later events resolve", () =>
    givenEvents([O.event(OrderPlaced({orderId: "o1"}))])
    ->whenSweep
    ->andThenEvents([O.event(OrderCancelled({orderId: "o1"}))])
    ->thenScenarioTodos([])
  )
})
