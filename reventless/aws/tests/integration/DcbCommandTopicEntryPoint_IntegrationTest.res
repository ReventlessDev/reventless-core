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

// Same as `runOneAppSyncEvent` but wires the composite-partition fixture
// (EpCompositeSlice) through the real entry point. Proves the deployed path
// derives and threads `partitionTag = Composite(...)` into the DynamoDB
// `append` — the fix for the residual burst-contention bug.
let runOneCompositeEvent: (string, JSON.t) => promise<JSON.t> = %raw(`
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
      if (specifier === "ep-composite://spec") return await import("./EpCompositeSlice.res.mjs");
      if (specifier === "ep-composite://behavior") return await import("./EpCompositeSliceBehavior.res.mjs");
      throw new Error("unknown test specifier: " + specifier);
    };

    const config = {
      pluginName: "EpCompositePlugin",
      dcbEventLogTableName: tableName,
      stateChangeSliceModules: [{ spec: "ep-composite://spec", behavior: "ep-composite://behavior" }],
      queueUrl: "https://sqs.eu-west-1.amazonaws.com/000000000000/ep-composite-queue",
    };

    const [, cmdGenHandler] = await buildHandlersForConfig(config, { loadModule });

    const effect = cmdGenHandler(event)
      .pipe(Effect.provideService(requestContextTag, { correlationId: "ep-composite" }));
    const outcome = await Effect.runPromise(effect);
    return commandOutcomeToJson(outcome);
  }
`)

let buildCompositeCommandEvent = (~command, ~environment, ~resourceName): JSON.t => {
  // `command` is the command type name as a plain string — the shape AppSync's
  // direct-invoke resolver sends and `CommandGenerator.payload.command: string`
  // expects.
  let arguments = Dict.fromArray([
    ("environment", environment->JSON.Encode.string),
    ("resourceName", resourceName->JSON.Encode.string),
  ])
  let meta = Dict.fromArray([
    ("user", "ep-composite"->JSON.Encode.string),
    ("ip", JSON.Encode.null),
  ])
  Dict.fromArray([
    ("command", command->JSON.Encode.string),
    ("arguments", arguments->JSON.Encode.object),
    ("meta", meta->JSON.Encode.object),
  ])->JSON.Encode.object
}

let buildAddResourceEvent = (~environment, ~resourceName): JSON.t =>
  buildCompositeCommandEvent(~command="AddResource", ~environment, ~resourceName)

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

  // Residual composite-fence burst contention
  // (docs/plans/done/dcb-composite-fence-residual-burst-contention.md).
  //
  // The entry point must derive `partitionTag = Composite(...)` and thread it
  // into the DynamoDB `append`, so a `@compositePartitionTag` slice collapses to
  // ONE synthetic composite fence per entity. Without the thread (the bug),
  // `partitionTag` defaults to None, the collapse never fires, and each append
  // fences on its individual members — the shared low-cardinality `environment`
  // member then serialises/rejects distinct resources.
  testAsync(
    "composite-partition burst: distinct resources sharing a prefix all commit, only composite fences written",
    async () => {
      let table = await H.createDcbTableWithTagKeys(
        "EpComposite_" ++ Date.now()->Float.toString,
        ["environment", "resourceName"],
      )
      let env = "prod"
      let resourceNames = ["res-a", "res-b", "res-c", "res-d", "res-e"]

      // Concurrent burst — simulates the deploy-sync fan-out that surfaced the
      // `retries exhausted` cascade on alpha.
      let outcomes =
        await resourceNames
        ->Array.map(resourceName =>
          runOneCompositeEvent(table.name, buildAddResourceEvent(~environment=env, ~resourceName))
        )
        ->Promise.all

      // Every distinct composite entity must commit — none may conflict on the
      // shared `environment` prefix.
      outcomes->Array.forEach(outcomeJson => {
        let s = outcomeJson->JSON.stringifyAny->Option.getOr("<unserializable>")
        expect(s->String.includes("CommandAccepted"))->toBe(true)
      })

      // Mechanism-level proof: the only fence rows are the synthetic composite
      // fences (`fence#__dcb_composite__:…`) — one per entity — with NO
      // per-member `fence#environment:…` / `fence#resourceName:…` rows.
      let fenceIds = await H.scanFenceIds(table)
      let compositeFencePrefix = "fence#" ++ DcbEventLogStorage_DynamoDb_Runtime.compositeFenceTagKey
      expect(fenceIds->Array.length)->toBe(resourceNames->Array.length)
      fenceIds->Array.forEach(id => expect(id->String.startsWith(compositeFencePrefix))->toBe(true))

      await H.deleteTable(table)
    },
  )

  // Composite read-back invariant
  // (docs/plans/done/dcb-composite-query-clause-fence-contention.md).
  //
  // A composite-partition slice must be able to READ BACK its own events. The
  // stored `tag_composite` key is computed from the event's tags; if the
  // framework `originatorSlice` provenance tag (appended by
  // StateChangeSlice_Callback.encodeEvent) leaks into that key, it diverges from
  // the read key (built from the command's entity tags only) and the composite
  // GSI read never matches — so a follow-up command reads empty state.
  //
  // `TouchResource` requires state `Added` (i.e. it must observe the prior
  // `ResourceAdded`) to succeed. With the bug the read misses → state `Absent` →
  // `NotFound` → CommandRejected. With the fix the read hits → `ResourceTouched`
  // is produced → CommandAccepted and a second event persists.
  testAsync(
    "composite read-back: a follow-up command sees the slice's own prior event",
    async () => {
      let table = await H.createDcbTableWithTagKeys(
        "EpCompositeRB_" ++ Date.now()->Float.toString,
        ["environment", "resourceName"],
      )
      let env = "prod"
      let res = "res-rb"

      let addOutcome = await runOneCompositeEvent(
        table.name,
        buildCompositeCommandEvent(~command="AddResource", ~environment=env, ~resourceName=res),
      )
      expect(
        addOutcome->JSON.stringifyAny->Option.getOr("")->String.includes("CommandAccepted"),
      )->toBe(true)

      let touchOutcome = await runOneCompositeEvent(
        table.name,
        buildCompositeCommandEvent(~command="TouchResource", ~environment=env, ~resourceName=res),
      )
      // The read must have observed the ResourceAdded — otherwise TouchResource
      // rejects NotFound (the originatorSlice-in-tag_composite regression).
      expect(
        touchOutcome->JSON.stringifyAny->Option.getOr("")->String.includes("CommandAccepted"),
      )->toBe(true)

      // Both events persisted: ResourceAdded + ResourceTouched.
      let events = await H.scanEventTypes(table)
      expect(events->Array.toSorted(String.compare))->toEqual(["ResourceAdded", "ResourceTouched"])

      await H.deleteTable(table)
    },
  )
})
