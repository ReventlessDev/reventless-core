// Unified logger for deploy-time (Pulumi Output.apply) and non-Effect runtime code.
// EffectLogger delegates to `emit` so the format is defined once here.
//
// Usage:
//   let log = Logger.fromEnv()         // reads LOG_LEVEL from process.env once
//   log.info(~comp="MyModule", "done")
//   log.debug(~comp="MyModule", ~data=json, "detail")
//
// LOG_LEVEL env var: "debug" | "warn" | "error" | (anything else = "info")

@val external _logLevel: option<string> = "process.env.LOG_LEVEL"
@val external _isLambda: option<string> = "process.env.AWS_LAMBDA_FUNCTION_NAME"

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

// Null-byte separator for embedding detail in Effect log messages.
// EffectLogger encodes: "message\x00{detail json}"
// install() decodes: split on \x00, extract detail.
let detailSeparator = "\x00"

let hms = () => {
  let d = Date.make()
  let h = d->Date.getHours->Int.toString->String.padStart(2, "0")
  let m = d->Date.getMinutes->Int.toString->String.padStart(2, "0")
  let s = d->Date.getSeconds->Int.toString->String.padStart(2, "0")
  `${h}:${m}:${s}`
}

let fmtComp = (~comp=?, ()) =>
  switch comp {
  | Some(c) => `${Reventless.AnsiStyle.bold(`[${c}]`)} `
  | None => ""
  }

// Central emit — all log output flows through here.
// ~detail: structured data shown only in CloudWatch (expandable on click).
//   Terminal (in-memory): shows only the message line.
//   Lambda (CloudWatch):  outputs JSON with message + detail fields.
let emit = (~level: level, ~comp=?, ~detail: option<JSON.t>=?, msg: string) => {
  let isLambda = _isLambda->Option.isSome

  if isLambda {
    // CloudWatch structured JSON — message in summary, detail expandable on click
    let compStr = switch comp {
    | Some(c) => `[${c}] `
    | None => ""
    }
    let message = `${compStr}${msg}`
    switch detail {
    | Some(d) =>
      let obj = Dict.fromArray([
        ("level", levelLabel(level)->JSON.Encode.string),
        ("message", message->JSON.Encode.string),
        ("detail", d),
      ])
      Console.log(obj->JSON.Encode.object->JSON.stringify)
    | None =>
      let obj = Dict.fromArray([
        ("level", levelLabel(level)->JSON.Encode.string),
        ("message", message->JSON.Encode.string),
      ])
      Console.log(obj->JSON.Encode.object->JSON.stringify)
    }
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
let fromEnv = (): t =>
  makeLogger(
    ~minLevel=switch _logLevel {
    | Some("debug") => Debug
    | Some("warn") => Warn
    | Some("error") => Error
    | _ => Info
    },
  )
