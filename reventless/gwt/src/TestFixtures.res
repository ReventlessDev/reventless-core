let id = "id"
let meta = {
  Reventless.Message.service: "service",
  user: "ProjectionTest",
  ip: "ip",
  time: "time",
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
