// The local platform's metrics: counted in memory rather than written to the
// output, where nothing collects them locally, and served on the platform API
// (`Platform_Metrics`) and the MCP server (`platform/metrics`).

module Metrics = ReventlessCore.Metrics

let counts = Metrics.Counts.make()

/** Counts every metric from now on; installed when the platform module loads. */
let install = () => Metrics.Sink.install(Metrics.Counts.sink(counts))

let snapshotJson = (s: Metrics.Counts.snapshot): JSON.t =>
  Dict.fromArray([
    ("metric", JSON.Encode.string(s.metric)),
    ("plugin", JSON.Encode.string(s.plugin)),
    ("slice", JSON.Encode.string(s.slice)),
    ("unit", JSON.Encode.string(s.unit)),
    ("count", JSON.Encode.int(s.count)),
    ("sum", JSON.Encode.float(s.sum)),
    ("lastAt", JSON.Encode.string(s.lastAt->Date.fromTime->Date.toISOString)),
    ("perMinute", s.perMinute->Array.map(JSON.Encode.int)->JSON.Encode.array),
  ])->JSON.Encode.object

/** The counts now, of the given plugins or of every one. */
let read = (~plugins: option<array<string>>=?): JSON.t =>
  counts
  ->Metrics.Counts.read(~now=Date.now(), ~plugins?)
  ->Array.map(snapshotJson)
  ->JSON.Encode.array
