// RequestContext service — carries per-invocation data through an Effect pipeline
// without explicit argument threading.
//
// Populated at the Lambda handler entry point from the incoming event's meta field.
// All Effects that need correlationId use serviceWith(RequestContext.tag, ...)
// instead of accepting them as function arguments.
//
// Provide in Lambda handler:
//   let ctx = { correlationId: event.meta.correlationId }
//   myEffect
//   ->Effect.provideService(RequestContext.tag, ctx)
//   ->Effect.provideService(Logger.tag, Logger.consoleLogger)
//   ->Effect.runPromise
//
// In tests:
//   ->Effect.provideService(RequestContext.tag, RequestContext.test())

type t = {
  correlationId: string,
  // Extend with tenantId, userId, traceId as multi-tenancy needs arise
}

let tag: Context.tag<t> = Context.genericTag("reventless/RequestContext")

// Convenience constructor for tests
let test = (~correlationId="test-correlation-id"): t => {
  correlationId: correlationId,
}
