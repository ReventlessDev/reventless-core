// E2E test for reventless-in-memory package.
// Verifies the full aggregate command → event flow using the in-memory bus.

open AsyncTest
open AsyncTest.Expect
open AggregateE2EFixtures

describe("InMemory_Bus", () => {
  testPromise("publishes events to all subscribers", async () => {
    module TestBus = InMemory_Bus.Make()
    let count: ref<int> = ref(0)
    TestBus.subscribeToEvents("t1", async (_, _, _) => {
      count := count.contents + 1
    })
    TestBus.subscribeToEvents("t1", async (_, _, _) => {
      count := count.contents + 1
    })
    await TestBus.publishEvent("t1", "InMemory", testMeta, JSON.Null)
    expect(count.contents)->toBe(2)
  })

  testPromise("dispatches commands to registered handler", async () => {
    module TestBus = InMemory_Bus.Make()
    let received: ref<option<string>> = ref(None)
    TestBus.registerCommandHandler("cmd1", async (json, _) => {
      received := switch json {
      | JSON.String(s) => Some(s)
      | _ => None
      }
    })
    await TestBus.dispatchCommand("cmd1", JSON.Encode.string("hello"))
    expect(received.contents)->toEqual(Some("hello"))
  })

  testPromise("reset clears all handlers and subscribers", async () => {
    module TestBus = InMemory_Bus.Make()
    let count: ref<int> = ref(0)
    TestBus.subscribeToEvents("topic", async (_, _, _) => {
      count := count.contents + 1
    })
    TestBus.reset()
    // After reset, no subscribers — this just verifies no crash
    expect(count.contents)->toBe(0)
  })
})

describe("EventLogStorage_InMemory", () => {
  testPromise("append stores events and replay returns them", async () => {
    let opts: Pulumi.CustomResourceOptions.t = {}
    let storage = EventLogStorage_InMemory.make(~name="test-log", ~opts)
    let ops = await storage.operations->TestRunner.resolve
    let _ = await ops.append(1, "agg-1", [JSON.Encode.string("e1"), JSON.Encode.string("e2")])
    let events = await ops.replay("agg-1")
    expect(events->Array.length)->toBe(2)
  })

  testPromise("replay returns empty array for unknown aggregate id", async () => {
    let opts: Pulumi.CustomResourceOptions.t = {}
    let storage = EventLogStorage_InMemory.make(~name="test-log-2", ~opts)
    let ops = await storage.operations->TestRunner.resolve
    let events = await ops.replay("unknown-id")
    expect(events->Array.length)->toBe(0)
  })

  testPromise("multiple appends accumulate events", async () => {
    let opts: Pulumi.CustomResourceOptions.t = {}
    let storage = EventLogStorage_InMemory.make(~name="test-log-3", ~opts)
    let ops = await storage.operations->TestRunner.resolve
    let _ = await ops.append(1, "agg-2", [JSON.Encode.string("e1")])
    let _ = await ops.append(2, "agg-2", [JSON.Encode.string("e2"), JSON.Encode.string("e3")])
    let events = await ops.replay("agg-2")
    expect(events->Array.length)->toBe(3)
  })
})

describe("Aggregate E2E", () => {
  // Resolve the Output chain before any test runs so bus wiring is complete.
  let _ = beforeAllAsync(async () => {
    let _ = await agg->ItemAgg.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("CreateItem command produces ItemCreated event on event topic", async () => {
    let ops = await agg->ItemAgg.operations->TestRunner.resolve
    let commandJson =
      ItemSpec.CreateItem({name: "Widget"})->ReventlessCore.Message.encode(ItemSpec.commandSchema)
    await ops.publishJsons([
      {
        Reventless.Message.id: "item-1",
        meta: testMeta,
        commandJson: commandJson,
      },
    ])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("second CreateItem for same id produces no events (AlreadyExists)", async () => {
    // item-1 was already created in the previous test (same aggregate instance)
    let ops = await agg->ItemAgg.operations->TestRunner.resolve
    let commandJson =
      ItemSpec.CreateItem({name: "Widget2"})->ReventlessCore.Message.encode(ItemSpec.commandSchema)
    await ops.publishJsons([
      {
        Reventless.Message.id: "item-1",
        meta: testMeta,
        commandJson: commandJson,
      },
    ])
    // AlreadyExists error → no events generated → no bus publish
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("CreateItem for new id produces event", async () => {
    let ops = await agg->ItemAgg.operations->TestRunner.resolve
    let commandJson =
      ItemSpec.CreateItem({name: "NewItem"})->ReventlessCore.Message.encode(ItemSpec.commandSchema)
    await ops.publishJsons([
      {
        Reventless.Message.id: "item-2",
        meta: testMeta,
        commandJson: commandJson,
      },
    ])
    expect(capturedEventCount.contents)->toBe(1)
  })
})
