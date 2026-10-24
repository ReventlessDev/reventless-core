// The local platform's limit on doors open to callers who are not signed in:
// requests per source address per window, read from
// `REVENTLESS_ANONYMOUS_REQUEST_LIMIT` (`10/3600` when unset).
//
// One limiter for the process, built on first use so a test can set the
// variable first. A value that does not parse fails the request rather than
// falling back: a limit someone set and mistyped must not quietly become one they
// did not choose.

let limiter: ref<option<ReventlessCore.AnonymousLimiter.t>> = ref(None)

let configured = (): Reventless.AnonymousRequestLimit.t =>
  switch NodeProcess.env->Dict.get(Reventless.AnonymousRequestLimit.envKey) {
  | None | Some("") => Reventless.AnonymousRequestLimit.default
  | Some(raw) =>
    switch Reventless.AnonymousRequestLimit.parse(raw) {
    | Ok(limit) => limit
    | Error(message) => JsError.throwWithMessage(message)
    }
  }

let current = (): ReventlessCore.AnonymousLimiter.t =>
  switch limiter.contents {
  | Some(l) => l
  | None =>
    let l = ReventlessCore.AnonymousLimiter.make(~limit=configured())
    limiter := Some(l)
    l
  }

/** Forget every count and re-read the configuration on next use. */
let reset = () => limiter := None

/** Whether one more request from `source` reaches `door`. */
let admit = (~door: string, ~source: string): bool => current().admit(~door, ~source)
