/** ANSI terminal style primitives + sink detection for log output.
    Kept in reventless-spec so both reventless-core (Logger / LogFormat) and
    reventless-infra (compLog in ExtensionMapping/ExtensionPointMapping)
    can share the same styling helpers AND the same sink decision.

    This is the lowest layer in the logging stack — LogPrefix and Logger
    depend on it, so the sink decision lives here as the single source of
    truth. `useAnsi()` ⇒ TTY text mode (colour/bold); `isJsonSink()` ⇒
    structured JSON for any non-TTY collector (CloudWatch, Datadog, …). */

@val external _isTty: option<bool> = "process.stdout.isTTY"
@val external _logFormat: option<string> = "process.env.REVENTLESS_LOG_FORMAT"

// What this runtime is, for when stdout cannot say. A local dev platform's logs
// are read by a person even when its stdout is a pipe — `concurrently`, `tsx
// watch` and an IDE terminal all pipe — while a Lambda's are read by a collector
// through a pipe that looks identical. TTY-ness is only a proxy for "a person is
// reading this", and a pipe is exactly where the proxy fails, so a runtime that
// knows which it is says so instead of being guessed at.
let _default: ref<option<string>> = ref(None)

// "json" | "text", in precedence order: an explicit REVENTLESS_LOG_FORMAT, then
// what the runtime declared itself to be, then the TTY probe — a TTY stdout ⇒
// text, everything else (Lambda, Fargate, ECS, Docker, CI) ⇒ structured JSON.
let _resolveFormat = (): string =>
  switch (_logFormat, _default.contents, _isTty) {
  | (Some("json"), _, _) => "json"
  | (Some("text"), _, _) => "text"
  | (_, Some(declared), _) => declared
  | (_, None, Some(true)) => "text"
  | _ => "json"
  }

// Resolved once at module init; recomputable via `reload()` (test-only — after a
// test mutates process.env / process.stdout.isTTY). Not a hot path, but caching
// keeps every log call off `process.env`.
let _format = ref(_resolveFormat())

/** Declares what this runtime is, for the pipe case the TTY probe gets wrong.
    Call it at module init, before anything logs. An explicit
    REVENTLESS_LOG_FORMAT still wins, so a developer can always ask for the other
    one. A runtime that says nothing keeps the TTY behaviour. */
let setDefaultFormat = (format: [#text | #json]) => {
  _default :=
    Some(
      switch format {
      | #text => "text"
      | #json => "json"
      },
    )
  _format := _resolveFormat()
}

/** Test-only: re-evaluate REVENTLESS_LOG_FORMAT / process.stdout.isTTY. */
let reload = () => _format := _resolveFormat()

/** True when output should be structured JSON (non-TTY sink). */
let isJsonSink = () => _format.contents == "json"

/** True when output should carry ANSI colour/bold (TTY text mode). */
let useAnsi = () => _format.contents == "text"

/** Wrap a string in ANSI bold escape codes — no-op in a JSON sink. */
let bold = s => useAnsi() ? `\x1b[1m${s}\x1b[0m` : s
