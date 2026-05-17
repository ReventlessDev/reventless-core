
// ─────────────────────────────────────────────────────────────
// Shared captures — reset in beforeEach
// ─────────────────────────────────────────────────────────────

let capturedCountCalls: ref<array<(Reventless.Id.StringPure.t, string, int)>> = ref([])
let capturedEventBatches: ref<array<array<JSON.t>>> = ref([])

// ─────────────────────────────────────────────────────────────
// Mock countsDbCount — records (id, field, delta) calls
// Returns Ok(0) by default (simulates count reaching 0 is handled
// via the 'counts' parameter, not the return value of countsDbCount)
// ─────────────────────────────────────────────────────────────

let mockCountsDbCount: QueryDb.count<string> = async (id, field, delta) => {
  capturedCountCalls :=
    capturedCountCalls.contents->Array.concat([(id->Reventless.Id.StringPure.toString, field, delta)])
  Ok(0)
}

// ─────────────────────────────────────────────────────────────
// Mock jsonEventsHandler — captures batches of event JSONs
// ─────────────────────────────────────────────────────────────

let mockJsonEventsHandler: Counter.jsonEventsHandler = stream =>
  stream
  ->Stream.runCollect
  ->Effect.map(chunk => {
    capturedEventBatches :=
      capturedEventBatches.contents->Array.concat([chunk])
  })

// ─────────────────────────────────────────────────────────────
// Counter_Callback spec and handler under test
// ─────────────────────────────────────────────────────────────

module TestCounterSpec: Counter_Callback.Spec = {
  let name = "TestCounter"
  let countsDbCount = mockCountsDbCount
  let jsonEventsHandler = mockJsonEventsHandler
}

module TestCounterHandler = Counter_Callback.Make(TestCounterSpec)

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

// Encode a countsState JSON (what the Lambda callback receives as ~counts)
let makeCountsJson = (id, count): JSON.t =>
  ({id, count}: Counter_Callback.countsState)->Message.encode(Counter_Callback.countsStateSchema)

let reset = () => {
  capturedCountCalls := []
  capturedEventBatches := []
}
