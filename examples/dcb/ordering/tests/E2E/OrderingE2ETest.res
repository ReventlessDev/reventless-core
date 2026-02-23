// End-to-end test for the OrderingPlugin DCB using the in-memory platform.
// Verifies the full command → DCB event log → event topic pipeline for both
// Customer and Order entities without any cloud infrastructure.

open Reventless.AsyncTest
open Reventless.AsyncTest.Expect

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
// Build DcbEventLog
// ─────────────────────────────────────────────────────────────

module DcbEventLogMaker = ReventlessInMemory.DcbEventLog_Builder.Make(Bus)
module OrderingEventLogMaker = DcbEventLogMaker.Make(OrderingEventLog)
let eventLog = OrderingEventLogMaker.make(~name="Ordering")

// ─────────────────────────────────────────────────────────────
// Build StateChangeSlices
// ─────────────────────────────────────────────────────────────

module RegisterCustomerMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(RegisterCustomer)
module UpdateEmailMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(UpdateEmail)
module UpdateAddressMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(UpdateAddress)
module DeactivateCustomerMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(DeactivateCustomer)
module PlaceOrderMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(PlaceOrder)
module ShipOrderMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ShipOrder)
module CancelOrderMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(CancelOrder)

// publishJsons routing — dispatches each command to its registered StateChangeSlice handler.
let publishJsons: ReventlessSpec.CommandTopic.publishJsons = async cmdJsons => {
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
        ("meta", cmdJson.meta->S.reverseConvertToJsonOrThrow(ReventlessSpec.Message.metaSchema)),
        ("command", cmdJson.commandJson),
      ]),
    )
    let handlers = Reventless.CommandTopic.getHandlers(typeName)
    let _ = await handlers
    ->Array.map(async entry => {
      let _ = await entry.handler([
        {ReventlessSpec.CommandTopic.reference: cmdJson.id, command: fullBody},
      ])
    })
    ->Promise.all
  })
  ->Promise.all
}

let publishJsonsOutput = publishJsons->Pulumi.Output.make

let _registerCustomerSlice =
  RegisterCustomerMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _updateEmailSlice =
  UpdateEmailMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _updateAddressSlice =
  UpdateAddressMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _deactivateCustomerSlice =
  DeactivateCustomerMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _placeOrderSlice = PlaceOrderMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _shipOrderSlice = ShipOrderMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _cancelOrderSlice =
  CancelOrderMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: ReventlessSpec.Message.meta = {
  service: "example-dcb-ordering-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let dispatch = async (commandJson, entityId) =>
  await publishJsons([{ReventlessSpec.Message.id: entityId, meta: testMeta, commandJson}])

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("Ordering DCB E2E:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->Reventless.Component.operations->ReventlessInMemory.TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  // — Customer —

  testPromise("RegisterCustomer publishes 1 event", async () => {
    let cmd =
      RegisterCustomer.RegisterCustomer({
        customerId: "cust-1",
        email: "alice@example.com",
        address: "123 Main St",
      })->Reventless.Message.encode(RegisterCustomer.commandSchema)
    await dispatch(cmd, "cust-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate RegisterCustomer produces 0 events (CustomerAlreadyRegistered)", async () => {
    let cmd =
      RegisterCustomer.RegisterCustomer({
        customerId: "cust-1",
        email: "duplicate@example.com",
        address: "Dup",
      })->Reventless.Message.encode(RegisterCustomer.commandSchema)
    await dispatch(cmd, "cust-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("UpdateEmail on existing customer publishes 1 event", async () => {
    let cmd =
      UpdateEmail.UpdateEmail({customerId: "cust-1", email: "alice2@example.com"})
      ->Reventless.Message.encode(UpdateEmail.commandSchema)
    await dispatch(cmd, "cust-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("DeactivateCustomer publishes 1 event", async () => {
    let cmd =
      DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"})
      ->Reventless.Message.encode(DeactivateCustomer.commandSchema)
    await dispatch(cmd, "cust-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate DeactivateCustomer is idempotent (0 events)", async () => {
    let cmd =
      DeactivateCustomer.DeactivateCustomer({customerId: "cust-1"})
      ->Reventless.Message.encode(DeactivateCustomer.commandSchema)
    await dispatch(cmd, "cust-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  // — Order —

  testPromise("PlaceOrder publishes 1 event", async () => {
    let cmd =
      PlaceOrder.PlaceOrder({
        orderId: "ord-1",
        customerId: "cust-1",
        productIds: ["prod-1", "prod-2"],
      })->Reventless.Message.encode(PlaceOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate PlaceOrder produces 0 events (OrderAlreadyPlaced)", async () => {
    let cmd =
      PlaceOrder.PlaceOrder({
        orderId: "ord-1",
        customerId: "cust-1",
        productIds: ["prod-1"],
      })->Reventless.Message.encode(PlaceOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("ShipOrder on placed order publishes 1 event", async () => {
    let cmd =
      ShipOrder.ShipOrder({orderId: "ord-1"})->Reventless.Message.encode(ShipOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate ShipOrder is idempotent (0 events)", async () => {
    let cmd =
      ShipOrder.ShipOrder({orderId: "ord-1"})->Reventless.Message.encode(ShipOrder.commandSchema)
    await dispatch(cmd, "ord-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("CancelOrder on non-existent order produces 0 events (OrderNotFound)", async () => {
    let cmd =
      CancelOrder.CancelOrder({orderId: "no-such-order"})
      ->Reventless.Message.encode(CancelOrder.commandSchema)
    await dispatch(cmd, "no-such-order")
    expect(capturedEventCount.contents)->toBe(0)
  })
})
