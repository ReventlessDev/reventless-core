// A deadline tested at a fixed time: an order not shipped within three days of
// being placed is cancelled. `collect` counts the due time from the event's
// recorded time; `process` compares it with `~now`. `atTime` and `~recordedAt`
// say when the events happened, `~now` when the sweep runs.

module CancelUnshipped = {
  let name = "CancelUnshipped"
  let moduleUrl = ""

  @schema
  type todoItem = {orderId: string, dueAt: float}

  @schema
  type command = CancelOrder({orderId: string})

  let maxRetries = 3
  let targetName = "Order"
  let schedule = None
}

let day = 24. *. 60. *. 60. *. 1000.
let day0 = Date.fromString("2026-10-01T09:00:00Z")->Date.getTime

module CancelUnshipped_Automation = {
  module M = Reventless.AutomationSlice.Mappings.Make(CancelUnshipped)
  module type Mapping = M.Mapping
  let moduleUrl = ""

  module Orders = {
    module Id = Reventless.Id.String
    let name = "Orders"
    @schema
    type event =
      | OrderPlaced({orderId: string})
      | OrderShipped({orderId: string})
  }

  module FromOrders = Reventless.AutomationSlice.Mapping.Make(
    Orders,
    CancelUnshipped,
    {
      let collect = (event, ~sourceId as _, ctx: Reventless.AutomationSlice.context) =>
        switch (event, ctx.recordedAt) {
        | (Orders.OrderPlaced({orderId}), Some(placedAt)) => [
            (orderId, ({orderId, dueAt: placedAt +. 3. *. day}: CancelUnshipped.todoItem)),
          ]
        | _ => []
        }
      let resolve = event =>
        switch event {
        | Orders.OrderShipped({orderId}) => Some(orderId)
        | OrderPlaced(_) => None
        }
      let reschedule = _ => []
    },
  )

  let mappings: array<module(Mapping)> = [module(FromOrders)]

  let process = (id, item: CancelUnshipped.todoItem, ~now) =>
    now >= item.dueAt ? Some((id, CancelUnshipped.CancelOrder({orderId: item.orderId}))) : None
  let onExhausted = (_id, _item: CancelUnshipped.todoItem) => None
}

open CancelUnshipped
open CancelUnshipped_Automation
include Automation_GWT.FromSlice(CancelUnshipped, CancelUnshipped_Automation)
module O = Mapping(FromOrders)

describe("a deadline at a fixed time", () => {
  test("collect counts the due time from the event's recorded time", () =>
    O.givenEvent(OrderPlaced({orderId: "o1"}))
    ->O.whenCollect(~recordedAt=day0)
    ->thenTodos([("o1", {orderId: "o1", dueAt: day0 +. 3. *. day})])
  )

  test("not yet due on day 2: no command", () =>
    givenEvents([O.event(OrderPlaced({orderId: "o1"}))])
    ->atTime(day0)
    ->whenSweep(~now=day0 +. 2. *. day)
    ->thenCommands([])
  )

  test("due on day 3: CancelOrder", () =>
    givenEvents([O.event(OrderPlaced({orderId: "o1"}))])
    ->atTime(day0)
    ->whenSweep(~now=day0 +. 3. *. day)
    ->thenCommands([("o1", CancelOrder({orderId: "o1"}))])
  )

  test("shipped on day 2: nothing on day 3", () =>
    givenEvents([
      O.event(OrderPlaced({orderId: "o1"}), ~recordedAt=day0),
      O.event(OrderShipped({orderId: "o1"}), ~recordedAt=day0 +. 2. *. day),
    ])
    ->whenSweep(~now=day0 +. 3. *. day)
    ->thenCommands([])
  )

  test("a sweep given no time runs when the events happened", () =>
    givenEvents([O.event(OrderPlaced({orderId: "o1"}))])
    ->atTime(day0)
    ->whenSweep
    ->thenCommands([])
  )

  test("process is given the time a scenario fixes", () =>
    givenTodo("o1", {orderId: "o1", dueAt: day0})
    ->whenProcess(~now=day0)
    ->thenCommand("o1", CancelOrder({orderId: "o1"}))
  )
})
