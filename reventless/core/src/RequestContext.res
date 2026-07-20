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

// `causationId` = the direct-parent msgId of the message that triggered this
// invocation (Message.deriveMeta propagates it); reconstructs the parent → child
// causal chain within one `correlationId`. `component` / `pluginName` identify the
// component and plugin handling the invocation — mirror the `comp` / `plugin` log
// fields so a consumer of this service sees the same attribution the logs carry.
// All three are optional: absent in `.test()` and wherever the dispatch site has
// no value to supply.
type t = {
  correlationId: string,
  causationId?: string,
  component?: string,
  pluginName?: string,
  identity: Reventless.Identity.t,
  claims: dict<string>,
}

let tag: Context.tag<t> = Context.genericTag("reventless/RequestContext")

// Real dispatch-boundary constructor. Use this at runtime dispatch points
// (see Runtime.runEffect); `test` is test-only.
let make = (
  ~correlationId,
  ~causationId=?,
  ~component=?,
  ~pluginName=?,
  ~identity=Reventless.Identity.anonymous,
  ~claims=Dict.make(),
): t => {
  correlationId,
  causationId: ?causationId,
  component: ?component,
  pluginName: ?pluginName,
  identity,
  claims,
}

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
