// What a handler dispatched on the in-process platform sees in its RequestContext.
//
// The counterpart of reventless-aws's HandlerFactoryDispatchTest: that one covers
// the deployed entry-point shim, this one covers `Runtime.runEffectHandler` wired
// with `LocalRuntimeEnvironment`'s extractors — the exact composition every local
// runtime builder uses (LocalEventCollectorRuntime_Builder,
// LocalAggregateRuntime_Builder). Without it, the local half of "a handler can
// compute latency from RequestContext.timestamp and branch on retryCount on both
// platforms" rests on the extractors merely compiling.
//
// See docs/plans/entrypoint-dispatch-parity-and-latency-fields.md.

open JestGlobals

let _ = TestRunner.setup()

// Hand the provided context back as the handler's result — the assertions then
// see exactly what an application handler would.
let capture = (_event, _ctx) =>
  Effect.serviceWith(ReventlessCore.RequestContext.tag, ctx => ctx)

let comp = "EventCollector(TestCollector)"

let dispatch = (event: JSON.t): promise<ReventlessCore.RequestContext.t> => {
  let handler =
    capture
    ->LocalRuntimeEnvironment.asEffectHandler
    ->ReventlessCore.Runtime.runEffectHandler(
      ~extractCorrelationId=LocalRuntimeEnvironment.extractCorrelationId,
      ~extractCausationId=LocalRuntimeEnvironment.extractCausationId,
      ~extractSentTimestamp=LocalRuntimeEnvironment.extractSentTimestamp,
      ~extractRetryCount=LocalRuntimeEnvironment.extractRetryCount,
      ~comp,
    )
  handler(event, ())
}

let eventWithMeta = (~correlationId, ~causationId=?, ()) => {
  let meta = Dict.fromArray([("correlationId", correlationId->JSON.Encode.string)])
  switch causationId {
  | Some(id) => meta->Dict.set("causationId", id->JSON.Encode.string)
  | None => ()
  }
  Dict.fromArray([("meta", meta->JSON.Encode.object)])->JSON.Encode.object
}

describe("local dispatch boundary", () => {
  testPromise("carries the envelope identity through to the handler", async () => {
    let ctx = await dispatch(
      eventWithMeta(~correlationId="corr-local", ~causationId="cause-local", ()),
    )
    expect(ctx.correlationId)->toBe("corr-local")
    expect(ctx.causationId)->toEqual(Some("cause-local"))
    expect(ctx.component)->toEqual(Some(comp))
  })

  testPromise("falls back to a placeholder when the event carries no correlationId", async () => {
    let ctx = await dispatch(JSON.Encode.object(Dict.make()))
    expect(ctx.correlationId)->toBe("unknown")
    expect(ctx.causationId)->toEqual(None)
  })

  // In-process dispatch has no queue to dwell in, so send time *is* dispatch
  // time — a handler computing `now - timestamp` measures its own processing
  // latency here and end-to-end latency on a queue-backed platform, from the
  // same expression.
  testPromise("supplies a send time a handler can measure latency against", async () => {
    let before = Date.now()
    let ctx = await dispatch(eventWithMeta(~correlationId="corr-local", ()))
    let after = Date.now()
    switch ctx.timestamp {
    | Some(t) => expect(t >= before && t <= after)->toBe(true)
    | None => fail("expected RequestContext.timestamp to be populated on the local platform")
    }
  })

  // The bus calls each handler once; a handler branching on redelivery must see
  // a first delivery here rather than a missing field.
  testPromise("reports a first delivery", async () => {
    let ctx = await dispatch(eventWithMeta(~correlationId="corr-local", ()))
    expect(ctx.retryCount)->toEqual(Some(1))
  })
})
