// Provider-neutral metric emission. `emitCount` is the one call that emits a
// metric; where the count goes is the installed `Sink`. The default writes one
// JSON line per occurrence to a JSON log sink, which a deployed collector turns
// into a metric (on AWS a CloudWatch metric filter keys on `reventlessMetric`). A
// local platform installs `Counts.sink` instead: it counts in memory and writes
// nothing. See docs/plans/metrics-are-counted-not-logged.md.

// Discriminator key a metric collector keys off. Stable — changing it is a
// breaking change for any configured metric filter.
let discriminator = "reventlessMetric"

// Builds the generic metric line. Pure, so the shape is unit-testable.
let metricLine = (~metric: string, ~slice: string, ~value: int=1): JSON.t =>
  Dict.fromArray([
    (discriminator, metric->JSON.Encode.string),
    ("slice", slice->JSON.Encode.string),
    ("value", value->JSON.Encode.int),
    ("unit", "Count"->JSON.Encode.string),
  ])->JSON.Encode.object

/** One occurrence of a metric, as a sink receives it. */
type sample = {
  metric: string,
  slice: string,
  /** The plugin the slice belongs to, when the registry knows it. */
  plugin?: string,
  value: int,
  unit: string,
  /** In milliseconds since 1970. */
  at: float,
}

module Sink = {
  type t = sample => unit

  /** The line a deployed collector reads, written only to a JSON log sink. */
  let line: t = s =>
    if Reventless.AnsiStyle.isJsonSink() {
      Console.log(metricLine(~metric=s.metric, ~slice=s.slice, ~value=s.value)->JSON.stringify)
    }

  let current: ref<t> = ref(line)

  /** Where every metric goes from now on, installed at a process's start. */
  let install = (sink: t) => current := sink

  /** Back to the line: for tests. */
  let reset = () => current := line
}

// Emits a single count for `metric`, dimensioned by `slice`. `value` defaults to
// 1 (one occurrence).
let emitCount = (~metric: string, ~slice: string, ~value: int=1): unit =>
  Sink.current.contents({
    metric,
    slice,
    plugin: ?Reventless.LogPrefix.lookup(slice),
    value,
    unit: "Count",
    at: Date.now(),
  })

/** Metrics counted in memory, per metric, plugin and slice: how often, the sum of
    their values, the last time, and how many in each of the last 60 minutes. Bounded
    by the number of slices, not of commands. */
module Counts = {
  let minutes = 60
  let minuteMs = 60_000.

  type entry = {
    metric: string,
    plugin: string,
    slice: string,
    unit: string,
    mutable count: int,
    mutable sum: float,
    mutable lastAt: float,
    /** The counts of the last `minutes` minutes, oldest first; the last is `minute`'s. */
    mutable perMinute: array<int>,
    mutable minute: float,
  }

  type t = {entries: dict<entry>}

  /** One count as a reader gets it. */
  type snapshot = {
    metric: string,
    plugin: string,
    slice: string,
    unit: string,
    count: int,
    sum: float,
    lastAt: float,
    perMinute: array<int>,
  }

  let make = (): t => {entries: Dict.make()}

  let clear = (t: t) => t.entries->Dict.keysToArray->Array.forEach(k => t.entries->Dict.delete(k))

  let minuteOf = (at: float) => Math.floor(at /. minuteMs)

  /** The buckets moved on to `minute`: the minutes since the last count are zero. */
  let rolled = (perMinute: array<int>, ~from: float, ~to_: float): array<int> => {
    let gap = Math.Int.min(minutes, (to_ -. from)->Float.toInt)
    gap <= 0
      ? perMinute
      : perMinute
        ->Array.slice(~start=gap, ~end=minutes)
        ->Array.concat(Array.make(~length=gap, 0))
  }

  let add = (t: t, s: sample) => {
    let plugin = s.plugin->Option.getOr("")
    let key = `${s.metric}|${plugin}|${s.slice}`
    let minute = minuteOf(s.at)
    let e = switch t.entries->Dict.get(key) {
    | Some(e) => e
    | None =>
      let e = {
        metric: s.metric,
        plugin,
        slice: s.slice,
        unit: s.unit,
        count: 0,
        sum: 0.,
        lastAt: s.at,
        perMinute: Array.make(~length=minutes, 0),
        minute,
      }
      t.entries->Dict.set(key, e)
      e
    }
    e.perMinute = rolled(e.perMinute, ~from=e.minute, ~to_=minute)
    e.minute = Math.max(e.minute, minute)
    let last = minutes - 1
    e.perMinute->Array.setUnsafe(last, e.perMinute->Array.getUnsafe(last) + 1)
    e.count = e.count + 1
    e.sum = e.sum +. s.value->Int.toFloat
    e.lastAt = Math.max(e.lastAt, s.at)
  }

  /** The sink that counts into `t` and writes nothing. */
  let sink = (t: t): Sink.t => s => add(t, s)

  /** The counts at `now`, of the given plugins or of every one, ordered by plugin,
      slice and metric. */
  let read = (t: t, ~now: float, ~plugins: option<array<string>>=?): array<snapshot> =>
    t.entries
    ->Dict.valuesToArray
    ->Array.filter(e => plugins->Option.mapOr(true, ps => ps->Array.includes(e.plugin)))
    ->Array.map((e): snapshot => {
      metric: e.metric,
      plugin: e.plugin,
      slice: e.slice,
      unit: e.unit,
      count: e.count,
      sum: e.sum,
      lastAt: e.lastAt,
      perMinute: rolled(e.perMinute, ~from=e.minute, ~to_=minuteOf(now)),
    })
    ->Array.toSorted((a, b) =>
      `${a.plugin}|${a.slice}|${a.metric}`->String.localeCompare(
        `${b.plugin}|${b.slice}|${b.metric}`,
      )
    )
}
