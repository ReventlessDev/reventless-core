// In-memory "appended but not yet fully published" tracker backing the SQLite
// projection checkpoint (see ProjectionCheckpoint.res).
//
// EventLogStorage_Sqlite registers each appended batch here (msgId → event_log
// rowid) the moment the insert transaction commits; Platform's afterPublish hook
// resolves the batch once `Bus.publishEvent` has returned — i.e. after every
// subscriber (including all projections) has processed the events. The gap
// between the two is exactly the crash window a checkpoint must not advance
// over: `minPending() - 1` is the highest position provably fully projected.
//
// Tracking is off by default so bare storage construction (tests, tools) never
// accumulates entries nobody resolves; Platform enables it for the SQLite
// backend only. State is module-level — one platform per process, same as the
// LocalBus registries.

let enabled = ref(false)
let pendingByMsgId: dict<int> = Dict.make()

let enableTracking = () => enabled := true

let trackAppended = (entries: array<(string, int)>) =>
  if enabled.contents {
    entries->Array.forEach(((msgId, rowid)) => pendingByMsgId->Dict.set(msgId, rowid))
  }

let resolve = (msgIds: array<string>) =>
  msgIds->Array.forEach(msgId => pendingByMsgId->Dict.delete(msgId))

// Lowest still-pending position, or None when every tracked append has
// completed its publish cycle.
let minPending = (): option<int> => {
  let positions = pendingByMsgId->Dict.valuesToArray
  switch positions->Array.get(0) {
  | None => None
  | Some(first) => Some(positions->Array.reduce(first, (a, b) => a < b ? a : b))
  }
}

// Test isolation: clears state AND disables tracking (the default).
let reset = () => {
  enabled := false
  pendingByMsgId->Dict.keysToArray->Array.forEach(k => pendingByMsgId->Dict.delete(k))
}
