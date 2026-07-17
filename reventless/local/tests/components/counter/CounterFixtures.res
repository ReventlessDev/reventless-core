// E2E test fixtures for Counter builder.
// Verifies addToCounterTarget (in-memory deduplication) and count (ReferencesDb save).

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build Counter
// jsonEventsHandler fires when a count reaches zero;
// capture events for assertion.
// ─────────────────────────────────────────────────────────────

module CounterMaker = Counter_Builder.Make(Bus)

let counterEvents: ref<array<JSON.t>> = ref([])

let counter = CounterMaker.make(
  ~name="TestCounter",
  ~jsonEventsHandler=stream =>
    stream
    ->Stream.runCollect
    ->Effect.map(chunk => {
      counterEvents := counterEvents.contents->Array.concat(chunk)
    }),
)

// ─────────────────────────────────────────────────────────────
// Resolve counter operations.
// ─────────────────────────────────────────────────────────────

let resolveOps = async () => {
  await CounterMaker.operations(counter)->TestRunner.resolve
}
