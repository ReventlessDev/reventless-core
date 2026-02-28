// Logger service for Effect pipelines.
//
// Any Effect with 'r = Logger.t requires a Logger to be provided before running.
// Provide at the handler entry point:
//   myEffect->Effect.provideService(Logger.tag, Logger.consoleLogger)->Effect.runPromise
//
// In tests, use Logger.silent to suppress all output:
//   myEffect->Effect.provideService(Logger.tag, Logger.silent)->Effect.runPromise

type t = {
  debug: string => Effect.t<unit, unit, unit>,
  info: string => Effect.t<unit, unit, unit>,
  warn: string => Effect.t<unit, unit, unit>,
  error: string => Effect.t<unit, unit, unit>,
}

// The tag — used with serviceWith/provideService
let tag: Context.tag<t> = Context.genericTag("reventless/Logger")

// ─── Built-in implementations ─────────────────────────────────────────────

// Writes to stdout/stderr via Console
let consoleLogger: t = {
  debug: msg => Effect.sync(() => Console.log(msg)),
  info: msg => Effect.sync(() => Console.log(msg)),
  warn: msg => Effect.sync(() => Console.warn(msg)),
  error: msg => Effect.sync(() => Console.error(msg)),
}

// Discards all messages — use in tests where log noise is unwanted
let silent: t = {
  debug: _ => Effect.succeed(()),
  info: _ => Effect.succeed(()),
  warn: _ => Effect.succeed(()),
  error: _ => Effect.succeed(()),
}
