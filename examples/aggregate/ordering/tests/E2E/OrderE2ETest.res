// End-to-end test for the Order aggregate using the in-memory platform.

open Reventless.AsyncTest
open Reventless.AsyncTest.Expect
open ReventlessSpec

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Topic name = Spec.name ++ "Aggr" ++ "EventTopic" = "OrderAggrEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("OrderAggrEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

let _ = ReventlessInMemory.TestRunner.setup()

module AggregateMaker = ReventlessInMemory.Aggregate_Builder.Make(Bus)
module OrderAgg = AggregateMaker.Make(Order, OrderBehavior, Reventless.NoEventMappings.Make(Order))

let agg = OrderAgg.make(~api=())

let testMeta: Message.meta = {
  service: "example-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

describe("Order E2E:", () => {
  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("PlaceOrder command publishes 1 event to the event topic", async () => {
    let ops = await agg->OrderAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      Order.PlaceOrder({
        orderId: "ord-1",
        customerId: "cust-1",
        productIds: ["prod-1"],
      })->Reventless.Message.encode(Order.commandSchema)
    await ops.publishJsons([{Message.id: "ord-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("ShipOrder on placed order publishes 1 event", async () => {
    let ops = await agg->OrderAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      Order.ShipOrder({orderId: "ord-1"})->Reventless.Message.encode(Order.commandSchema)
    await ops.publishJsons([{Message.id: "ord-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise(
    "duplicate PlaceOrder for same id produces no events (OrderAlreadyPlaced error path)",
    async () => {
      let ops = await agg->OrderAgg.operations->ReventlessInMemory.TestRunner.resolve
      let commandJson =
        Order.PlaceOrder({
          orderId: "ord-1",
          customerId: "cust-1",
          productIds: ["prod-1"],
        })->Reventless.Message.encode(Order.commandSchema)
      await ops.publishJsons([{Message.id: "ord-1", meta: testMeta, commandJson}])
      expect(capturedEventCount.contents)->toBe(0)
    },
  )
})
