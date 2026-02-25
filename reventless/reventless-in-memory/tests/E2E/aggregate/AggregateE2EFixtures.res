// E2E test fixtures for the Aggregate E2E test.
// Contains specs, behavior, bus setup, and shared test data.

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
  ReventlessSpec.NoEventMappings.Make(ItemSpec),
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
