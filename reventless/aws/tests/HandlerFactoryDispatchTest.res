// Regression guard for the deployed entry points' dispatch boundary.
//
// `HandlerFactoryHelpers.mjs` is the single place where every Lambda invocation
// gets its log annotations and its `RequestContext` — the AWS counterpart of
// ReventlessCore.Runtime.annotateInvocation, which does not run in a Lambda (the
// runtime builders take `~handler as _` and deploy the .mjs shell instead). Two
// things here are checkable only from JS and break silently otherwise:
//
//   1. `RequestContext.fromOptions` is called across the ReScript/JS seam. A
//      labelled-argument constructor compiles to positional arguments, so an
//      inserted field would silently shift every value; `fromOptions` takes one
//      options object precisely to avoid that, and this test fails if the shell
//      and the record ever disagree.
//   2. The transport extractors read two different record shapes — SQS (`body`
//      envelope + `attributes`) and DynamoDB streams (flat top-level meta
//      attributes on `NewImage` + `ApproximateCreationDateTime` in *seconds*).
//
// See docs/plans/entrypoint-dispatch-parity-and-latency-fields.md.

open JestGlobals

// ─── The shell under test ───────────────────────────────────────────────────

type dispatchOptions = {
  correlationId?: string,
  causationId?: string,
  comp?: string,
  plugin?: string,
  timestamp?: float,
  retryCount?: int,
}

