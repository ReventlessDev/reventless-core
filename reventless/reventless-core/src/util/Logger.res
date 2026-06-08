// Unified logger for deploy-time (Pulumi Output.apply) and non-Effect runtime code.
// EffectLogger delegates to `emit` so the format is defined once here.
//
// Usage:
//   let log = Logger.fromEnv()         // reads LOG_LEVEL from process.env once
//   log.info(~comp="MyModule", "done")
//   log.debug(~comp="MyModule", ~data=json, "detail")
//
// LOG_LEVEL env var: "silent" | "debug" | "warn" | "error" | (anything else = "info")

@val external _logLevel: option<string> = "process.env.LOG_LEVEL"

type logFn = (~comp: string=?, ~data: JSON.t=?, string) => unit

type t = {
  debug: logFn,
  info: logFn,
  warn: logFn,
  error: logFn,
}

type level = Debug | Info | Warn | Error

let levelToInt = l =>
  switch l {
  | Debug => 0
  | Info => 1
  | Warn => 2
  | Error => 3
  }

let levelLabel = l =>
  switch l {
  | Debug => "DEBUG"
  | Info => "INFO"
  | Warn => "WARN"
  | Error => "ERROR"
  }

// ─── Shared format + output ──────────────────────────────────────────────────
// Single definition used by Logger.t AND EffectLogger.

// ANSI codes
let red = "\x1b[31m"
let yellow = "\x1b[33m"
let cyan = "\x1b[36m"
let dim = "\x1b[90m"
let reset = "\x1b[0m"

let hms = () => {
  let d = Date.make()
  let h = d->Date.getHours->Int.toString->String.padStart(2, "0")
  let m = d->Date.getMinutes->Int.toString->String.padStart(2, "0")
  let s = d->Date.getSeconds->Int.toString->String.padStart(2, "0")
  `${h}:${m}:${s}`
}

// Plugin-name resolution + prefix formatting live in `Reventless.LogPrefix`
// so that infra-layer log helpers (ExtensionPointMapping, ExtensionMapping)
// can share the same logic without depending on this package.
let currentPluginName = Reventless.LogPrefix.currentPluginName
let registerComponentPlugin = Reventless.LogPrefix.registerComponentPlugin
let fmtComp = Reventless.LogPrefix.fmtComp
let fmtPlainPrefix = Reventless.LogPrefix.fmtPlainPrefix
let resolvePlugin = Reventless.LogPrefix.resolvePlugin

// Central emit — all log output flows through here.
// ~detail: structured data shown only in CloudWatch (expandable on click).
//   Terminal (in-memory): shows only the message line.
//   JSON sink (CloudWatch/…): structured object with plugin/comp/detail fields.
// ~annotations: extra structured key/value pairs (e.g. correlationId, requestId)
//   carried via Effect log annotations. JSON sink only; ignored in the TTY view.
let emit = (
  ~level: level,
  ~comp=?,
  ~detail: option<JSON.t>=?,
  ~annotations: option<dict<string>>=?,
  msg: string,
) => {
  // Sink decision lives in Reventless.AnsiStyle (single source of truth, shared
  // with fmtComp / AnsiStyle.bold). Non-TTY collectors (Lambda, Fargate, ECS,
  // Azure, GCP, Docker, CI, piped stdout) all get JSON; a TTY stays text.
  if Reventless.AnsiStyle.isJsonSink() {
    // Structured JSON for any log collector. Plugin/comp/annotations are promoted
    // to top-level queryable keys instead of being baked into `message`; `message`
    // stays clean human text. `detail` is the expandable structured payload.
    let annotationFields =
      annotations->Option.mapOr([], a =>
        a->Dict.toArray->Array.map(((k, v)) => (k, JSON.Encode.string(v)))
      )
    let fields =
      [
        ("level", levelLabel(level)->JSON.Encode.string),
        ("message", msg->JSON.Encode.string),
      ]
      ->Array.concat(
        resolvePlugin(~comp?, ())->Option.mapOr([], p => [("plugin", JSON.Encode.string(p))]),
      )
      ->Array.concat(comp->Option.mapOr([], c => [("comp", JSON.Encode.string(c))]))
      ->Array.concat(annotationFields)
      ->Array.concat(detail->Option.mapOr([], d => [("detail", d)]))
    Console.log(fields->Dict.fromArray->JSON.Encode.object->JSON.stringify)
  } else {
    // Terminal — colored, human-readable, no detail
    let t = hms()
    let c = fmtComp(~comp?, ())
    switch level {
    | Error => Console.error(`${t} ${red}E${reset} ${c}${msg}`)
    | Warn => Console.warn(`${t} ${yellow}W${reset} ${c}${msg}`)
    | Info => Console.log(`${t} ${cyan}I${reset} ${c}${msg}`)
    | Debug => Console.log(`${t} ${dim}D${reset} ${c}${msg}`)
    }
  }
}

// ─── Logger.t (record-based API) ─────────────────────────────────────────────

let makeLogger = (~minLevel=Info): t => {
  let shouldLog = l => levelToInt(l) >= levelToInt(minLevel)
  let log = (level, ~comp=?, ~data=?, msg) =>
    if shouldLog(level) {
      let dataStr = data->Option.map(d => ` ${d->JSON.stringify}`)->Option.getOr("")
      emit(~level, ~comp?, `${msg}${dataStr}`)
    }
  {
    debug: (~comp=?, ~data=?, msg) => log(Debug, ~comp?, ~data?, msg),
    info: (~comp=?, ~data=?, msg) => log(Info, ~comp?, ~data?, msg),
    warn: (~comp=?, ~data=?, msg) => log(Warn, ~comp?, ~data?, msg),
    error: (~comp=?, ~data=?, msg) => log(Error, ~comp?, ~data?, msg),
  }
}

let silent: t = {
  debug: (~comp as _=?, ~data as _=?, _) => (),
  info: (~comp as _=?, ~data as _=?, _) => (),
  warn: (~comp as _=?, ~data as _=?, _) => (),
  error: (~comp as _=?, ~data as _=?, _) => (),
}

// Reads LOG_LEVEL from process.env and returns a configured logger.
// Call once at module top-level or startup — not inside hot loops.
// LOG_LEVEL=silent disables all output (used by the reventless-gwt CLI so
// framework diagnostics don't interleave with NDJSON / TAP / JUnit streams).
let fromEnv = (): t =>
  switch _logLevel {
  | Some("silent") => silent
  | Some("debug") => makeLogger(~minLevel=Debug)
  | Some("warn") => makeLogger(~minLevel=Warn)
  | Some("error") => makeLogger(~minLevel=Error)
  | _ => makeLogger(~minLevel=Info)
  }
