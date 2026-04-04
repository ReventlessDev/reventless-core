// Compact Effect logger — delegates to Logger.emit for format.
//
// Two responsibilities:
//   1. install() — replaces Effect's default logger (timestamp=/level=/fiber=)
//      with Logger.emit so all Effect.runPromise/runSync calls use the unified format.
//   2. logInfo/logWarn/logError/logDebug — structured helpers with ~comp and ~detail
//      that return Effect.t<unit> for use in Effect pipelines.
//
// ~detail: structured JSON shown only in CloudWatch (expandable on click).
//   Encoded as message\x00{json} in the Effect log string; decoded by install().
//
// Usage: import at platform startup (module init calls install()).
//   EffectLogger.logInfo(~comp=`Aggregate(${Spec.name})`, ~detail=eventJson, "replay done")

type loggerOptions
type logLevel

@get external _message: loggerOptions => array<string> = "message"
@get external _logLevel: loggerOptions => logLevel = "logLevel"
@get external _ordinal: logLevel => int = "ordinal"

type effectLogger = {mutable log: loggerOptions => unit}

@module("effect/Logger")
external _defaultLogger: effectLogger = "defaultLogger"

let ordinalToLevel = ordinal =>
  if ordinal >= 40000 {
    Logger.Error
  } else if ordinal >= 30000 {
    Logger.Warn
  } else if ordinal >= 20000 {
    Logger.Info
  } else {
    Logger.Debug
  }

let install = () =>
  _defaultLogger.log = opts => {
    let raw = opts->_message->Array.join(" ")
    let level = opts->_logLevel->_ordinal->ordinalToLevel
    // Split on null-byte separator: "message\x00{detail json}"
    let idx = raw->String.indexOf(Logger.detailSeparator)
    if idx >= 0 {
      let msg = raw->String.slice(~start=0, ~end=idx)
      let detailStr = raw->String.slice(~start=idx + 1, ~end=raw->String.length)
      let detail = try Some(detailStr->JSON.parseOrThrow) catch {
      | _ => None
      }
      Logger.emit(~level, ~detail?, msg)
    } else {
      Logger.emit(~level, raw)
    }
  }

// Self-installing: runs at module initialization time.
install()

// ─── Structured log helpers ──────────────────────────────────────────────────
// Returns Effect.t<unit> — usable in Effect pipelines or with ->Effect.runSync.
//
// ~detail: structured JSON data — shown only in CloudWatch (expandable on click).
//   In-memory terminal output shows only the message line.

let withComp = (~comp=?, msg) =>
  switch comp {
  | Some(c) => `${Logger.bold}[${c}]${Logger.reset} ${msg}`
  | None => msg
  }

let encode = (~comp=?, ~detail=?, msg) => {
  let text = withComp(~comp?, msg)
  switch detail {
  | Some(d) => `${text}${Logger.detailSeparator}${d->JSON.stringify}`
  | None => text
  }
}

let logInfo = (~comp=?, ~detail=?, msg) => Effect.logInfo(encode(~comp?, ~detail?, msg))
let logWarn = (~comp=?, ~detail=?, msg) => Effect.logWarning(encode(~comp?, ~detail?, msg))
let logError = (~comp=?, ~detail=?, msg) => Effect.logError(encode(~comp?, ~detail?, msg))
let logDebug = (~comp=?, ~detail=?, msg) => Effect.logDebug(encode(~comp?, ~detail?, msg))
