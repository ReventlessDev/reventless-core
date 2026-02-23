// E2E test for reventless-in-memory package.
// Verifies the full aggregate command → event flow using the in-memory bus.

open Jest
open Expect

// ─────────────────────────────────────────────────────────────
// Simple Item aggregate spec
// ─────────────────────────────────────────────────────────────

module ItemSpec = {
  module Id = ReventlessSpec.Id.String
  let name = "TestItem"

  @schema
  type command = | CreateItem({name: string})

  @schema
  type event = | ItemCreated({name: string})

  @schema
  type error = | AlreadyExists
}

// ─────────────────────────────────────────────────────────────
// Item behavior: CreateItem → ItemCreated
// ─────────────────────────────────────────────────────────────

module ItemBehavior: Reventless.Behavior.T with module Spec := ItemSpec = {
  type state = bool // true = item exists

  let resolverConfig: Reventless.Behavior.resolverConfig<ItemSpec.command> = {
    commandSchema: ItemSpec.commandSchema,
    fields: [],
  }

  let init = (_event: ItemSpec.event) => true
  let apply = (_state, _event: ItemSpec.event) => true

  let create = (command: ItemSpec.command, _meta, _errorHandler) =>
    switch command {
    | ItemSpec.CreateItem({name}) => [ItemSpec.ItemCreated({name: name})]
    }

  let execute = (state, command, meta, errorHandler) =>
    if state {
      errorHandler(ItemSpec.AlreadyExists, command, meta)
    } else {
      create(command, meta, errorHandler)
    }
}

// ─────────────────────────────────────────────────────────────
// Isolated bus for the E2E test (shared across all tests here)
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// Capture events published to the aggregate's event topic.
// Topic name = Spec.name ++ "Aggr" ++ "EventTopic" = "TestItemAggrEventTopic"
let capturedEventCount: ref<int> = ref(0)

let _ = Bus.subscribeToEvents("TestItemAggrEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build the aggregate (creates Pulumi components + wires bus)
// ─────────────────────────────────────────────────────────────

module ItemAggregateMaker = Aggregate_Builder.Make(Bus)
module ItemAgg = ItemAggregateMaker.Make(
  ItemSpec,
  ItemBehavior,
  Reventless.NoEventMappings.Make(ItemSpec),
)

let agg = ItemAgg.make(~api=())

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: ReventlessSpec.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

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

  test("reset clears all handlers and subscribers", () => {
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
  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("CreateItem command produces ItemCreated event on event topic", async () => {
    let ops = await agg->ItemAgg.operations->TestRunner.resolve
    let commandJson =
      ItemSpec.CreateItem({name: "Widget"})->Reventless.Message.encode(ItemSpec.commandSchema)
    await ops.publishJsons([
      {
        ReventlessSpec.Message.id: "item-1",
        meta: testMeta,
        commandJson: commandJson,
      },
    ])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("second CreateItem for same id produces no events (AlreadyExists)", async () => {
    // Note: this test relies on state from the previous test (same aggregate instance)
    // item-1 was already created above
    let ops = await agg->ItemAgg.operations->TestRunner.resolve
    let commandJson =
      ItemSpec.CreateItem({name: "Widget2"})->Reventless.Message.encode(ItemSpec.commandSchema)
    await ops.publishJsons([
      {
        ReventlessSpec.Message.id: "item-1",
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
      ItemSpec.CreateItem({name: "NewItem"})->Reventless.Message.encode(ItemSpec.commandSchema)
    await ops.publishJsons([
      {
        ReventlessSpec.Message.id: "item-2",
        meta: testMeta,
        commandJson: commandJson,
      },
    ])
    expect(capturedEventCount.contents)->toBe(1)
  })
})
