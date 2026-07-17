// Provider-neutral metric event emission.
//
// Emits one structured JSON line per occurrence — the same posture as `Logger`
// (generic structured stdout, no provider vocabulary). Core does NOT know about
// any provider's metric system: a collector/adapter turns these lines into real
// metrics. On AWS a CloudWatch metric filter (defined in `reventless-aws`,
// deploy-time) matches the discriminator field and extracts the `slice`
// dimension + value; another provider can match the same generic shape.
//
// Suppressed outside a JSON sink so TTY dev runs stay clean. Used by the DCB
// StateChangeSlice callback to surface append-retry / append-conflict rates per
// slice (see docs/analysis/dcb-high-contention-handling.md §6).

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

// Emits a single count for `metric`, dimensioned by `slice`. No-op outside a
// JSON sink. `value` defaults to 1 (one occurrence).
let emitCount = (~metric: string, ~slice: string, ~value: int=1): unit =>
  if Reventless.AnsiStyle.isJsonSink() {
    Console.log(metricLine(~metric, ~slice, ~value)->JSON.stringify)
  }
