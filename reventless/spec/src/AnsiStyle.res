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

// "json" | "text". Explicit REVENTLESS_LOG_FORMAT override always wins; otherwise
// a TTY stdout ⇒ human-readable text, everything else (Lambda, Fargate, ECS,
// Azure, GCP, Docker, CI runners, piped stdout) ⇒ structured JSON.
let _resolveFormat = (): string =>
  switch (_logFormat, _isTty) {
  | (Some("json"), _) => "json"
  | (Some("text"), _) => "text"
  | (_, Some(true)) => "text"
  | _ => "json"
  }

// Resolved once at module init; recomputable via `reload()` (test-only — after a
// test mutates process.env / process.stdout.isTTY). Not a hot path, but caching
// keeps every log call off `process.env`.
let _format = ref(_resolveFormat())

/** Test-only: re-evaluate REVENTLESS_LOG_FORMAT / process.stdout.isTTY. */
let reload = () => _format := _resolveFormat()

/** True when output should be structured JSON (non-TTY sink). */
let isJsonSink = () => _format.contents == "json"

/** True when output should carry ANSI colour/bold (TTY text mode). */
let useAnsi = () => _format.contents == "text"

/** Wrap a string in ANSI bold escape codes — no-op in a JSON sink. */
let bold = s => useAnsi() ? `\x1b[1m${s}\x1b[0m` : s
