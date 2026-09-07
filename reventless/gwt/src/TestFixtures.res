let id = "id"
let meta = {
  Reventless.Message.service: "service",
  user: "ProjectionTest",
  ip: "ip",
  // A real instant, not the word: a projection stamping this into a `DateTime`
  // field writes it through that field's grammar, and `"time"` is not one.
  // Matches `StubRuntime.meta`, so the two harnesses agree on the producer clock.
  time: "1970-01-01T00:00:00Z",
  msgId: "msgId",
  correlationId: "correlationId",
}

// Deterministic storage timestamp for StateViewSlice projection envelopes
// (`consumed.recordedAt`). Distinct from `meta.time` (producer time) so a test
// projecting either clock asserts against an unambiguous fixed value.
let recordedAt = "recordedAt"

let context = {Reventless.Message.meta, id}

let statusChange = {
  Reventless.Message.at: context.meta.time,
  by: context.meta.user->Option.getOr(""),
}
