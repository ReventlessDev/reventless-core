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

@get external _message: loggerOptions => JSON.t = "message"
@get external _logLevel: loggerOptions => logLevel = "logLevel"
@get external _ordinal: logLevel => int = "ordinal"

let _messageToString = (msg: JSON.t): string =>
  switch msg {
  | Array(arr) =>
    arr
    ->Array.map(j =>
      switch j {
      | String(s) => s
      | _ => j->JSON.stringifyAny->Option.getOr("")
      }
    )
    ->Array.join(" ")
  | String(s) => s
  | _ => msg->JSON.stringifyAny->Option.getOr("")
  }

type effectLogger = {mutable log: loggerOptions => unit}

@module("effect/Logger")
external _defaultLogger: effectLogger = "defaultLogger"

// Effect's runtime gates log effects by a minimum LogLevel BEFORE they reach the
// installed logger above — so `Effect.logDebug` is dropped unless the threshold is
// lowered. We set that threshold per log effect from a configurable minimum.
type effectLogLevel
@module("effect/LogLevel") external _llDebug: effectLogLevel = "Debug"
@module("effect/LogLevel") external _llInfo: effectLogLevel = "Info"
@module("effect/LogLevel") external _llWarning: effectLogLevel = "Warning"
@module("effect/LogLevel") external _llError: effectLogLevel = "Error"
@module("effect/LogLevel") external _llNone: effectLogLevel = "None"

@module("effect/Logger")
external _withMinimumLogLevel: (Effect.t<'a, 'e, 'r>, effectLogLevel) => Effect.t<'a, 'e, 'r> =
  "withMinimumLogLevel"

@val external _envLogLevel: option<string> = "process.env.LOG_LEVEL"

// Minimum level used when LOG_LEVEL is unset. Framework default is Info; a platform
// may lower it (e.g. the in-memory dev platform sets Debug) via setDefaultMinLevel.
let _defaultMin = ref(Logger.Info)
let setDefaultMinLevel = (l: Logger.level) => _defaultMin := l

// Resolve the active minimum: explicit LOG_LEVEL wins, else the platform default.
let _effectMin = (): effectLogLevel =>
  switch _envLogLevel {
  | Some("silent") => _llNone
  | Some("debug") => _llDebug
  | Some("info") => _llInfo
  | Some("warn") => _llWarning
  | Some("error") => _llError
  | _ =>
    switch _defaultMin.contents {
    | Logger.Debug => _llDebug
    | Logger.Info => _llInfo
    | Logger.Warn => _llWarning
    | Logger.Error => _llError
    }
  }

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
    let raw = opts->_message->_messageToString
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

let withComp = (~comp=?, msg) => {
  let prefix = Logger.fmtComp(~comp?, ())
  prefix == "" ? msg : `${prefix}${msg}`
}

let encode = (~comp=?, ~detail=?, msg) => {
  let text = withComp(~comp?, msg)
  switch detail {
  | Some(d) => `${text}${Logger.detailSeparator}${d->JSON.stringify}`
  | None => text
  }
}

let logInfo = (~comp=?, ~detail=?, msg) =>
  Effect.logInfo(encode(~comp?, ~detail?, msg))->_withMinimumLogLevel(_effectMin())
let logWarn = (~comp=?, ~detail=?, msg) =>
  Effect.logWarning(encode(~comp?, ~detail?, msg))->_withMinimumLogLevel(_effectMin())
let logError = (~comp=?, ~detail=?, msg) =>
  Effect.logError(encode(~comp?, ~detail?, msg))->_withMinimumLogLevel(_effectMin())
let logDebug = (~comp=?, ~detail=?, msg) =>
  Effect.logDebug(encode(~comp?, ~detail?, msg))->_withMinimumLogLevel(_effectMin())
