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

// The same automation, whose command names its field `order` where the decision
// that runs it says `orderId`: a flow that types each side's command passes.
module AutoShipByOrderSlice = {
  let name = "AutoShipByOrder"
  let moduleUrl = ""

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = ShipOrder({order: string})

  let maxRetries = 3
  let targetName = "Order"
  let schedule = None
}

module AutoShipByOrderAutomation = {
  module M = Reventless.AutomationSlice.Mappings.Make(AutoShipByOrderSlice)
  module type Mapping = M.Mapping
  let moduleUrl = ""

  module FromOrders = Reventless.AutomationSlice.Mapping.Make(
    AutoShipAutomation.Orders,
    AutoShipByOrderSlice,
    {
      let collect = (event, ~sourceId as _, _ctx) =>
        switch event {
        | AutoShipAutomation.Orders.OrderPlaced({orderId}) => [
            (orderId, ({orderId: orderId}: AutoShipByOrderSlice.todoItem)),
          ]
        | OrderShipped(_) => []
        }
      let resolve = event =>
        switch event {
        | AutoShipAutomation.Orders.OrderShipped({orderId}) => Some(orderId)
        | OrderPlaced(_) => None
        }
      let reschedule = _ => []
    },
  )

  let mappings: array<module(Mapping)> = [module(FromOrders)]
  let process = (id, _todo: AutoShipByOrderSlice.todoItem, ~now as _) => Some((
    id,
    AutoShipByOrderSlice.ShipOrder({order: id}),
  ))
  let onExhausted = (_id, _todo, ~lastError as _) => None
}

// A reminder an hour after an order is placed, unless it ships first: the
// schedule is set by the event, keyed by the order, and its tick makes the item.
module RemindSlice = {
  let name = "Remind"
  let moduleUrl = ""

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = RemindCustomer({orderId: string})

  let maxRetries = 3
  let targetName = "Order"
  let schedule = None
}

module RemindAutomation = {
  module M = Reventless.AutomationSlice.Mappings.Make(RemindSlice)
  module type Mapping = M.Mapping
  let moduleUrl = ""

  module FromClock = Reventless.AutomationSlice.Mapping.Make(
    Reventless.Clock,
    RemindSlice,
    {
      open Reventless.Clock
      let collect = (Tick({key, at}), ~sourceId as _, _ctx) => [
        (itemId(key, at), ({orderId: key}: RemindSlice.todoItem)),
      ]
      let resolve = _ => None
      let reschedule = _ => []
    },
  )

  module FromOrders = Reventless.AutomationSlice.Mapping.Make(
    AutoShipAutomation.Orders,
    RemindSlice,
    {
      let collect = (_, ~sourceId as _, _ctx) => []
      let resolve = _ => None
      let reschedule = event =>
        switch event {
        | AutoShipAutomation.Orders.OrderPlaced({orderId}) => [
            Reventless.AutomationSlice.Set({
              key: orderId,
              time: Once({moment: After(Hours(1))}),
            }),
          ]
        | OrderShipped({orderId}) => [Clear({key: orderId})]
        }
    },
  )

  let mappings: array<module(Mapping)> = [module(FromClock), module(FromOrders)]
  let process = (id, item: RemindSlice.todoItem, ~now as _) => Some((
    id,
    RemindSlice.RemindCustomer({orderId: item.orderId}),
  ))
  let onExhausted = (_id, _item, ~lastError as _) => None
}

// -- Step modules ------------------------------------------------------------

module Place = DecisionStep(PlaceOrderSlice, PlaceOrderDecision)
module Auto = AutomationStep(AutoShipSlice, AutoShipAutomation)
module Ship = DecisionStep(ShipOrderSlice, ShipOrderDecision)
module View = ViewStep(OrdersViewSlice, OrdersViewProjection)
module Confirm = OutboundStep(ConfirmSlice, ConfirmTranslation)
module AutoByOrder = AutomationStep(AutoShipByOrderSlice, AutoShipByOrderAutomation)
module Remind = AutomationStep(RemindSlice, RemindAutomation)

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
      ->Ship.whenIssued
      ->Ship.thenEvents([ShipOrderSlice.OrderShipped({orderId: "o1"})])
      ->View.thenRow("o1", {OrdersViewSlice.orderId: "o1", item: "book", status: "Shipped"})
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
    ->View.thenRow("o1", {OrdersViewSlice.orderId: "o1", item: "book", status: "Shipped"})
    ->View.thenRow("o2", {OrdersViewSlice.orderId: "o2", item: "pen", status: "Placed"})
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
      ->Ship.whenIssued
      // Wrong on purpose: the order shipped is o1.
      ->Ship.thenEvent(ShipOrderSlice.OrderShipped({orderId: "o2"}))
      ->View.thenRow("o1", {OrdersViewSlice.orderId: "o1", item: "book", status: "Placed"})
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

// -- What was sent is what runs ----------------------------------------------

let failureOf = async (flowP: flow) =>
  switch (await flowP)->outcomeOf {
  | Error(m) => Some(m)
  | Ok() => None
  }

let placed = () =>
  start
  ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}))
  ->Place.thenEvent(PlaceOrderSlice.OrderPlaced({orderId: "o1", item: "book"}))