@module("@reventlessdev/reventless-aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs")
external runEffect: (Effect.t<'a, 'e, 'r>, dispatchOptions) => promise<'a> = "runEffect"

@module("@reventlessdev/reventless-aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs")
external setRequestId: string => unit = "setRequestId"

@module("@reventlessdev/reventless-aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs")
external extractMetaField: (array<'record>, string) => option<string> = "extractMetaField"

@module("@reventlessdev/reventless-aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs")
external extractSentTimestamp: array<'record> => option<float> = "extractSentTimestamp"

@module("@reventlessdev/reventless-aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs")
external extractRetryCount: array<'record> => int = "extractRetryCount"

// ─── Record fixtures, typed rather than cast ────────────────────────────────

type sqsAttributes = {
  @as("SentTimestamp") sentTimestamp: string,
  @as("ApproximateReceiveCount") approximateReceiveCount: string,
}
type sqsRecord = {body: string, attributes: sqsAttributes}
type bodyOnlyRecord = {body: string}

type streamAttribute = {@as("S") s: string}
type streamImage = {correlationId: streamAttribute, causationId: streamAttribute}
type streamPayload = {
  @as("NewImage") newImage: streamImage,
  @as("ApproximateCreationDateTime") approximateCreationDateTime: float,
}
type streamRecord = {dynamodb: streamPayload}

let sqsRecords = [
  {
    body: `{"meta":{"correlationId":"corr-1","causationId":"cause-1"}}`,
    attributes: {sentTimestamp: "1750000000000", approximateReceiveCount: "3"},
  },
]

let streamRecords = [
  {
    dynamodb: {
      newImage: {correlationId: {s: "corr-2"}, causationId: {s: "cause-2"}},
      approximateCreationDateTime: 1750000001.0,
    },
  },
]

// Read back what the dispatch boundary provided, so the assertions see exactly
// what an application handler would.
let capture = (): Effect.t<ReventlessCore.RequestContext.t, string, _> =>
  Effect.serviceWith(ReventlessCore.RequestContext.tag, ctx => ctx)

describe("entry-point dispatch boundary", () => {
  describe("SQS records", () => {
    testSync("reads the envelope out of the body", () => {
      expect(extractMetaField(sqsRecords, "correlationId"))->Expect.toEqual(Some("corr-1"))
      expect(extractMetaField(sqsRecords, "causationId"))->Expect.toEqual(Some("cause-1"))
    })

    testSync("reads SentTimestamp as ms since epoch", () =>
      expect(extractSentTimestamp(sqsRecords))->Expect.toEqual(Some(1750000000000.0))
    )

    testSync("reads ApproximateReceiveCount as the delivery attempt", () =>
      expect(extractRetryCount(sqsRecords))->Expect.toBe(3)
    )
  })

  describe("DynamoDB stream records", () => {
    // EventLog rows store meta keys flat as top-level attributes
    // (Message.composeMeta rebuilds `meta` from them) — not as a nested map.
    testSync("reads the envelope off the flat NewImage attributes", () => {
      expect(extractMetaField(streamRecords, "correlationId"))->Expect.toEqual(Some("corr-2"))
      expect(extractMetaField(streamRecords, "causationId"))->Expect.toEqual(Some("cause-2"))
    })

    testSync("converts ApproximateCreationDateTime from seconds to ms", () =>
      expect(extractSentTimestamp(streamRecords))->Expect.toEqual(Some(1750000001000.0))
    )

    testSync("reports a first delivery — streams have no receive count", () =>
      expect(extractRetryCount(streamRecords))->Expect.toBe(1)
    )
  })

  describe("absent or malformed input", () => {
    testSync("an empty batch has no send time", () =>
      expect(extractSentTimestamp([]))->Expect.toEqual(None)
    )

    testSync("an unparseable body yields no envelope field", () =>
      expect(extractMetaField([{body: "not json"}], "correlationId"))->Expect.toEqual(None)
    )
  })

  describe("RequestContext provided at dispatch", () => {
    test("carries the full record, not a bare correlationId literal", async () => {
      let ctx = await runEffect(
        capture(),
        {
          correlationId: "corr-1",
          causationId: "cause-1",
          comp: "AggregateRuntime(Customer)",
          plugin: "Catalog",
          timestamp: 1750000000000.0,
          retryCount: 3,
        },
      )
      expect(ctx.correlationId)->Expect.toBe("corr-1")
      expect(ctx.causationId)->Expect.toEqual(Some("cause-1"))
      expect(ctx.component)->Expect.toEqual(Some("AggregateRuntime(Customer)"))
      expect(ctx.pluginName)->Expect.toEqual(Some("Catalog"))
      expect(ctx.timestamp)->Expect.toEqual(Some(1750000000000.0))
      expect(ctx.retryCount)->Expect.toEqual(Some(3))
    })

    test("fills identity and claims, which the record declares non-optional", async () => {
      let ctx = await runEffect(capture(), {correlationId: "corr-1"})
      expect(ctx.identity.userId)->Expect.toBe(Reventless.Identity.anonymous.userId)
      expect(ctx.claims->Dict.keysToArray)->Expect.toEqual([])
    })

    test("falls back to a placeholder when no correlationId is on the message", async () => {
      let ctx = await runEffect(capture(), {comp: "X(Y)"})
      expect(ctx.correlationId)->Expect.toBe("unknown")
    })
  })

  describe("log annotations", () => {
    // Effect keeps annotations in a HashMap; read it as a dict.
    let annotations = (): Effect.t<Effect.logAnnotationMap, string, _> => Effect.logAnnotations

    test("promotes comp, causationId and the request id onto every line", async () => {
      setRequestId("req-abc")
      let annotated = await runEffect(
        annotations(),
        {correlationId: "corr-1", causationId: "cause-1", comp: "EventCollector(Customers)"},
      )
      let annotated = annotated->Effect.annotationsToDict
      expect(annotated->Dict.get("comp"))->Expect.toEqual(Some("EventCollector(Customers)"))
      expect(annotated->Dict.get("causationId"))->Expect.toEqual(Some("cause-1"))
      expect(annotated->Dict.get("correlationId"))->Expect.toEqual(Some("corr-1"))
      expect(annotated->Dict.get("requestId"))->Expect.toEqual(Some("req-abc"))
    })

    // A constant "1" on every line is noise; its absence is what makes
    // `filter retryCount > 1` a usable CloudWatch query.
    test("annotates retryCount only on a redelivery", async () => {
      let first = await runEffect(annotations(), {correlationId: "c", retryCount: 1})
      expect(first->Effect.annotationsToDict->Dict.get("retryCount"))->Expect.toEqual(None)
      let redelivered = await runEffect(annotations(), {correlationId: "c", retryCount: 2})
      expect(redelivered->Effect.annotationsToDict->Dict.get("retryCount"))->Expect.toEqual(
        Some("2"),
      )
    })
  })
})
