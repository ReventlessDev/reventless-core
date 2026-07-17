// RequestContext service — carries per-invocation data through an Effect pipeline
// without explicit argument threading.
//
// Populated at the Lambda handler entry point from the incoming event's meta field.
// All Effects that need correlationId or identity use serviceWith(RequestContext.tag, ...)
// instead of accepting them as function arguments.
//
// Provide in Lambda handler:
//   let ctx = { correlationId: event.meta.correlationId, identity: Identity.anonymous, claims: Dict.make() }
//   myEffect
//   ->Effect.provideService(RequestContext.tag, ctx)
//   ->Effect.runPromise
//
// In tests:
//   ->Effect.provideService(RequestContext.tag, RequestContext.test())

type t = {
  correlationId: string,
  identity: Reventless.Identity.t,
  claims: dict<string>,
}

let tag: Context.tag<t> = Context.genericTag("reventless/RequestContext")

let getClaim = (ctx: t, key: string): option<string> =>
  ctx.claims->Dict.get(key)

let withClaim = (ctx: t, key: string, value: string): t => {
  let next = ctx.claims->Dict.toArray->Dict.fromArray
  next->Dict.set(key, value)
  {...ctx, claims: next}
}

let test = (
  ~correlationId="test-correlation-id",
  ~identity=Reventless.Identity.anonymous,
  ~claims=Dict.make(),
): t => {
  correlationId,
  identity,
  claims,
}
