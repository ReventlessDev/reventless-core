// End-to-end test for the CatalogItem aggregate using the in-memory platform.
// Verifies the full command → event pipeline without any cloud infrastructure.
//
// Note: We use Aggregate_Builder.Make(Bus) directly (rather than CatalogItemPlugin.Make(Platform))
// so we can subscribe to the event bus and access the concrete api = unit type.
//
// Note on testPromise: @glennsl/rescript-jest's testPromise wraps the async callback in
// `() => { affirm(callback()); }` which discards the returned Promise, so Jest treats tests
// as synchronous and runs them concurrently. We use Reventless.AsyncTest instead, which
// binds directly to Jest's global `test` and `expect` and properly awaits async tests.
// See docs/fixes/rescript-jest-testpromise-async.md for the full explanation.

open Reventless.AsyncTest
open Reventless.AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Subscribe to the aggregate event topic before building the aggregate.
// Topic name = Spec.name ++ "Aggr" ++ "EventTopic" = "CatalogItemAggrEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("CatalogItemAggrEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = ReventlessInMemory.TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build the aggregate with the in-memory builder
// ─────────────────────────────────────────────────────────────

module AggregateMaker = ReventlessInMemory.Aggregate_Builder.Make(Bus)
module ItemAgg = AggregateMaker.Make(
  CatalogItem,
  CatalogItemBehavior,
  Reventless.NoEventMappings.Make(CatalogItem),
)

let agg = ItemAgg.make(~api=())

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: ReventlessSpec.Message.meta = {
  service: "example-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("CatalogItem E2E:", () => {
  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("CreateItem command publishes 1 event to the event topic", async () => {
    let ops = await agg->ItemAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      CatalogItem.CreateItem({itemId: "item-1", name: "Widget", description: "A widget"})
      ->Reventless.Message.encode(CatalogItem.commandSchema)
    await ops.publishJsons([
      {
        ReventlessSpec.Message.id: "item-1",
        meta: testMeta,
        commandJson,
      },
    ])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("UpdateItem on existing item publishes 1 event", async () => {
    // item-1 was created in a previous test run; state persists in the in-memory storage
    let ops = await agg->ItemAgg.operations->ReventlessInMemory.TestRunner.resolve
    let commandJson =
      CatalogItem.UpdateItem({
        itemId: "item-1",
        name: "Updated Widget",
        description: "An updated widget",
      })->Reventless.Message.encode(CatalogItem.commandSchema)
    await ops.publishJsons([
      {
        ReventlessSpec.Message.id: "item-1",
        meta: testMeta,
        commandJson,
      },
    ])
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise(
    "duplicate CreateItem for same id produces no events (ItemAlreadyExists error path)",
    async () => {
      // item-1 already exists from the first test — duplicate create is silently rejected
      let ops = await agg->ItemAgg.operations->ReventlessInMemory.TestRunner.resolve
      let commandJson =
        CatalogItem.CreateItem({itemId: "item-1", name: "Duplicate", description: "Dup"})
        ->Reventless.Message.encode(CatalogItem.commandSchema)
      await ops.publishJsons([
        {
          ReventlessSpec.Message.id: "item-1",
          meta: testMeta,
          commandJson,
        },
      ])
      expect(capturedEventCount.contents)->toBe(0)
    },
  )
})
