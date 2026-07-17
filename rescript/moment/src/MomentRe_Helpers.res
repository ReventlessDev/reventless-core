let momentWithUnix = (timestamp: int) =>
  MomentRe.momentWithTimestampMS(Int.toFloat(timestamp) *. 1000.0)

let momentUtc = (~format=?, value) =>
  switch format {
  | Some(f) => MomentRe.momentUtcWithFormats(value, f)
  | None => MomentRe.momentUtcDefaultFormat(value)
  }

let moment = (~format=?, value) =>
  switch format {
  | Some(f) => MomentRe.momentWithFormats(value, f)
  | None => MomentRe.momentDefaultFormat(value)
  }
