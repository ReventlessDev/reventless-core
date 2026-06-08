// Compact Effect logger — delegates to Logger.emit for format.
//
// Two responsibilities:
//   1. install() — replaces Effect's default logger (timestamp=/level=/fiber=)
//      with Logger.emit so all Effect.runPromise/runSync calls use the unified format.
//   2. logInfo/logWarn/logError/logDebug — structured helpers with ~comp and ~detail
//      that return Effect.t<unit> for use in Effect pipelines.
//
// ~comp / ~detail and any ambient annotations (e.g. correlationId, requestId set
// via Effect.annotateLogs at the request boundary) travel as Effect log
// annotations — NOT baked into the message string. install() reads them off
// `loggerOptions.annotations` and forwards them to Logger.emit, which promotes
// them to top-level JSON fields. The message stays clean human text.
//
// Usage: import at platform startup (module init calls install()).
//   EffectLogger.logInfo(~comp=`Aggregate(${Spec.name})`, ~detail=eventJson, "replay done")

type loggerOptions
type logLevel
type annotationsMap

@get external _message: loggerOptions => JSON.t = "message"
@get external _logLevel: loggerOptions => logLevel = "logLevel"
@get external _ordinal: logLevel => int = "ordinal"
@get external _annotations: loggerOptions => annotationsMap = "annotations"

// Effect stores log annotations as a HashMap<string, unknown>; toEntries gives a
// plain [key, value] array. Values arrive as raw JS — string annotations decode
// directly via JSON.Decode.string.
@module("effect/HashMap")
external _annotationEntries: annotationsMap => array<(string, JSON.t)> = "toEntries"

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
    let msg = opts->_message->_messageToString
    let level = opts->_logLevel->_ordinal->ordinalToLevel
    // Decode log annotations: `comp`, `plugin`, and `detail` get dedicated
    // Logger.emit handling (prefix/plugin resolution, expandable payload);
    // everything else (correlationId, requestId, …) flows through as
    // top-level string fields.
    let comp = ref(None)
    let plugin = ref(None)
    let detail = ref(None)
    let extra = Dict.make()
    opts
    ->_annotations
    ->_annotationEntries
    ->Array.forEach(((k, v)) =>
      switch k {
      | "comp" => comp := v->JSON.Decode.string
      | "plugin" => plugin := v->JSON.Decode.string
      | "detail" =>
        detail :=
          switch v->JSON.Decode.string {
          | Some(s) =>
            try Some(s->JSON.parseOrThrow) catch {
            | _ => Some(JSON.Encode.string(s))
            }
          | None => Some(v)
          }
      | _ =>
        switch v->JSON.Decode.string {
        | Some(s) => extra->Dict.set(k, s)
        | None => extra->Dict.set(k, v->JSON.stringify)
        }
      }
    )
    let annotations = extra->Dict.toArray->Array.length == 0 ? None : Some(extra)
    Logger.emit(
      ~level,
      ~comp=?comp.contents,
      ~plugin=?plugin.contents,
      ~detail=?detail.contents,
      ~annotations?,
      msg,
    )
  }

// Self-installing: runs at module initialization time.
install()

// ─── Structured log helpers ──────────────────────────────────────────────────
// Returns Effect.t<unit> — usable in Effect pipelines or with ->Effect.runSync.
//
// ~comp / ~detail attach as Effect log annotations; install() reads them back.
//   ~detail: structured JSON shown only in a JSON sink (expandable on click);
//   the in-memory terminal output shows only the message line.

// Attach comp/detail as annotations on the log effect. detail is stringified so
// it rides through Effect's string-keyed annotation map; install() re-parses it.
let _annotate = (eff, ~comp=?, ~detail=?) => {
  let eff = switch comp {
  | Some(c) => eff->Effect.annotateLogs("comp", c)
  | None => eff
  }
  switch detail {
  | Some(d) => eff->Effect.annotateLogs("detail", d->JSON.stringify)
  | None => eff
  }
}

let logInfo = (~comp=?, ~detail=?, msg) =>
  Effect.logInfo(msg)->_annotate(~comp?, ~detail?)->_withMinimumLogLevel(_effectMin())
let logWarn = (~comp=?, ~detail=?, msg) =>
  Effect.logWarning(msg)->_annotate(~comp?, ~detail?)->_withMinimumLogLevel(_effectMin())
let logError = (~comp=?, ~detail=?, msg) =>
  Effect.logError(msg)->_annotate(~comp?, ~detail?)->_withMinimumLogLevel(_effectMin())
let logDebug = (~comp=?, ~detail=?, msg) =>
  Effect.logDebug(msg)->_annotate(~comp?, ~detail?)->_withMinimumLogLevel(_effectMin())