describe("a command sent by one part and run by the next", () => {
  JestGlobals.testPromise("typed twice, each side to its own type, it passes", async () => {
    let failure = await placed()
    ->AutoByOrder.whenReacts
    ->AutoByOrder.thenIssuesCommand(AutoShipByOrderSlice.ShipOrder({order: "o1"}))
    ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->Ship.thenEvent(ShipOrderSlice.OrderShipped({orderId: "o1"}))
    ->failureOf
    JestGlobals.expect(failure)->JestGlobals.toEqual(None)
  })

  JestGlobals.testPromise("run as sent, the field the decision cannot read fails it", async () => {
    let failure = await placed()
    ->AutoByOrder.whenReacts
    ->AutoByOrder.thenIssuesCommand(AutoShipByOrderSlice.ShipOrder({order: "o1"}))
    ->Ship.whenIssued
    ->Ship.thenEvent(ShipOrderSlice.OrderShipped({orderId: "o1"}))
    ->failureOf
    switch failure {
    | Some(TranslateError({actual: Some(reason), ?step})) => {
        JestGlobals.expect(
          reason->String.startsWith(`ShipOrder cannot read {"TAG":"ShipOrder","order":"o1"}`),
        )->JestGlobals.toBe(true)
        JestGlobals.expect(step->Option.map(s => s.verb))->JestGlobals.toEqual(Some("whenIssued"))
      }
    | other => JestGlobals.expect(other)->JestGlobals.toEqual(None)
    }
  })

  JestGlobals.testPromise("~only past what was sent fails, naming how many were", async () => {
    let failure = await placed()->Auto.whenReacts->Ship.whenIssued(~only=2)->failureOf
    switch failure {
    | Some(TranslateError({actual: Some(reason)})) =>
      JestGlobals.expect(reason)->JestGlobals.toBe("~only=2, but 1 command(s) were sent")
    | other => JestGlobals.expect(other)->JestGlobals.toEqual(None)
    }
  })

  JestGlobals.testPromise("nothing sent is nothing to run", async () => {
    let failure = await start->Ship.whenIssued->failureOf
    switch failure {
    | Some(TranslateError({actual: Some(reason)})) =>
      JestGlobals.expect(reason)->JestGlobals.toBe("the step before sent no command")
    | other => JestGlobals.expect(other)->JestGlobals.toEqual(None)
    }
  })
})

// -- The expectations a flow lacked ------------------------------------------

describe("what a flow can expect besides whole events and rows", () => {
  test("a decision that records nothing", () =>
    placed()
    ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->Ship.thenNoEvent
  )

  test("a decision that did not refuse, its events not compared", () =>
    placed()->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))->Ship.thenAccepted
  )

  test("no row for an order never placed", () => placed()->View.thenNoRow("o9"))

  test("some fields of the row", () =>
    placed()->View.thenRowShows("o1", row => {"status": row.status}, {"status": "Placed"})
  )

  JestGlobals.testPromise("a field picked and wrong fails, showing what was picked", async () => {
    let failure = await placed()
    ->View.thenRowShows("o1", row => {"status": row.status}, {"status": "Shipped"})
    ->failureOf
    switch failure {
    | Some(StateMismatch({key, expected, actual})) => {
        JestGlobals.expect(key)->JestGlobals.toBe("o1")
        JestGlobals.expect(expected->Option.map(j => JSON.stringify(j)))->JestGlobals.toEqual(
          Some(`[{"status":"Shipped"}]`),
        )
        JestGlobals.expect(actual->Option.map(j => JSON.stringify(j)))->JestGlobals.toEqual(
          Some(`[{"status":"Placed"}]`),
        )
      }
    | other => JestGlobals.expect(other)->JestGlobals.toEqual(None)
    }
  })

  JestGlobals.testPromise("thenAccepted fails on a refusal", async () => {
    let failure = await start
    ->Ship.whenCommand(ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->Ship.thenAccepted
    ->failureOf
    JestGlobals.expect(failure->Option.map(Outcome.kindName))->JestGlobals.toEqual(
      Some("ErrorMismatch"),
    )
  })
})

// -- A flow keeps time -------------------------------------------------------

let placedAtNine = () =>
  start->Place.whenCommand(
    ~at="2026-03-02T09:00:00Z",
    PlaceOrderSlice.PlaceOrder({orderId: "o1", item: "book"}),
  )

describe("a flow keeps time", () => {
  test("a schedule an event set fires an hour later, and not before", () =>
    placedAtNine()
    ->Remind.whenTimePasses(~until="2026-03-02T09:59:00Z")
    ->Remind.thenIssuesNoCommand
    ->Remind.whenTimePasses(~until="2026-03-02T10:00:00Z")
    ->Remind.thenIssuesCommand(RemindSlice.RemindCustomer({orderId: "o1"}))
    // Once only: it does not fire again.
    ->Remind.whenTimePasses(~until="2026-03-03T10:00:00Z")
    ->Remind.thenIssuesNoCommand
  )

  test("an event that clears the schedule before it is due stops it", () =>
    placedAtNine()
    ->Ship.whenCommand(~at="2026-03-02T09:30:00Z", ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->Remind.whenTimePasses(~until="2026-03-02T11:00:00Z")
    ->Remind.thenIssuesNoCommand
  )

  JestGlobals.testPromise("time only moves forward", async () => {
    let failure = await placedAtNine()
    ->Ship.whenCommand(~at="2026-03-02T08:00:00Z", ShipOrderSlice.ShipOrder({orderId: "o1"}))
    ->failureOf
    switch failure {
    | Some(Throw({error, ?step})) => {
        JestGlobals.expect(
          error,
        )->JestGlobals.toBe(`~at="2026-03-02T08:00:00Z" is before the flow's time, 2026-03-02T09:00:00Z: time only moves forward`)
        JestGlobals.expect(step->Option.map(s => s.number))->JestGlobals.toEqual(Some(2))
      }
    | other => JestGlobals.expect(other)->JestGlobals.toEqual(None)
    }
  })
})
