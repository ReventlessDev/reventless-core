// CI routing guard for the DCB CommandTopic Lambda's Route 0 (InboundTranslation).
//
// The AppSync resolver for an InboundTranslationSlice mutation invokes the shared
// DCB command Lambda with `{__inboundTranslation, fieldName, arguments}` — no
// `command`, no `Records`. Before Route 0 existed the payload fell through to the
// SQS route and crashed on `event.records` being undefined ("Cannot read
// properties of undefined (reading 'length')"), so every inbound mutation 500'd
// on a deployed stack (docs/plans/done/aws-inbound-translation-lambda-routing.md).
// The gap that let this ship: `__inboundTranslation` was only ever asserted on the
// sending side (the resolver-template test). This pins the receiving end.
//
// Drives the real `buildHandlersForConfig` with an inbound slice module and a stub
// loader, then dispatches the payload exactly as `handler`'s Route 0 does. The
// fixture translation rejects its input, so the receiver returns CommandRejected
// inline without touching SQS or DynamoDB — no Docker needed, runs in CI.

open JestGlobals

let routeInbound: JSON.t => promise<JSON.t> = %raw(`
  async (event) => {
    const { buildHandlersForConfig } = await import(
      "@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs"
    );
    const loadModule = async (specifier) => {
      if (specifier === "ep-inbound-test://spec") return await import("./EpInboundTestSlice.res.mjs");
      if (specifier === "ep-inbound-test://translation") return await import("./EpInboundTestSliceTranslation.res.mjs");
      throw new Error("unknown test specifier: " + specifier);
    };
    const config = {
      pluginName: "EpInboundTestPlugin",
      dcbEventLogTableName: "ep-inbound-test-table",
      stateChangeSliceModules: [],
      queueUrl: "https://sqs.eu-west-1.amazonaws.com/000000000000/ep-inbound-test-queue",
      inboundTranslationSliceModules: [
        { spec: "ep-inbound-test://spec", translation: "ep-inbound-test://translation", auditTableName: null },
      ],
    };
    const [,,,, inboundReceivers] = await buildHandlersForConfig(config, { loadModule });
    // Mirror handler's Route 0 dispatch.
    const receiver = (inboundReceivers || {})[event.fieldName];
    if (receiver === undefined) throw new Error("no inbound receiver for " + event.fieldName);
    return await receiver(event.arguments);
  }
`)

let inboundEvent = (~fieldName, ~currency): JSON.t => {
  let arguments = Dict.fromArray([
    ("sku", "SKU-1"->JSON.Encode.string),
    ("currency", currency->JSON.Encode.string),
  ])
  Dict.fromArray([
    ("__inboundTranslation", true->JSON.Encode.bool),
    ("fieldName", fieldName->JSON.Encode.string),
    ("arguments", arguments->JSON.Encode.object),
  ])->JSON.Encode.object
}

describe("DcbCommandTopicEntryPoint Route 0 (InboundTranslation)", () => {
  test(
    "routes an __inboundTranslation payload to the slice's receive and encodes the outcome",
    async () => {
      // fieldName is `${pluginName}_${specName}` — the same string
      // Api_Naming.sliceMutationField produces at deploy time.
      let event = inboundEvent(~fieldName="EpInboundTestPlugin_EpInboundTest", ~currency="EUR")
      let outcome = await routeInbound(event)
      let s = outcome->JSON.stringifyAny->Option.getOr("<unserializable>")
      // A serializable outcome at all proves the payload no longer crashes on the
      // SQS route; the rejection proves it ran the slice's translate.
      expect(s->String.includes("CommandRejected"))->toBe(true)
      expect(s->String.includes("Unsupported currency"))->toBe(true)
    },
  )
})
