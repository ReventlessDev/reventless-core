// End-to-end test for the hybrid OrderingPlugin using the in-memory platform.
// Verifies that the Order/CatalogProduct DCB slices dispatch and produce events.

open Reventless
open ReventlessInMemory.AsyncTest
open ReventlessInMemory.AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Topic name = DcbEventLog name ++ "EventTopic" = "OrderingEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("OrderingEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = ReventlessInMemory.TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog for Order/CatalogProduct
// ─────────────────────────────────────────────────────────────

module OrderingEventLogMaker = ReventlessInMemory.DcbEventLog_Builder.Make(Bus)
let eventLog = OrderingEventLogMaker.make(~name="Ordering")

// ─────────────────────────────────────────────────────────────
// Build StateChangeSlices
// ─────────────────────────────────────────────────────────────

module SyncCatalogProductMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(
  SyncCatalogProduct,
)
module PlaceOrderMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(PlaceOrder)
module ShipOrderMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ShipOrder)
module CancelOrderMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(CancelOrder)

// publishJsons routing — dispatches each command to its registered StateChangeSlice handler.
let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmdJsons => {
  let _ = await cmdJsons
  ->Array.map(async cmdJson => {
    let typeName = switch cmdJson.commandJson {
    | JSON.Object(dict) =>
      dict
      ->Dict.get("TAG")
      ->Option.flatMap(j =>
        switch j {
        | JSON.String(s) => Some(s)
        | _ => None
        }
      )
      ->Option.getOr("")
    | _ => ""
    }
    let fullBody = JSON.Encode.object(
      Dict.fromArray([
        ("id", JSON.Encode.string(cmdJson.id)),
        ("meta", cmdJson.meta->S.reverseConvertToJsonOrThrow(Message.metaSchema)),
        ("command", cmdJson.commandJson),
      ]),
    )
    let handlers = ReventlessInMemory.CommandTopic.getHandlers(typeName)
    let _ = await handlers
    ->Array.map(async entry => {
      let item: ReventlessInfra.CommandTopic.topicItem<JSON.t> = {
        reference: cmdJson.id,
        command: fullBody,
      }
      let _ = await ReventlessInMemory.CommandTopic.callHandlerWithArray(entry.handler, [item])
    })
    ->Promise.all
  })
  ->Promise.all
}

let publishJsonsOutput = publishJsons->Pulumi.Output.make

let _syncCatalogProductSlice = SyncCatalogProductMaker.make(
  ~dcbEventLog=eventLog,
  ~publishJsons=publishJsonsOutput,
)
let _placeOrderSlice = PlaceOrderMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _shipOrderSlice = ShipOrderMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _cancelOrderSlice = CancelOrderMaker.make(
  ~dcbEventLog=eventLog,
  ~publishJsons=publishJsonsOutput,
)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "online-shop-hybrid-ordering-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let dispatch = async (commandJson, entityId) =>
  await publishJsons([{Message.id: entityId, meta: testMeta, commandJson}])

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("Ordering Hybrid E2E:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->OrderingEventLogMaker.operations->ReventlessInMemory.TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  // — CatalogProduct sync —

  testPromise("SyncCatalogProduct publishes 1 event", async () => {
    let cmd = SyncCatalogProduct.SyncNewProduct({
      productId: "prod-1",
      name: "Laptop",
      price: 999.99,
    })->Message.encode(SyncCatalogProduct.commandSchema)
    await dispatch(cmd, "prod-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("SyncCatalogProduct for prod-2", async () => {
    let cmd = SyncCatalogProduct.SyncNewProduct({
      productId: "prod-2",
      name: "Mouse",
      price: 29.99,
    })->Message.encode(SyncCatalogProduct.commandSchema)
    await dispatch(cmd, "prod-2")
    expect(capturedEventCount.contents)->toBe(1)
  })

  // — Order —

  testPromise("PlaceOrder with synced products publishes 1 event", async () => {
    let cmd = PlaceOrder.PlaceOrder({
      orderId: "ord-1",
      customerId: "cust-1",
      productId: ["prod-1", "prod-2"],
    })->Message.encode(PlaceOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate PlaceOrder produces 0 events (OrderAlreadyPlaced)", async () => {
    let cmd = PlaceOrder.PlaceOrder({
      orderId: "ord-1",
      customerId: "cust-1",
      productId: ["prod-1"],
    })->Message.encode(PlaceOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("ShipOrder on placed order publishes 1 event", async () => {
    let cmd = ShipOrder.ShipOrder({orderId: "ord-1"})->Message.encode(ShipOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate ShipOrder is idempotent (0 events)", async () => {
    let cmd = ShipOrder.ShipOrder({orderId: "ord-1"})->Message.encode(ShipOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("CancelOrder on non-existent order produces 0 events (OrderNotFound)", async () => {
    let cmd =
      CancelOrder.CancelOrder({orderId: "no-such-order"})->Message.encode(CancelOrder.commandSchema)
    await dispatch(cmd, "no-such-order")
    expect(capturedEventCount.contents)->toBe(0)
  })

  // — Cross-entity DCB decision model filtering (Step 3.2) —
  // PlaceOrder's multi-clause query fetches both Order events (via orderId tag)
  // AND CatalogProduct events (via productId tag). These tests verify that
  // the decision model correctly aggregates events across entity types.

  testPromise("PlaceOrder with un-synced product produces 0 events (ProductsNotAvailable)", async () => {
    let cmd = PlaceOrder.PlaceOrder({
      orderId: "ord-cross-1",
      customerId: "cust-1",
      productId: ["prod-1", "prod-UNSYNCED"],
    })->Message.encode(PlaceOrder.commandSchema)
    await dispatch(cmd, "ord-cross-1")
    // prod-UNSYNCED was never synced, so PlaceOrder rejects with ProductsNotAvailable
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("after syncing missing product, PlaceOrder succeeds", async () => {
    // Sync the previously missing product
    let syncCmd = SyncCatalogProduct.SyncNewProduct({
      productId: "prod-UNSYNCED",
      name: "Keyboard",
      price: 49.99,
    })->Message.encode(SyncCatalogProduct.commandSchema)
    await dispatch(syncCmd, "prod-UNSYNCED")
    expect(capturedEventCount.contents)->toBe(1)

    capturedEventCount := 0

    // Now PlaceOrder should succeed — multi-clause query fetches both
    // CatalogProductSynced events (prod-1 and prod-UNSYNCED)
    let cmd = PlaceOrder.PlaceOrder({
      orderId: "ord-cross-1",
      customerId: "cust-1",
      productId: ["prod-1", "prod-UNSYNCED"],
    })->Message.encode(PlaceOrder.commandSchema)
    await dispatch(cmd, "ord-cross-1")
    expect(capturedEventCount.contents)->toBe(1)
  })
})
