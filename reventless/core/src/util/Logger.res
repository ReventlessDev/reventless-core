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

// service field (3.3): explicit REVENTLESS_SERVICE override wins, else the
// Lambda function name. Read per-emit (cheap) so a platform/test can set it
// after module init. None ⇒ field omitted.
@val external _serviceOverride: option<string> = "process.env.REVENTLESS_SERVICE"
@val external _lambdaName: option<string> = "process.env.AWS_LAMBDA_FUNCTION_NAME"
let serviceName = (): option<string> =>
  switch _serviceOverride {
  | Some(s) => Some(s)
  | None => _lambdaName
  }

// detail truncation cap (3.1) — configurable; default 32 KB. CloudWatch caps a
// single record at 256 KB, so an oversized ~detail is replaced with a preview
// stub rather than risking a silent drop.
@val external _maxDetailBytes: option<string> = "process.env.REVENTLESS_LOG_MAX_DETAIL_BYTES"
let maxDetailBytes = switch _maxDetailBytes {
| Some(s) => s->Int.fromString->Option.getOr(32 * 1024)
| None => 32 * 1024
}

type logFn = (~comp: string=?, ~data: JSON.t=?, string) => unit

type t = {
  debug: logFn,
  info: logFn,
  warn: logFn,
  error: logFn,
  // Lazy debug: the message thunk runs only when debug output is actually
  // enabled. On a hot path (e.g. per-projection-action logging) this avoids
  // building — and serializing state into — a string that is then dropped at
  // the default Info level.
  debugLazy: (~comp: string=?, unit => string) => unit,
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

// RFC 3339 / ISO-8601 timestamp for the JSON `time` field (3.2).
let iso = () => Date.make()->Date.toISOString

// Replace an oversized detail payload with a bounded preview stub (3.1).
let truncateDetail = (d: JSON.t): JSON.t => {
  let s = d->JSON.stringify
  if s->String.length > maxDetailBytes {
    Dict.fromArray([
      ("truncated", JSON.Encode.bool(true)),
      ("bytes", JSON.Encode.int(s->String.length)),
      ("preview", s->String.slice(~start=0, ~end=512)->JSON.Encode.string),
    ])->JSON.Encode.object
  } else {
    d
  }
}

// Plugin-name resolution + prefix formatting live in `Reventless.LogPrefix`
// so that infra-layer log helpers (ExtensionPointMapping, ExtensionMapping)
// can share the same logic without depending on this package.
let currentPluginName = Reventless.LogPrefix.currentPluginName
let registerComponentPlugin = Reventless.LogPrefix.registerComponentPlugin
let fmtComp = Reventless.LogPrefix.fmtComp
let fmtPlainPrefix = Reventless.LogPrefix.fmtPlainPrefix
let resolvePlugin = Reventless.LogPrefix.resolvePlugin

// ─── The record every line is made from ──────────────────────────────────────

/** One log line before it is formatted: what the JSON line prints, field for
    field, and what a registered sink receives. `detail` is already redacted and
    truncated, so a sink can keep it as it is. */
type record = {
  time: string,
  level: level,
  message: string,
  service?: string,
  plugin?: string,
  comp?: string,
  annotations: dict<string>,
  detail?: JSON.t,
}

/** The JSON line's fields, in the order the line prints them. Annotations are
    top-level keys beside the fixed ones. */
let recordFields = (r: record): array<(string, JSON.t)> =>
  [
    ("time", r.time->JSON.Encode.string),
    ("level", levelLabel(r.level)->JSON.Encode.string),
    ("message", r.message->JSON.Encode.string),
  ]
  ->Array.concat(r.service->Option.mapOr([], s => [("service", JSON.Encode.string(s))]))
  ->Array.concat(r.plugin->Option.mapOr([], p => [("plugin", JSON.Encode.string(p))]))
  ->Array.concat(r.comp->Option.mapOr([], c => [("comp", JSON.Encode.string(c))]))
  ->Array.concat(r.annotations->Dict.toArray->Array.map(((k, v)) => (k, JSON.Encode.string(v))))
  ->Array.concat(r.detail->Option.mapOr([], d => [("detail", d)]))

let recordToJson = (r: record): JSON.t => r->recordFields->Dict.fromArray->JSON.Encode.object

// ─── Sinks ───────────────────────────────────────────────────────────────────
// Code that keeps or forwards log records (a platform's recent-records ring, a
// feed to a watching tool) registers a sink and receives every record that
// passed its level, before it is formatted.

type sink = record => unit

type registeredSink = {
  id: int,
  sink: sink,
  // A sink that throws is noted once, not on every line it fails.
  mutable noted: bool,
}

let sinks: ref<array<registeredSink>> = ref([])
let nextSinkId = ref(0)

/** Registers a sink and returns the function that removes it. */
let addSink = (sink: sink): (unit => unit) => {
  nextSinkId := nextSinkId.contents + 1
  let id = nextSinkId.contents
  sinks := sinks.contents->Array.concat([{id, sink, noted: false}])
  () => sinks := sinks.contents->Array.filter(s => s.id != id)
}

let hasSinks = () => sinks.contents->Array.length > 0

// Written straight to stderr, never through `emit`: a note about a failing sink
// must not reach that sink again.
let callSinks = (r: record) =>
  sinks.contents->Array.forEach(s =>
    try s.sink(r) catch {
    | exn =>
      if !s.noted {
        s.noted = true
        let why = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Console.error(`log sink ${s.id->Int.toString} failed and is skipped for that line: ${why}`)
      }
    }
  )

// Central emit — all log output flows through here.
// ~detail: structured data shown only in CloudWatch (expandable on click).
//   Terminal (in-memory): shows only the message line.
//   JSON sink (CloudWatch/…): structured object with plugin/comp/detail fields.
// ~plugin: explicit plugin override (e.g. from Effect annotations set at the
//   Lambda boundary). Falls back to LogPrefix.resolvePlugin lookup if absent.
// ~annotations: extra structured key/value pairs (e.g. correlationId, requestId)
//   carried via Effect log annotations. JSON sink only; ignored in the TTY view.
let emit = (
  ~level: level,
  ~comp=?,
  ~plugin: option<string>=?,
  ~detail: option<JSON.t>=?,
  ~annotations: option<dict<string>>=?,
  msg: string,
) => {
  // Sink decision lives in Reventless.AnsiStyle (single source of truth, shared
  // with fmtComp / AnsiStyle.bold). Non-TTY collectors (Lambda, Fargate, ECS,
  // Azure, GCP, Docker, CI, piped stdout) all get JSON; a TTY stays text.
  let json = Reventless.AnsiStyle.isJsonSink()
  // The record is built only when something reads it: the JSON line, or a sink.
  let record = if json || hasSinks() {
    // Explicit ~plugin wins; otherwise fall back to the LogPrefix registry.
    let pluginField = switch plugin {
    | Some(_) as p => p
    | None => resolvePlugin(~comp?, ())
    }
    Some({
      time: iso(),
      level,
      message: msg,
      service: ?serviceName(),
      plugin: ?pluginField,
      ?comp,
      annotations: annotations->Option.getOr(Dict.make()),
      // Redacted before anything else: a personal value must not reach a log
      // group, which cannot be swept for one person (`LogRedaction`).
      detail: ?(detail->Option.map(d => d->Reventless.LogRedaction.redactJson->truncateDetail)),
    })
  } else {
    None
  }
  record->Option.forEach(callSinks)
  if json {
    // Structured JSON for any log collector. Plugin/comp/annotations are promoted
    // to top-level queryable keys instead of being baked into `message`; `message`
    // stays clean human text. `detail` is the expandable structured payload.
    record->Option.forEach(r => Console.log(r->recordToJson->JSON.stringify))
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

// Platform-tunable default minimum level, used when LOG_LEVEL is unset. Lives
// here (not in EffectLogger) so it is the single source of truth for BOTH logger
// paths — the record logger below and EffectLogger, which re-exports
// `setDefaultMinLevel`. A platform may lower it (e.g. reventless-local sets
// Debug); the framework default is Info.
let defaultMinLevel = ref(Info)
let setDefaultMinLevel = (l: level) => defaultMinLevel := l

// Build a logger from a per-call predicate. `shouldLog` is evaluated on every
// emit, so a logger created at module-init time still reflects a platform
// default set later (and a live LOG_LEVEL) instead of baking the level in once.
// It is given the line's component, so a level set for one component applies.
let makeLoggerWith = (shouldLog: (level, option<string>) => bool): t => {
  let log = (level, ~comp=?, ~data=?, msg) =>
    if shouldLog(level, comp) {
      let dataStr =
        data
        ->Option.map(d => ` ${d->Reventless.LogRedaction.redactJson->JSON.stringify}`)
        ->Option.getOr("")
      emit(~level, ~comp?, `${msg}${dataStr}`)
    }
  {
    debug: (~comp=?, ~data=?, msg) => log(Debug, ~comp?, ~data?, msg),
    info: (~comp=?, ~data=?, msg) => log(Info, ~comp?, ~data?, msg),
    warn: (~comp=?, ~data=?, msg) => log(Warn, ~comp?, ~data?, msg),
    error: (~comp=?, ~data=?, msg) => log(Error, ~comp?, ~data?, msg),
    debugLazy: (~comp=?, makeMsg) =>
      if shouldLog(Debug, comp) {
        emit(~level=Debug, ~comp?, makeMsg())
      },
  }
}

// Fixed-level logger — the level is baked at creation. Used by tests that assert
// a specific minimum regardless of env/platform default.
let makeLogger = (~minLevel=Info): t =>
  makeLoggerWith((l, _) => levelToInt(l) >= levelToInt(minLevel))

let silent: t = {
  debug: (~comp as _=?, ~data as _=?, _) => (),
  info: (~comp as _=?, ~data as _=?, _) => (),
  warn: (~comp as _=?, ~data as _=?, _) => (),
  error: (~comp as _=?, ~data as _=?, _) => (),
  debugLazy: (~comp as _=?, _) => (),
}

// Active minimum level: explicit LOG_LEVEL wins, else the platform default.
// None ⇒ silent (suppress everything). Re-read per call — LOG_LEVEL via the
// process.env external, the platform default via `defaultMinLevel`.
let effectiveMin = (): option<level> =>
  switch _logLevel {
  | Some("silent") => None
  | Some("debug") => Some(Debug)
  | Some("info") => Some(Info)
  | Some("warn") => Some(Warn)
  | Some("error") => Some(Error)
  | Some(_) => Some(Info) // unrecognized value ⇒ Info (unchanged behavior)
  | None => Some(defaultMinLevel.contents)
  }

// ─── Levels set while running ────────────────────────────────────────────────
// A running process can be told a level for everything, for one plugin, for one
// component, or for one component of one plugin. Consulted before LOG_LEVEL, and
// the narrowest one that is set wins: component of a plugin, then component, then
// plugin, then the default. Kept in memory only, so a level set this way lasts
// until the process stops.

type levelOverrides = {
  plugins: dict<level>,
  comps: dict<level>,
  // Keyed `plugin + "\x00" + comp`.
  pluginComps: dict<level>,
}

let overrides: levelOverrides = {plugins: Dict.make(), comps: Dict.make(), pluginComps: Dict.make()}
// The level for every line not covered by a narrower one; `None` until set.
let defaultOverride: ref<option<level>> = ref(None)

let pluginCompKey = (~plugin, ~comp) => plugin ++ "\x00" ++ comp

let hasOverrides = () =>
  defaultOverride.contents->Option.isSome ||
  overrides.plugins->Dict.keysToArray->Array.length > 0 ||
  overrides.comps->Dict.keysToArray->Array.length > 0 ||
  overrides.pluginComps->Dict.keysToArray->Array.length > 0

/** Sets the level for the scope the arguments name — both: that component of
    that plugin; only `~comp`: that component wherever it runs; only `~plugin`:
    every line of that plugin; neither: the default. `None` removes it, so the
    next wider scope applies again. */
let setLevel = (~plugin: option<string>=?, ~comp: option<string>=?, level: option<level>) => {
  let put = (d: dict<level>, key) =>
    switch level {
    | Some(l) => d->Dict.set(key, l)
    | None => d->Dict.delete(key)
    }
  switch (plugin, comp) {
  | (Some(p), Some(c)) => put(overrides.pluginComps, pluginCompKey(~plugin=p, ~comp=c))
  | (None, Some(c)) => put(overrides.comps, c)
  | (Some(p), None) => put(overrides.plugins, p)
  | (None, None) => defaultOverride := level
  }
}

/** Removes every level set while running. */
let clearLevels = () => {
  defaultOverride := None
  [overrides.plugins, overrides.comps, overrides.pluginComps]->Array.forEach(d =>
    d->Dict.keysToArray->Array.forEach(k => d->Dict.delete(k))
  )
}

type levelSetting = {
  plugin?: string,
  comp?: string,
  level: level,
}

/** Every level set while running, the default first. */
let levelSettings = (): array<levelSetting> => {
  let out = []
  defaultOverride.contents->Option.forEach(level => out->Array.push({level: level}))
  overrides.plugins
  ->Dict.toArray
  ->Array.forEach(((plugin, level)) => out->Array.push({plugin, level}))
  overrides.comps->Dict.toArray->Array.forEach(((comp, level)) => out->Array.push({comp, level}))
  overrides.pluginComps
  ->Dict.toArray
  ->Array.forEach(((key, level)) =>
    switch key->String.split("\x00") {
    | [plugin, comp] => out->Array.push({plugin, comp, level})
    | _ => ()
    }
  )
  out
}

/** The minimum level a line of this component (and plugin) is written at.
    `None` ⇒ nothing is written. The plugin is resolved from the component when
    not given, and only when a level was set for a plugin. */
let minLevelFor = (~plugin: option<string>=?, ~comp: option<string>=?, ()): option<level> =>
  if !hasOverrides() {
    effectiveMin()
  } else {
    let pluginOf = () =>
      switch plugin {
      | Some(_) as p => p
      | None => resolvePlugin(~comp?, ())
      }
    let fromPluginComp = switch comp {
    | Some(c) if overrides.pluginComps->Dict.keysToArray->Array.length > 0 =>
      pluginOf()->Option.flatMap(p =>
        overrides.pluginComps->Dict.get(pluginCompKey(~plugin=p, ~comp=c))
      )
    | _ => None
    }
    let fromComp = () => comp->Option.flatMap(c => overrides.comps->Dict.get(c))
    let fromPlugin = () =>
      if overrides.plugins->Dict.keysToArray->Array.length > 0 {
        pluginOf()->Option.flatMap(p => overrides.plugins->Dict.get(p))
      } else {
        None
      }
    switch fromPluginComp {
    | Some(_) as l => l
    | None =>
      switch fromComp() {
      | Some(_) as l => l
      | None =>
        switch fromPlugin() {
        | Some(_) as l => l
        | None =>
          switch defaultOverride.contents {
          | Some(_) as l => l
          | None => effectiveMin()
          }
        }
      }
    }
  }

/** Whether a line at `level` of this component (and plugin) is written. */
let shouldLog = (level: level, ~plugin: option<string>=?, ~comp: option<string>=?, ()): bool =>
  switch minLevelFor(~plugin?, ~comp?, ()) {
  | None => false
  | Some(min) => levelToInt(level) >= levelToInt(min)
  }

// Reads LOG_LEVEL from process.env on every call and honors the platform default
// when unset. Safe to call at module top-level: the returned logger evaluates the
// level lazily, so a platform lowering the default afterwards (e.g.
// reventless-local → Debug) takes effect for loggers already constructed.
// LOG_LEVEL=silent disables all output (used by the reventless-gwt CLI so
// framework diagnostics don't interleave with NDJSON / TAP / JUnit streams).
// A level set while running (`setLevel`) is consulted first.
let fromEnv = (): t => makeLoggerWith((l, comp) => shouldLog(l, ~comp?, ()))
