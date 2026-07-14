// StateViewSlice Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec modules,
// builds projection handler that decodes events and runs Projection.handleAction.
// Routes DynamoDB Stream events by source URN.

import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { parseJsonOrThrow } from "sury/src/S.res.mjs";
import { log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { handleAction } from "@reventlessdev/reventless-core/src/Projection.res.mjs";
// Typed cold-start core — DynamoDB QueryDb ops, compiler-checked against the
// framework signatures (see the module header and
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md).
import { makeDynamoQueryDbOps } from "./QueryDbEntryPoint_Ops.res.mjs";
import { opsFor as pgQdbOpsFor } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_Postgres_Runtime.res.mjs";
import { withLiveUpdates } from "./StateTopicPublish.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// Set at handler entry; read by runEffect to tag logs with the Lambda request id.
let _currentRequestId = "unknown";

function runEffect(correlationId, effect) {
  let e = effect
    // Promote correlationId/requestId/plugin to top-level JSON log fields —
    // decoded by EffectLogger.install() from Effect log annotations. Harmless
    // no-op if the unified logger isn't installed.
    .pipe(Effect.annotateLogs("correlationId", correlationId || "unknown"))
    .pipe(Effect.annotateLogs("requestId", _currentRequestId));
  if (pluginName) e = e.pipe(Effect.annotateLogs("plugin", pluginName));
  return e
    .pipe(Effect.provideService(requestContextTag, { correlationId: correlationId || "unknown" }))
    .pipe(Effect.runPromise);
}

function groupBySource(records) {
  const dict = {};
  records.forEach(record => {
    const arn = record.eventSourceARN;
    const existing = dict[arn] || [];
    dict[arn] = existing.concat([record]);
  });
  return dict;
}

// `pgConnection`, when present, selects the Postgres QueryDb runtime for this
// slice's view table (`queryDbTableName` is then the slice spec name, the shared
// `qdb_<name>` discriminator). Absent → the DynamoDB path is byte-identical.
export function buildJsonEventsHandler(specModule, projectionModule, queryDbTableName, pgConnection, stateTopicName) {
  let queryDbOps;
  if (pgConnection) {
    const indexes = (specModule.config && specModule.config.indexes) || [];
    const subIdField = specModule.subIdConfig ? specModule.subIdConfig.subIdField : undefined;
    const pgOps = pgQdbOpsFor(pgConnection, queryDbTableName, indexes, subIdField);
    // B3.3: subscription-enabled (Stream) Postgres view slice → publish a
    // live-update descriptor after save/delete. `stateTopicName` + APPSYNC_ENDPOINT
    // gate it; absent → withLiveUpdates passes pgOps through. The view slice's id
    // is the save's first arg (no id injection), so no wrap-ordering concern.
    queryDbOps = withLiveUpdates(pgOps, {
      endpoint: process.env.APPSYNC_ENDPOINT,
      region: process.env.AWS_REGION,
      topicName: stateTopicName,
      subIdField,
    });
  } else {
    queryDbOps = makeDynamoQueryDbOps(queryDbTableName);
  }
  // Spec module exports `consumedEventSchema`; the `project` function lives in
  // the sibling projection module (`<Name>_Projection.res`).
  const eventSchema = specModule.consumedEventSchema;
  const project = projectionModule.project;

  return stream => Stream.runForEach(
    Stream.flatMap(
      Stream.mapEffect(stream, json => Effect.sync(() => {
        try {
          const eventJson = json.event != null ? json.event : json;
          return project(parseJsonOrThrow(eventJson, eventSchema));
        } catch (exn) {
          log.error("failed to decode event", { comp: "StateViewSliceRuntime", detail: exn && exn.message ? exn.message : String(exn) });
          return [];
        }
      })),
      actions => Stream.fromIterable(actions)
    ),
    action => Effect.map(
      // Thread the slice's `subIdConfig` (generated from `@subId`) so sub-id-dependent
      // actions like `UpdateMultiState` can resolve the sort key. Dropping it here made
      // every such action hit the `MissingSubIdConfig` guard and silently write nothing,
      // while the test-harness callback path (which threads it) stayed green. `undefined`
      // for slices without an `@subId` is correct — those never emit sub-id actions.
      // First positional arg is the compiled `~comp=` optional (attribution
      // for Projection.handleAction's debug-lazy action log) — the slice's
      // spec name. Compiled shape: (comp, action, operations, subIdConfig).
      Effect.promise(() => handleAction(specModule.name, action, queryDbOps, specModule.subIdConfig)),
      _ => {}
    )
  );
}

// HANDLER_CONFIG is emitted compact (StateViewSliceRuntime_Builder_Single) to
// stay under AWS Lambda's 4KB env-var limit: a shared module-path `base` and a
// shared `sourceUrn` are hoisted out, and per-handler keys are shortened to
// s/p/q/u. Expand back to the full {specModule, projectionModule,
// queryDbTableName, sourceUrn} shape. Legacy full-key entries pass through.
function expandHandlers(config) {
  const base = config.base || "";
  const sharedUrn = config.sourceUrn || "";
  return (config.handlers || []).map(h => {
    if (h.specModule !== undefined) return h;
    return {
      specModule: base + h.s,
      projectionModule: base + h.p,
      queryDbTableName: h.q,
      sourceUrn: h.u !== undefined ? h.u : sharedUrn,
      // Shared across a plugin's slices (all follow the platform backend toggle);
      // hoisted to the top level of the compressed config like base/sourceUrn.
      pgConnection: config.pgConnection,
      // B3.3: per-slice AppSync Events channel root (list field name). Present
      // only for subscription-enabled (Stream) Postgres view slices.
      stateTopicName: h.t,
    };
  });
}

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const handlers = {};
  await Promise.all(expandHandlers(config).map(async h => {
    const [specModule, projectionModule] = await Promise.all([
      dynamicImport(h.specModule),
      dynamicImport(h.projectionModule),
    ]);
    const jsonEventsHandler = buildJsonEventsHandler(specModule, projectionModule, h.queryDbTableName, h.pgConnection, h.stateTopicName);
    const streamHandler = (event, context) => handleStreamEvent(jsonEventsHandler, event, context);
    const existing = handlers[h.sourceUrn] || [];
    existing.push(streamHandler);
    handlers[h.sourceUrn] = existing;
  }));
  return handlers;
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  _currentRequestId = context?.awsRequestId || "unknown";
  const handlers = await initPromise;
  const records = event.Records || [];
  const grouped = groupBySource(records);

  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const streamHandlers = handlers[arn];
    if (streamHandlers !== undefined && streamHandlers.length > 0) {
      log.debug("found " + streamHandlers.length + " handler(s) for " + arn, { comp: "StateViewSliceRuntime" });
      await Promise.all(streamHandlers.map(h =>
        runEffect(undefined, h({ Records: subRecords }, context))
      ));
    } else {
      log.warn("no handler found: " + arn, { comp: "StateViewSliceRuntime" });
    }
  }));
  return "";
}
