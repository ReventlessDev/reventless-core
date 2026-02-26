// E2E test fixtures for Counter builder.
// Verifies addToCounterTarget (in-memory deduplication) and count (ReferencesDb save).

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build Counter
// counterEventsHandler fires when a count reaches zero;
// capture events for assertion.
// ─────────────────────────────────────────────────────────────

module CounterMaker = Counter_Builder.Make(Bus)

let counterEvents: ref<array<JSON.t>> = ref([])

let counter = CounterMaker.make(
  ~name="TestCounter",
  ~counterEventsHandler=async events => {
    counterEvents := counterEvents.contents->Array.concat(events)
  },
)

// ─────────────────────────────────────────────────────────────
// Resolve counter operations.
// Counter.T only exposes `make` and abstract `component` —
// use Obj.magic to access the underlying Component.operations.
// ─────────────────────────────────────────────────────────────

let resolveOps = async () => {
  let c: Reventless.Counter.component = counter->Obj.magic
  await c->Reventless.Component.operations->TestRunner.resolve
}
