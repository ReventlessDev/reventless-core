/**
Logger service for Effect pipelines.

Any `Effect` with `'r = Logger.t` requires a `Logger` to be provided before running.
Provide at the handler entry point:
```rescript
myEffect
->Effect.provideService(Logger.tag, Logger.consoleLogger)
->Effect.runPromise
```

In tests, use `Logger.silent` to suppress all output:
```rescript
myEffect
->Effect.provideService(Logger.tag, Logger.silent)
->Effect.runPromise
```
*/

/** The logger service type — four log levels, each returning `Effect.t<unit>`. */
type t = {
  debug: string => Effect.t<unit, unit, unit>,
  info: string => Effect.t<unit, unit, unit>,
  warn: string => Effect.t<unit, unit, unit>,
  error: string => Effect.t<unit, unit, unit>,
}

/** The `Context.tag` for the `Logger` service — use with `Effect.serviceWith` and `Effect.provideService`. */
let tag: Context.tag<t> = Context.genericTag("reventless/Logger")

// ─── Built-in implementations ─────────────────────────────────────────────

/** A `Logger` implementation that writes to stdout/stderr via `Console`. */
let consoleLogger: t = {
  debug: msg => Effect.sync(() => Console.log(msg)),
  info: msg => Effect.sync(() => Console.log(msg)),
  warn: msg => Effect.sync(() => Console.warn(msg)),
  error: msg => Effect.sync(() => Console.error(msg)),
}

/** A `Logger` implementation that discards all messages — useful in tests to suppress log noise. */
let silent: t = {
  debug: _ => Effect.succeed(()),
  info: _ => Effect.succeed(()),
  warn: _ => Effect.succeed(()),
  error: _ => Effect.succeed(()),
}
