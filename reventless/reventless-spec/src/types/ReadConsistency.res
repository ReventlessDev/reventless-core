// Per-slice decision-read consistency mode for DCB StateChangeSlices.
//
// Controls how a slice's decision-model read (the conditional read that
// rebuilds `state` before `decide`) chooses DynamoDB read consistency across
// the optimistic-concurrency retry loop in `StateChangeSlice_Callback`.
//
// Correctness is identical in every mode. A DynamoDB conditional write is
// always evaluated against the latest committed data, so a stale (eventually
// consistent) read can only ever cause a *rejected* append — which the retry
// loop re-reads and resolves — never a wrong write. Strong reads are therefore
// purely a cost/latency lever against the *replica-lag* class of conflicts;
// they do nothing for genuine concurrent-writer conflicts (those serialize at
// the fence regardless). See `docs/analysis/dcb-high-contention-handling.md`.
//
// The variant ships with three cases; further cases can be added without
// breaking existing `@@reventless.consistency(...)` declarations.

@schema
type t =
  | // Default: eventual read on the first attempt (cheaper RCU), then strong on
  // every retry so a replica-lag conflict self-heals deterministically instead
  // of burning further retries.
  EscalateOnRetry
  | // Always strong. For known-hot slices where replica-lag conflicts dominate
  // and the first eventual read is not worth the wasted attempt.
  AlwaysStrong
  | // Always eventual, even on retry. For very cost-sensitive, low-contention
  // slices that never want to pay strong-read RCU.
  AlwaysEventual

let default = EscalateOnRetry

let toString = (v: t) =>
  switch v {
  | EscalateOnRetry => "EscalateOnRetry"
  | AlwaysStrong => "AlwaysStrong"
  | AlwaysEventual => "AlwaysEventual"
  }
