// The local platform's limit on doors and views open to callers who are not
// signed in: requests per source address per window, each kind read from its own
// variable (`REVENTLESS_ANONYMOUS_REQUEST_LIMIT` for doors,
// `REVENTLESS_ANONYMOUS_VIEW_LIMIT` for views). Unset, nothing is limited: the
// local platform is where an app is built, and a limit there only gets in the way
// of the person building it. Set one to try the limit out.
//
// One limiter per kind for the process, built on first use so a test can set the
// variable first. A value that does not parse fails the request rather than
// falling back: a limit someone set and mistyped must not quietly become one they
// did not choose.

let limiters: dict<ReventlessCore.AnonymousLimiter.t> = Dict.make()

/** The limit set for `kind`, or none where its variable is unset or empty. */
let configured = (~kind: Reventless.AnonymousRequestLimit.kind): option<
  Reventless.AnonymousRequestLimit.t,
> =>
  switch NodeProcess.env->Dict.get(Reventless.AnonymousRequestLimit.envKeyOf(kind)) {
  | None | Some("") => None
  | Some(raw) =>
    switch Reventless.AnonymousRequestLimit.parse(~kind, raw) {
    | Ok(limit) => Some(limit)
    | Error(message) => JsError.throwWithMessage(message)
    }
  }

let current = (~kind): option<ReventlessCore.AnonymousLimiter.t> => {
  let key = Reventless.AnonymousRequestLimit.envKeyOf(kind)
  switch limiters->Dict.get(key) {
  | Some(l) => Some(l)
  | None =>
    configured(~kind)->Option.map(limit => {
      let l = ReventlessCore.AnonymousLimiter.make(~limit)
      limiters->Dict.set(key, l)
      l
    })
  }
}

/** Forget every count and re-read the configuration on next use. */
let reset = () =>
  limiters
  ->Dict.keysToArray
  ->Array.forEach(key => limiters->Dict.delete(key))

/** Whether one more request from `source` reaches `door`, a door or a view: always,
    where no limit is set for its kind. */
let admit = (~kind, ~door: string, ~source: string): bool =>
  current(~kind)->Option.mapOr(true, l => l.admit(~door, ~source))
