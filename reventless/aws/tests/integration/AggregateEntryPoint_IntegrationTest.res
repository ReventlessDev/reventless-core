// Integration regression guard for the Aggregate Lambda entry point.
//
// Drives the real `AggregateEntryPoint.mjs` against a DynamoDB Local EventLog
// table, with a test loader supplying a tiny `AggTestAggregate` spec/behavior
// pair in place of the production Lambda's `/var/task/node_modules` dynamic
// import. Covers the same regression class as the DCB entry-point test: the
// shell wires the compiled EventLog/Aggregate/CommandTopic functors and the
// CommandGenerator by structural contract, so any drift between the JS caller
// and the ReScript-compiled shapes (a renamed callback field, a shifted arg)
// re-breaks the AppSync command path. This test fails it as
// CommandAccepted -> Lambda:Unhandled.
//
// This is also the harness that unblocks moving the Aggregate functor wiring
// behind a typed core (docs/plans/minimize-lambda-entrypoint-mjs-shell.md,
// Tier 2.5): with it green, that refactor is verifiable end-to-end rather than
// only at compile time. Boots via the same Docker-gated
// `pnpm run test:integration` suite as the storage-runtime tests.

open JestGlobals

module H = AggIntegrationHarness

// Build handlers via the entry point's exported factory, dispatch one AppSync
// direct-invoke event, run the returned Effect through the request context the
// production handler supplies, and return the AppSync-shape outcome JSON.
let runOneAppSyncEvent: (string, JSON.t) => promise<JSON.t> = %raw(`
  async (tableName, event) => {
    const { buildHandlersForConfig } = await import(
      "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs"
    );
    const Effect = await import("effect/Effect");
    const { tag: requestContextTag } = await import(
      "@reventlessdev/reventless-core/src/RequestContext.res.mjs"
    );
    const { commandOutcomeToJson } = await import(
      "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res.mjs"
    );

    const loadModule = async (specifier) => {
      if (specifier === "agg-test://spec") return await import("./AggTestAggregate.res.mjs");
      if (specifier === "agg-test://behavior") return await import("./AggTestAggregateBehavior.res.mjs");
      throw new Error("unknown test specifier: " + specifier);
    };

    const config = {
      handlers: [{
        specModule: "agg-test://spec",
        behaviorModule: "agg-test://behavior",
        eventLogTable: tableName,
        queueUrl: "https://sqs.eu-west-1.amazonaws.com/000000000000/agg-test-queue",
        queueArn: "arn:aws:sqs:eu-west-1:000000000000:agg-test-queue",
      }],
    };

    const [, cmdGenHandlers] = await buildHandlersForConfig(config, { loadModule });
    const cmdGenHandler = cmdGenHandlers["AggTestAggregate"];

    const effect = cmdGenHandler(event, {})
      .pipe(Effect.provideService(requestContextTag, { correlationId: "agg-test" }));
    const outcome = await Effect.runPromise(effect);
    return commandOutcomeToJson(outcome);
  }
`)

// CommandGenerator payload: `{command, arguments, meta}` — the shape AppSync's
// direct-invoke resolver sends. `command` is the constructor name as a string;
// `arguments.id` is the aggregate/EventLog id (stripped from the command params
// by makeGenerateCommand's stripIdFromParams).
let buildAppSyncEvent = (~id, ~name): JSON.t => {
  let arguments = Dict.fromArray([
    ("id", id->JSON.Encode.string),
    ("name", name->JSON.Encode.string),
  ])
  let meta = Dict.fromArray([
    ("user", "agg-test"->JSON.Encode.string),
    ("ip", JSON.Encode.null),
  ])
  Dict.fromArray([
    ("command", "Add"->JSON.Encode.string),
    ("arguments", arguments->JSON.Encode.object),
    ("meta", meta->JSON.Encode.object),
  ])->JSON.Encode.object
}

describe("AggregateEntryPoint integration", () => {
  testAsync(
    "AppSync direct-invoke routes through the runtime handler to CommandAccepted",
    async () => {
      // Own table-name prefix avoids collisions when sharing a DDB Local
      // instance with sibling suites.
      let table = await H.createEventLogTable("AggIt_" ++ Date.now()->Float.toString)
      let event = buildAppSyncEvent(~id="agg-1", ~name="Widget One")
      let outcomeJson = await runOneAppSyncEvent(table.name, event)

      // A functor/arg-shape drift manifests as a thrown error from `runPromise`
      // before `commandOutcomeToJson` runs, so reaching this assertion already
      // proves the regression hasn't returned; we still assert CommandAccepted
      // so a drift to silent rejection also fails.
      let s = outcomeJson->JSON.stringifyAny->Option.getOr("<unserializable>")
      expect(s->String.includes("CommandAccepted"))->toBe(true)
    },
  )
})
