// End-to-end test for the Customer aggregate using the in-memory platform.

open ReventlessInMemory.AsyncTest
open ReventlessInMemory.AsyncTest.Expect
open Reventless

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Topic name = Spec.name ++ "Aggr" ++ "EventTopic" = "CustomerAggrEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("CustomerAggrEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

let _ = ReventlessInMemory.TestRunner.setup()

module AggregateMaker = ReventlessInMemory.Aggregate_Builder.Make(Bus)
module CustomerAgg = AggregateMaker.Make(
  Customer,
  CustomerBehavior,
  ReventlessInfra.NoEventMappings.Make(Customer),
)

let agg = CustomerAgg.make(~api=())

let testMeta: Message.meta = {
  service: "example-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

describe("Customer E2E:", () => {
  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("Register command publishes 1 event to the event topic", async () => {
    let ops = await agg->CustomerAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson = Customer.Register({
      email: "alice@example.com",
      address: "123 Main St",
    })->Message.encode(Customer.commandSchema)
    await ops.publishJsons([{Message.id: "cust-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("UpdateEmail on existing customer publishes 1 event", async () => {
    let ops = await agg->CustomerAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      Customer.UpdateEmail({
        email: "alice2@example.com",
      })->Message.encode(Customer.commandSchema)
    await ops.publishJsons([{Message.id: "cust-1", meta: testMeta, commandJson}])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise(
    "duplicate Register for same id produces no events (CustomerAlreadyRegistered error path)",
    async () => {
      let ops = await agg->CustomerAgg.operations->ReventlessInMemory.TestRunner.resolve
      let commandJson = Customer.Register({
        email: "duplicate@example.com",
        address: "Dup",
      })->Message.encode(Customer.commandSchema)
      await ops.publishJsons([{Message.id: "cust-1", meta: testMeta, commandJson}])
      expect(capturedEventCount.contents)->toBe(0)
    },
  )
})
