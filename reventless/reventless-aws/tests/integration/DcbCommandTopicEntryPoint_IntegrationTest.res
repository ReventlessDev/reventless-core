// Integration regression guard for the DCB CommandTopic Lambda entry point.
//
// Drives the real `DcbCommandTopicEntryPoint.mjs` against a DynamoDB Local
// table, with a test loader supplying a tiny `EpTestSlice` spec/behavior pair
// in place of the production Lambda's `/var/task/node_modules` dynamic import.
// Covers the regression class behind the 2026-06-21 incident: the entry point
// was passing the wrong number of positional args to ReScript-compiled
// `StateChangeSlice_Callback.handleCommands`, so `stream` landed as undefined
// and the Lambda crashed inside Effect's `Stream.mapEffect` with
// `'channel' in undefined`. Any future arity drift between the JS caller and
// the ReScript signature (e.g. a new optional labelled arg added before the
// positional ones) re-breaks the same path; this test fails it as
// CommandAccepted → Lambda:Unhandled.
//
// Boots via the same `pnpm run test:integration` Docker-gated suite as the
// storage-runtime integration tests; harnessed by `DcbIntegrationHarness`.

open JestGlobals

module H = DcbIntegrationHarness

// `cmdGenHandler(event)` returns an Effect that must be runPromise'd through
// the request context the production handler supplies. This raw helper drives
// the full real pipeline: build handlers via the entry point's exported
// factory, dispatch one AppSync event, run the Effect, return the AppSync-
// shape outcome JSON.
let runOneAppSyncEvent: (string, JSON.t) => promise<JSON.t> = %raw(`
  async (tableName, event) => {
    const { buildHandlersForConfig } = await import(
      "@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs"
    );
    const Effect = await import("effect/Effect");
    const { tag: requestContextTag } = await import(
      "@reventlessdev/reventless-core/src/RequestContext.res.mjs"
    );
    const { commandOutcomeToJson } = await import(
      "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res.mjs"
    );

    const loadModule = async (specifier) => {
      if (specifier === "ep-test://spec") return await import("./EpTestSlice.res.mjs");
      if (specifier === "ep-test://behavior") return await import("./EpTestSliceBehavior.res.mjs");
      throw new Error("unknown test specifier: " + specifier);
    };

    const config = {
      pluginName: "EpTestPlugin",
      dcbEventLogTableName: tableName,
      stateChangeSliceModules: [{ spec: "ep-test://spec", behavior: "ep-test://behavior" }],
      queueUrl: "https://sqs.eu-west-1.amazonaws.com/000000000000/ep-test-queue",
    };

    const [, cmdGenHandler] = await buildHandlersForConfig(config, { loadModule });

    const effect = cmdGenHandler(event)
      .pipe(Effect.provideService(requestContextTag, { correlationId: "ep-test" }));
    const outcome = await Effect.runPromise(effect);
    return commandOutcomeToJson(outcome);
  }
`)

let buildAppSyncEvent = (widgetId): JSON.t => {
  // CommandGenerator payload: `{command, arguments, meta, identity?}` — the
  // exact shape AppSync's direct-invoke resolver sends (matches the resolver
  // template in `DcbCmdHandlerResolver_GraphQL.res`).
  let command = Dict.fromArray([("AddWidget", Dict.make()->JSON.Encode.object)])
  let arguments = Dict.fromArray([("widgetId", widgetId->JSON.Encode.string)])
  let meta = Dict.fromArray([
    ("user", "ep-test"->JSON.Encode.string),
    ("ip", JSON.Encode.null),
  ])
  Dict.fromArray([
    ("command", command->JSON.Encode.object),
    ("arguments", arguments->JSON.Encode.object),
    ("meta", meta->JSON.Encode.object),
  ])->JSON.Encode.object
}

describe("DcbCommandTopicEntryPoint integration", () => {
  testAsync(
    "AppSync direct-invoke routes through the runtime handler to CommandAccepted",
    async () => {
      // Own table-name prefix avoids `ResourceInUseException` when the test
      // shares a DDB Local instance with sibling suites that also use the
      // harness's `DcbItTest_N` counter.
      let table = await H.createDcbTable("EpTest_" ++ Date.now()->Float.toString)
      let event = buildAppSyncEvent("widget-1")
      let outcomeJson = await runOneAppSyncEvent(table.name, event)

      // `commandOutcomeToJson` produces an AppSync-shape envelope:
      //   { __typename: "CommandAccepted" | "CommandRejected" | "CommandPending", ... }
      // The arity bug surfaces as `Lambda:Unhandled` at the AppSync layer —
      // here it would manifest as a thrown error from `runPromise` before
      // `commandOutcomeToJson` ever runs, so reaching this assertion at all
      // already proves the regression hasn't returned. We still assert on
      // `CommandAccepted` so a future drift to silent-rejection also fails.
      let s = outcomeJson->JSON.stringifyAny->Option.getOr("<unserializable>")
      expect(s->String.includes("CommandAccepted"))->toBe(true)
    },
  )
})
