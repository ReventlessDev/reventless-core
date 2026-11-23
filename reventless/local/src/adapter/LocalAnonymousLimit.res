// The local platform's limit on doors and views open to callers who are not
// signed in: requests per source address per window, each kind read from its own
// variable (`REVENTLESS_ANONYMOUS_REQUEST_LIMIT`, `20/3600` when unset, for doors;
// `REVENTLESS_ANONYMOUS_VIEW_LIMIT`, `300/3600`, for views).
//
// One limiter per kind for the process, built on first use so a test can set the
// variable first. A value that does not parse fails the request rather than
// falling back: a limit someone set and mistyped must not quietly become one they
// did not choose.

let limiters: dict<ReventlessCore.AnonymousLimiter.t> = Dict.make()

let configured = (
  ~kind: Reventless.AnonymousRequestLimit.kind,
): Reventless.AnonymousRequestLimit.t =>
  switch Reventless.AnonymousRequestLimit.fromSetting(
    ~kind,
    NodeProcess.env->Dict.get(Reventless.AnonymousRequestLimit.envKeyOf(kind)),
  ) {
  | Ok(limit) => limit
  | Error(message) => JsError.throwWithMessage(message)
  }

let current = (~kind): ReventlessCore.AnonymousLimiter.t => {
  let key = Reventless.AnonymousRequestLimit.envKeyOf(kind)
  switch limiters->Dict.get(key) {
  | Some(l) => l
  | None =>
    let l = ReventlessCore.AnonymousLimiter.make(~limit=configured(~kind))
    limiters->Dict.set(key, l)
    l
  }
}

/** Forget every count and re-read the configuration on next use. */
let reset = () =>
  limiters
  ->Dict.keysToArray
  ->Array.forEach(key => limiters->Dict.delete(key))

/** Whether one more request from `source` reaches `door`, a door or a view. */
let admit = (~kind, ~door: string, ~source: string): bool => current(~kind).admit(~door, ~source)
