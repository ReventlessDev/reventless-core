// End-to-end test for the Product aggregate using the in-memory platform.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open Reventless

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Topic name = Spec.name ++ "Aggr" ++ "EventTopic" = "ProductAggrEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("ProductAggrEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

let _ = ReventlessInMemory.TestRunner.setup()

module AggregateMaker = ReventlessInMemory.Aggregate_Builder.Make(Bus)
module ProductAgg = AggregateMaker.Make(
  Product,
  Product_Behavior,
  ReventlessInfra.NoEventMappings.Make(Product),
)

let agg = ProductAgg.make(~api=())

let testMeta: Message.meta = {
  service: "example-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

describe("Product E2E:", () => {
  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("Add command publishes 1 event to the event topic", async () => {
    let ops = await agg->ProductAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson = Product.Add({
      name: "Laptop",
      description: "A laptop",
      price: 999.99,
    })->Message.encode(Product.commandSchema)
    await ops.publishJsons([{Message.id: "prod-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("UpdateName on existing product publishes 1 event", async () => {
    let ops = await agg->ProductAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      Product.UpdateName({
        name: "Gaming Laptop",
      })->Message.encode(Product.commandSchema)
    await ops.publishJsons([{Message.id: "prod-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise(
    "duplicate Add for same id produces no events (ProductAlreadyExists error path)",
    async () => {
      let ops = await agg->ProductAgg.operations->ReventlessInMemory.TestRunner.resolve
      let commandJson = Product.Add({
        name: "Duplicate",
        description: "Dup",
        price: 1.0,
      })->Message.encode(Product.commandSchema)
      await ops.publishJsons([{Message.id: "prod-1", meta: testMeta, commandJson}])
      expect(capturedEventCount.contents)->toBe(0)
    },
  )
})
