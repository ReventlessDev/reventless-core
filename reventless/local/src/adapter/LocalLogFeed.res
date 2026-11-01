// The local platform's recent log records, and the feed that serves them to a
// tool that did not start the platform and so cannot read its stdout.
//
// Two rings keep what was logged: the most recent records, and, separately, the
// most recent warnings and errors, so a problem outlives a busy minute. Both are
// bounded by count and by bytes. `REVENTLESS_LOG_RING` and
// `REVENTLESS_LOG_PROBLEM_RING` set them, as `<count>` or `<count>,<bytes>`;
// `0` keeps nothing.
//
// The feed is a `LocalFeed` on a loopback socket whose port the registry entry
// names as `logPort`. On connect it sends the rings, filtered, then each record
// as it is logged. A line is the record's JSON line, the one stdout prints with
// `REVENTLESS_LOG_FORMAT=json`. `REVENTLESS_LOG_FEED=off|<port>` controls it the
// way `REVENTLESS_EVENT_TAP` controls the tap.

module Logger = ReventlessCore.Logger

// ─── Rings ───────────────────────────────────────────────────────────────────

type entry = {
  // Arrival order across both rings, so a record kept by both is sent once.
  seq: int,
  record: Logger.record,
  item: LocalFeed.item,
}

type ring = {
  mutable maxCount: int,
  mutable maxBytes: int,
  mutable entries: array<entry>,
  mutable head: int,
  mutable bytes: int,
}

let makeRing = (~maxCount: int, ~maxBytes: int): ring => {
  maxCount,
  maxBytes,
  entries: [],
  head: 0,
  bytes: 0,
}

let size = (r: ring) => r.entries->Array.length - r.head

let entryBytes = (e: entry) => e.item.line->String.length

let push = (r: ring, e: entry) =>
  if r.maxCount > 0 && r.maxBytes > 0 {
    r.entries->Array.push(e)
    r.bytes = r.bytes + entryBytes(e)
    while size(r) > 0 && (size(r) > r.maxCount || r.bytes > r.maxBytes) {
      r.bytes = r.bytes - entryBytes(r.entries->Array.getUnsafe(r.head))
      r.head = r.head + 1
    }

    // Compact once the dropped prefix is most of the array.
    if r.head > 1024 && r.head * 2 > r.entries->Array.length {
      r.entries = r.entries->Array.slice(~start=r.head, ~end=r.entries->Array.length)
      r.head = 0
    }
  }

let toArray = (r: ring): array<entry> =>
  r.entries->Array.slice(~start=r.head, ~end=r.entries->Array.length)

let ringBytes = (r: ring) => r.bytes

let clear = (r: ring) => {
  r.entries = []
  r.head = 0
  r.bytes = 0
}

let ringEnvVar = "REVENTLESS_LOG_RING"
let problemRingEnvVar = "REVENTLESS_LOG_PROBLEM_RING"

/** `<count>` or `<count>,<bytes>`; anything else keeps the defaults. */
let boundsOf = (value: option<string>, ~count: int, ~bytes: int): (int, int) =>
  switch value->Option.map(v => v->String.trim->String.split(",")) {
  | Some([c]) => (c->String.trim->Int.fromString->Option.getOr(count), bytes)
  | Some([c, b]) => (
      c->String.trim->Int.fromString->Option.getOr(count),
      b->String.trim->Int.fromString->Option.getOr(bytes),
    )
  | _ => (count, bytes)
  }

let recent = makeRing(~maxCount=5_000, ~maxBytes=8 * 1024 * 1024)
let problems = makeRing(~maxCount=1_000, ~maxBytes=2 * 1024 * 1024)

let isProblem = (level: Logger.level) =>
  switch level {
  | Warn | Error => true
  | Debug | Info => false
  }

/** What both rings hold, oldest first, each record once. */
let snapshot = (): array<entry> => {
  let seen = Set.make()
  recent
  ->toArray
  ->Array.concat(problems->toArray)
  ->Array.filter(e =>
    if seen->Set.has(e.seq) {
      false
    } else {
      seen->Set.add(e.seq)
      true
    }
  )
  ->Array.toSorted((a, b) => (a.seq - b.seq)->Int.toFloat)
}

// ─── Records as feed lines ───────────────────────────────────────────────────

let facetsOf = (r: Logger.record): LocalFeed.facets => {
  plugin: ?r.plugin,
  level: r.level,
  comp: ?r.comp,
  correlationId: ?(r.annotations->Dict.get("correlationId")),
}

let itemOf = (r: Logger.record): LocalFeed.item => {
  line: r->Logger.recordToJson->JSON.stringify,
  facets: facetsOf(r),
}

/** The filter fields a log line can be narrowed by. Event types are about events
    and are ignored here. */
let honours: array<LocalFeed.filterField> = [Plugins, Level, Components, CorrelationId]

/** The recent records a filter selects, oldest first, at most `limit` (the most
    recent ones). */
let recentRecords = (~filter: LocalFeed.filter, ~limit: option<int>=?): array<Logger.record> => {
  let selected =
    snapshot()
    ->Array.filter(e => LocalFeed.matches(~honours, filter, e.item.facets))
    ->Array.map(e => e.record)
  switch limit {
  | Some(n) if n >= 0 && selected->Array.length > n =>
    selected->Array.slice(~start=selected->Array.length - n, ~end=selected->Array.length)
  | _ => selected
  }
}

// ─── The feed ────────────────────────────────────────────────────────────────

let envVar = "REVENTLESS_LOG_FEED"

let feed = LocalFeed.make(
  ~name="LogFeed",
  ~honours,
  ~backlog=() => snapshot()->Array.map(e => e.item),
  ~maxBytes=16 * 1024 * 1024,
  (),
)

let port = () => feed->LocalFeed.port
let hasReaders = () => feed->LocalFeed.hasReaders

let seq = ref(0)
let removeSink: ref<option<unit => unit>> = ref(None)

let onRecord = (record: Logger.record) => {
  seq := seq.contents + 1
  let entry = {seq: seq.contents, record, item: itemOf(record)}
  push(recent, entry)
  if isProblem(record.level) {
    push(problems, entry)
  }
  if hasReaders() {
    feed->LocalFeed.publish(entry.item)
  }
}

/** Starts keeping records, once per process: sizes the rings from the
    environment and registers the sink. */
let install = (~env=NodeProcess.env) => {
  let (c, b) = boundsOf(env->Dict.get(ringEnvVar), ~count=5_000, ~bytes=8 * 1024 * 1024)
  recent.maxCount = c
  recent.maxBytes = b
  let (pc, pb) = boundsOf(env->Dict.get(problemRingEnvVar), ~count=1_000, ~bytes=2 * 1024 * 1024)
  problems.maxCount = pc
  problems.maxBytes = pb
  switch removeSink.contents {
  | Some(_) => ()
  | None => removeSink := Some(Logger.addSink(onRecord))
  }
}

/** Binds the feed's socket and reports the port it got, once it is listening. */
let start = (~env=NodeProcess.env, ~onBound: int => unit=_ => (), ()): unit =>
  feed->LocalFeed.start(~setting=LocalFeed.settingOf(env->Dict.get(envVar)), ~onBound, ())

/** Test seam: removes the sink and empties the rings. */
let resetForTests = () => {
  removeSink.contents->Option.forEach(remove => remove())
  removeSink := None
  clear(recent)
  clear(problems)
  feed->LocalFeed.resetForTests
}

let stopForTests = () => feed->LocalFeed.stopForTests
