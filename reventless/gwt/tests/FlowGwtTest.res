// Worked example for Flow_GWT — a single-plugin order flow threaded through a
// command slice, an automation, a second command slice, a read-model view and
// an outbound effect. One declarative chain asserts that the slices compose as
// an Event Modeling lane would draw them.
//
// Also exercises DCB tag isolation: a second order is placed successfully even
// though a first order is already on the shared log, because each command step
// filters the log by its command's tags.
// See `docs/plans/done/gwt-flow-and-extension-test-kinds.md` Phase 2.

S.enableJson()

open Flow_GWT

// -- Slices ------------------------------------------------------------------

module PlaceOrderSlice = {
  let name = "PlaceOrder"

  @schema
  type consumedEvent = OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type command = PlaceOrder({orderId: @s.matches(Reventless.DcbTag.string) string, item: string})

  @schema
  type error = AlreadyPlaced

  @schema
  type event = OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string, item: string})
}

module PlaceOrderBehavior = {
  module Spec = PlaceOrderSlice
  type state = {placed: bool}
  let initialState = {placed: false}

  let evolve = (_state, event: PlaceOrderSlice.consumedEvent) =>
    switch event {
    | OrderPlaced(_) => {placed: true}
    }

  let decide = (state, command: PlaceOrderSlice.command) =>
    switch command {
    | PlaceOrder({orderId, item}) =>
      state.placed
        ? Error(PlaceOrderSlice.AlreadyPlaced)
        : Ok([PlaceOrderSlice.OrderPlaced({orderId, item})])
    }
}

module AutoShipSlice = {
  let name = "AutoShip"

  @schema
  type consumedEvent =
    | OrderPlaced({orderId: string})
    | OrderShipped({orderId: string})

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = ShipOrder({orderId: string})

  let collect = event =>
    switch event {
    | OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: todoItem))]
    | OrderShipped(_) => []
    }

  let resolve = event =>
    switch event {
    | OrderShipped({orderId}) => Some(orderId)
    | OrderPlaced(_) => None
    }

  let process = (id, _todo) => Some((id, ShipOrder({orderId: id})))
}

module ShipOrderSlice = {
  let name = "ShipOrder"

  @schema
  type consumedEvent =
    | OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string})
    | OrderShipped({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type command = ShipOrder({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type error = NotPlaced

  @schema
  type event = OrderShipped({orderId: @s.matches(Reventless.DcbTag.string) string})
}

module ShipOrderBehavior = {
  module Spec = ShipOrderSlice
  type state = {placed: bool, shipped: bool}
  let initialState = {placed: false, shipped: false}

  let evolve = (state, event: ShipOrderSlice.consumedEvent) =>
    switch event {
    | OrderPlaced(_) => {...state, placed: true}
    | OrderShipped(_) => {...state, shipped: true}
    }

  let decide = (state, command: ShipOrderSlice.command) =>
    switch command {
    | ShipOrder({orderId}) =>
      if !state.placed {
        Error(ShipOrderSlice.NotPlaced)
      } else if state.shipped {
        Ok([])
      } else {
        Ok([ShipOrderSlice.OrderShipped({orderId: orderId})])
      }
    }
}

module OrdersViewSlice = {
  let name = "OrdersView"

  @schema
  type state = {orderId: string, item: string, status: string}

  @schema
  type consumedEvent =
    | OrderPlaced({orderId: string, item: string})
    | OrderShipped({orderId: string})

  let subIdConfig = None
}

module OrdersViewProjection = {
  module Spec = OrdersViewSlice
  open Reventless.Projection

  let project = ({event}: Reventless.StateViewSlice.consumed<OrdersViewSlice.consumedEvent>) =>
    switch event {
    | OrderPlaced({orderId, item}) => [
        Set(orderId, ({orderId, item, status: "Placed"}: OrdersViewSlice.state)),
      ]
    | OrderShipped({orderId}) => [Update(orderId, state => {...state, status: "Shipped"})]
    }
}

module ConfirmSlice = {
  let name = "Confirm"

  @schema
  type consumedEvent = OrderPlaced({orderId: string})

  @schema
  type outboundItem = {orderId: string}

  @schema
  type inboundCommand = unit

  let collect = event =>
    switch event {
    | OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: outboundItem))]
    }
}

// -- Step modules ------------------------------------------------------------

module Place = CommandStep(PlaceOrderSlice, PlaceOrderBehavior)
module Auto = AutomationStep(AutoShipSlice)
module Ship = CommandStep(ShipOrderSlice, ShipOrderBehavior)
module View = ViewStep(OrdersViewSlice, OrdersViewProjection)
module Confirm = OutboundStep(ConfirmSlice)

// -- Flows -------------------------------------------------------------------

describe("Order flow (single plugin)", () => {
  test("place → auto-ship → ship → view Shipped → confirmation fired", () =>
    start
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
    ->Place.thenEvents([PlaceOrderSlice.OrderPlaced({orderId: "o1", item: "book"})])
    ->Auto.whenReacts
    ->Auto.thenIssuesCommand(AutoShipSlice.ShipOrder({orderId: "o1"}))
    ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->Ship.thenEvents([ShipOrderSlice.OrderShipped({orderId: "o1"})])
    ->View.thenViewState("o1", {OrdersViewSlice.orderId: "o1", item: "book", status: "Shipped"})
    ->Confirm.thenOutbound([("o1", {ConfirmSlice.orderId: "o1"})])
  )

  test("automation does not re-issue ShipOrder once the order is shipped", () =>
    start
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
    ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->Auto.whenReacts
    ->Auto.thenIssuesNoCommand
  )

  test("re-placing the same order is rejected", () =>
    start
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
    ->Place.thenError(AlreadyPlaced)
  )

  test("a second, different order is not blocked by the first (DCB tag isolation)", () =>
    start
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
    ->Place.thenEvent(PlaceOrderSlice.OrderPlaced({orderId: "o1", item: "book"}))
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o2", item: "pen"}))
    ->Place.thenEvent(PlaceOrderSlice.OrderPlaced({orderId: "o2", item: "pen"}))
  )

  test("shipping one order leaves a sibling order Placed", () =>
    start
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o2", item: "pen"}))
    ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->View.thenViewState("o1", {OrdersViewSlice.orderId: "o1", item: "book", status: "Shipped"})
    ->View.thenViewState("o2", {OrdersViewSlice.orderId: "o2", item: "pen", status: "Placed"})
  )
})
