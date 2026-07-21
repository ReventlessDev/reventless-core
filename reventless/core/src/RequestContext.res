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
//
// `timestamp` = when the triggering message was *sent* (ms since epoch), not when
// this handler started: SQS `SentTimestamp`, a DynamoDB stream record's
// `ApproximateCreationDateTime`, or dispatch time in-process. A handler computes
// end-to-end latency from it without calling `Date.now()` itself, and the value
// includes queue dwell — which a handler-local clock cannot see.
// `retryCount` = delivery attempt, 1 on first delivery (SQS
// `ApproximateReceiveCount`; always 1 where the transport has no redelivery).
//
// All optional fields are absent in `.test()` and wherever the dispatch site has
// no value to supply.
type t = {
  correlationId: string,
  causationId?: string,
  component?: string,
  pluginName?: string,
  timestamp?: float,
  retryCount?: int,
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
  ~timestamp=?,
  ~retryCount=?,
  ~identity=Reventless.Identity.anonymous,
  ~claims=Dict.make(),
): t => {
  correlationId,
  causationId: ?causationId,
  component: ?component,
  pluginName: ?pluginName,
  timestamp: ?timestamp,
  retryCount: ?retryCount,
  identity,
  claims,
}

// JS-facing constructor for the hand-written Lambda entry-point shells
// (HandlerFactoryHelpers.mjs). `make`'s labelled arguments compile to *positional*
// ones, so a JS caller breaks silently the moment an argument is inserted; this
// takes a single options object whose field names survive compilation and stay
// compiler-checked here. Every field is optional so a shell can supply only what
// its transport actually carries.
type options = {
  correlationId?: string,
  causationId?: string,
  component?: string,
  pluginName?: string,
  timestamp?: float,
  retryCount?: int,
}

let fromOptions = (o: options): t =>
  make(
    ~correlationId=o.correlationId->Option.getOr("unknown"),
    ~causationId=?o.causationId,
    ~component=?o.component,
    ~pluginName=?o.pluginName,
    ~timestamp=?o.timestamp,
    ~retryCount=?o.retryCount,
  )

let getClaim = (ctx: t, key: string): option<string> =>
  ctx.claims->Dict.get(key)

let withClaim = (ctx: t, key: string, value: string): t => {
  let next = ctx.claims->Dict.toArray->Dict.fromArray
  next->Dict.set(key, value)
  {...ctx, claims: next}
}

let test = (
  ~correlationId="test-correlation-id",
  ~timestamp=?,
  ~retryCount=?,
  ~identity=Reventless.Identity.anonymous,
  ~claims=Dict.make(),
): t => {
  correlationId,
  timestamp: ?timestamp,
  retryCount: ?retryCount,
  identity,
  claims,
}
