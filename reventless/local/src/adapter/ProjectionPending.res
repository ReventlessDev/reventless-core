// In-memory "appended but not yet fully published" tracker backing the SQLite
// projection checkpoint (see ProjectionCheckpoint.res).
//
// The storage adapters register each appended batch here (msgId → global
// position) the moment the insert transaction commits; Platform's afterPublish
// hook resolves the batch once `Bus.publishEvent` has returned — i.e. after
// every subscriber (including all projections) has processed the events. The
// gap between the two is exactly the crash window a checkpoint must not
// advance over: `minPending(axis) - 1` is the highest position provably fully
// projected on that axis.
//
// Two independent position axes exist, because the two persisted logs have
// unrelated global sequences (each uses its own table's rowid):
//   Aggregate — event_log   (aggregate EventLogs → ReadModel projections)
//   Dcb       — dcb_event   (DCB slice events → StateViewSlice projections)
// msgIds are globally unique, so resolution needs no axis; each entry just
// remembers which axis its position belongs to.
//
// Tracking is off by default so bare storage construction (tests, tools) never
// accumulates entries nobody resolves; Platform enables it for the SQLite
// backend only. State is module-level — one platform per process, same as the
// LocalBus registries.

type axis =
  | Aggregate
  | Dcb

let enabled = ref(false)
let pendingByMsgId: dict<(axis, int)> = Dict.make()

let enableTracking = () => enabled := true

let trackAppended = (~axis: axis, entries: array<(string, int)>) =>
  if enabled.contents {
    entries->Array.forEach(((msgId, position)) =>
      pendingByMsgId->Dict.set(msgId, (axis, position))
    )
  }

let resolve = (msgIds: array<string>) =>
  msgIds->Array.forEach(msgId => pendingByMsgId->Dict.delete(msgId))

// Lowest still-pending position on the given axis, or None when every tracked
// append on that axis has completed its publish cycle.
let minPending = (axis: axis): option<int> => {
  let positions =
    pendingByMsgId
    ->Dict.valuesToArray
    ->Array.filterMap(((a, p)) => a == axis ? Some(p) : None)
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
