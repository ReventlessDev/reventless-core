// Worked example for Flow_GWT — a single-plugin order flow threaded through a
// command slice, an automation, a second command slice, a read-model view and
// an outbound effect. One declarative chain asserts that the slices compose as
// an Event Modeling lane would draw them.
//
// Also exercises DCB tag isolation: a second order is placed successfully even
// though a first order is already on the shared log, because each command step
// filters the log by its command's tags.

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

module PlaceOrderDecision = {
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
  let moduleUrl = ""

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = ShipOrder({orderId: string})

  let maxRetries = 3
  let targetName = "Order"
  let schedule = None
}

module AutoShipAutomation = {
  module M = Reventless.AutomationSlice.Mappings.Make(AutoShipSlice)
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
    AutoShipSlice,
    {
      let collect = (event, ~sourceId as _, _ctx) =>
        switch event {
        | Orders.OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: AutoShipSlice.todoItem))]
        | OrderShipped(_) => []
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
  let process = (id, _todo: AutoShipSlice.todoItem, ~now as _) => Some((
    id,
    AutoShipSlice.ShipOrder({orderId: id}),
  ))
  let onExhausted = (_id, _todo, ~lastError as _) => None
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

module ShipOrderDecision = {
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
  module Id = Reventless.Id.StringPure
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
  let moduleUrl = ""

  @schema
  type consumedEvent = OrderPlaced({orderId: string})

  @schema
  type outboundItem = {orderId: string}

  @schema
  type inboundCommand = unit

  let maxRetries = 1
  let targetName = None
  let sourceNames = []
  let externalSystem = None
  let capabilityNeeds = []
  let traits = []
}

module ConfirmTranslation = {
  let moduleUrl = ""

  let collect = (event, ~sourceId as _) =>
    switch event {
    | ConfirmSlice.OrderPlaced({orderId}) => [
        (orderId, ({orderId: orderId}: ConfirmSlice.outboundItem)),
      ]
    }

  let translate = async (_id, _item, ~capabilities as _) => Ok(None)
  let onExhausted = (_id, _item, ~lastError as _) => None
}

// -- Step modules ------------------------------------------------------------

module Place = DecisionStep(PlaceOrderSlice, PlaceOrderDecision)
module Auto = AutomationStep(AutoShipSlice, AutoShipAutomation)
module Ship = DecisionStep(ShipOrderSlice, ShipOrderDecision)
module View = ViewStep(OrdersViewSlice, OrdersViewProjection)
module Confirm = OutboundStep(ConfirmSlice, ConfirmTranslation)

// -- Flows -------------------------------------------------------------------

describe("Order flow (single plugin)", () => {
  test(
    "place → auto-ship → ship → view Shipped → confirmation fired",
    ~tells="An order ships",
    () =>
      start
      ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
      ->Place.thenEvents([PlaceOrderSlice.OrderPlaced({orderId: "o1", item: "book"})])
      ->Auto.whenReacts
      ->Auto.thenIssuesCommand(AutoShipSlice.ShipOrder({orderId: "o1"}))
      ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
      ->Ship.thenEvents([ShipOrderSlice.OrderShipped({orderId: "o1"})])
      ->View.thenViewState("o1", {OrdersViewSlice.orderId: "o1", item: "book", status: "Shipped"})
      ->Confirm.thenOutbound([("o1", {ConfirmSlice.orderId: "o1"})]),
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

// -- A failure names its step ------------------------------------------------

describe("a flow that fails at its sixth step", () => {
  let failed = async () =>
    (
      await start
      ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
      ->Place.thenEvents([PlaceOrderSlice.OrderPlaced({orderId: "o1", item: "book"})])
      ->Auto.whenReacts
      ->Auto.thenIssuesCommand(AutoShipSlice.ShipOrder({orderId: "o1"}))
      ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
      // Wrong on purpose: the order shipped is o1.
      ->Ship.thenEvent(ShipOrderSlice.OrderShipped({orderId: "o2"}))
      ->View.thenViewState("o1", {OrdersViewSlice.orderId: "o1", item: "book", status: "Placed"})
      ->Confirm.thenOutbound([("o1", {ConfirmSlice.orderId: "o1"})])
    )->outcomeOf

  let mismatchOf = async () =>
    switch await failed() {
    | Error(m) => m
    | Ok() => JsError.throwWithMessage("the flow was meant to fail")
    }

  JestGlobals.testPromise("the mismatch carries the step, not a later one", async () => {
    let m = await mismatchOf()
    JestGlobals.expect(Outcome.stepOf(m))->JestGlobals.toEqual(
      Some({
        Outcome.number: 6,
        total: 8,
        verb: "thenEvent",
        part: {Outcome.kind: Decision, name: "ShipOrder"},
      }),
    )
  })

  JestGlobals.testPromise("the hint names the step and points at its part", async () => {
    let hint = Hint.forMismatch(~slice="Flow", await mismatchOf())
    JestGlobals.expect(hint.locus)->JestGlobals.toBe("ShipOrder.decide")
    JestGlobals.expect(
      hint->Hint.format->String.startsWith("At step 6 of 8, ShipOrder.thenEvent.\n"),
    )->JestGlobals.toBe(true)
  })

  JestGlobals.testPromise("the JSON hint carries the step", async () => {
    let json = Hint.forMismatch(~slice="Flow", await mismatchOf())->Hint.toJson
    JestGlobals.expect(
      JSON.stringify(
        json,
      )->String.includes(`"step":{"number":6,"total":8,"verb":"thenEvent","part":{"kind":"Decision","name":"ShipOrder"}}`),
    )->JestGlobals.toBe(true)
  })

  JestGlobals.testPromise("jest's failure message says the step", async () => {
    let outcome = await failed()
    let message = switch JestBind.assertOutcome(~slice="Flow", outcome) {
    | () => ""
    | exception JsExn(e) => e->JsExn.message->Option.getOr("")
    }
    JestGlobals.expect(
      message->String.includes("At step 6 of 8, ShipOrder.thenEvent."),
    )->JestGlobals.toBe(true)
  })

  JestGlobals.testPromise("a flow that passes has no step to name", async () => {
    let outcome = (
      await start
      ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
      ->Place.thenEvent(PlaceOrderSlice.OrderPlaced({orderId: "o1", item: "book"}))
    )->outcomeOf
    JestGlobals.expect(outcome)->JestGlobals.toEqual(Outcome.pass)
  })
})
