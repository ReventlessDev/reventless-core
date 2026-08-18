// Worked example for Flow_GWT.AggregateCommandStep — two aggregate-style
// command steps threaded through one shared log. Verifies the framework's
// new aggregate-ID partitioning:
//
//   - Two aggregates sequence cleanly when they share an ID.
//   - A second aggregate's history is isolated from the first by `~id`, so a
//     command on `o2` does not see `o1`'s prior events.
//   - The `Error` branch flows through `thenError` like the slice form.


open Flow_GWT

// -- Aggregate: CatalogProduct (one event family, no error) -----------------

module CatalogProductAggregate = {
  let name = "CatalogProduct"

  @schema
  type command =
    | SyncNewProduct({productId: string, name: string})

  @schema
  type event =
    | CatalogProductSynced({productId: string, name: string})

  @schema
  type error = AlreadySynced
}

module CatalogProductBehavior = {
  module Spec = CatalogProductAggregate

  type state = NotSynced | Synced

  let initialState = NotSynced
  let snapshot = None

  let evolve = (_state, event: CatalogProductAggregate.event) =>
    switch event {
    | CatalogProductSynced(_) => Synced
    }

  let decide = (state, command: CatalogProductAggregate.command) =>
    switch (state, command) {
    | (NotSynced, SyncNewProduct({productId, name})) =>
      Ok([CatalogProductAggregate.CatalogProductSynced({productId, name})])
    | (Synced, _) => Error(CatalogProductAggregate.AlreadySynced)
    }

  let moduleUrl = "test://CatalogProductBehavior"
}

// -- Aggregate: Order ---------------------------------------------------------

module OrderAggregate = {
  let name = "Order"

  @schema
  type command =
    | Place({customerId: string, productIds: array<string>})
    | Ship

  @schema
  type event =
    | Placed({customerId: string, productIds: array<string>})
    | Shipped

  @schema
  type error =
    | AlreadyPlaced
    | NotPlaced
}

module OrderBehavior = {
  module Spec = OrderAggregate

  type state = {placed: bool, shipped: bool}

  let initialState = {placed: false, shipped: false}
  let snapshot = None

  let evolve = (state, event: OrderAggregate.event) =>
    switch event {
    | Placed(_) => {...state, placed: true}
    | Shipped => {...state, shipped: true}
    }

  let decide = (state, command: OrderAggregate.command) =>
    switch command {
    | Place({customerId, productIds}) =>
      state.placed
        ? Error(OrderAggregate.AlreadyPlaced)
        : Ok([OrderAggregate.Placed({customerId, productIds})])
    | Ship =>
      if !state.placed {
        Error(OrderAggregate.NotPlaced)
      } else if state.shipped {
        Ok([])
      } else {
        Ok([OrderAggregate.Shipped])
      }
    }

  let moduleUrl = "test://OrderBehavior"
}

// -- Step modules -------------------------------------------------------------

module Sync = AggregateCommandStep(CatalogProductAggregate, CatalogProductBehavior)
module Place = AggregateCommandStep(OrderAggregate, OrderBehavior)

// -- Flows --------------------------------------------------------------------

describe("Aggregate flow (single plugin)", () => {
  test("sync product → place order → ship order, threaded through aggregate-ID", () =>
    start
    ->Sync.whenCommand(~id="p1", SyncNewProduct({productId: "p1", name: "Book"}))
    ->Sync.thenEvent(CatalogProductSynced({productId: "p1", name: "Book"}))
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.thenEvent(Placed({customerId: "c1", productIds: ["p1"]}))
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.thenEvent(Shipped)
  )

  test("re-placing the same order is rejected (per-aggregate state replay)", () =>
    start
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.thenError(AlreadyPlaced)
  )

  test("a different order is not blocked by the first (~id isolation)", () =>
    start
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.thenEvent(Placed({customerId: "c1", productIds: ["p1"]}))
    ->Place.whenCommand(~id="o2", Place({customerId: "c2", productIds: ["p2"]}))
    ->Place.thenEvent(Placed({customerId: "c2", productIds: ["p2"]}))
  )

  test("ship before place returns NotPlaced", () =>
    start
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.thenError(NotPlaced)
  )

  test("givenEvents seeds history for an ~id starting mid-stream", () =>
    start
    ->Place.givenEvents(~id="o1", [Placed({customerId: "c1", productIds: ["p1"]})])
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.thenEvent(Shipped)
  )

  test("ship after ship is idempotent (no events emitted)", () =>
    start
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.thenNoEvent
  )

  test("two independent aggregates evolve their own state in parallel", () =>
    start
    ->Sync.whenCommand(~id="p1", SyncNewProduct({productId: "p1", name: "Book"}))
    ->Sync.thenEvent(CatalogProductSynced({productId: "p1", name: "Book"}))
    ->Sync.whenCommand(~id="p2", SyncNewProduct({productId: "p2", name: "Pen"}))
    ->Sync.thenEvent(CatalogProductSynced({productId: "p2", name: "Pen"}))
    ->Sync.whenCommand(~id="p1", SyncNewProduct({productId: "p1", name: "Book"}))
    ->Sync.thenError(AlreadySynced)
  )
})
