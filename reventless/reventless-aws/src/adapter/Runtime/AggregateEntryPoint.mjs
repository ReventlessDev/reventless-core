// Aggregate Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec+Behavior modules,
// wires EventLog_Operations, Aggregate_Callback, CommandTopic_Callback.
// Handles both SQS CommandTopic events (Route 2) and AppSync direct invocation (Route 1).

import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef, log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as eventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/EventLog/EventLog_Operations.res.mjs";
import { Make as aggregateCallbackMake } from "@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { makeGenerateCommand } from "@reventlessdev/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res.mjs";
import { commandOutcomeToJson, runInlineAndCollect } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res.mjs";
import { append, replay, replayStream, appendStream } from "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs";
import { opsFor as pgEventLogOpsFor } from "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_Postgres_Runtime.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { DynamoDBClient, ScanCommand } from "@aws-sdk/client-dynamodb";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// ---------------------------------------------------------------------------
// Plugin status gate — mirrors CommandGeneratorResolvers_GraphQL.checkPluginStatus.
// Rejects mutations on plugins whose Plugin RM `status` is not `Connected`,
// returning the split error codes from docs/analysis/plugin-lifecycle-tiers.md:
//   Disconnected → PluginUnavailable (tier 1, retryable)
//   Inactive     → PluginInactive    (tier 2, admin-controlled)
//   Retired      → PluginRetired     (tier 2, admin-archived version)
// Platform_* admin mutations bypass the gate. Disabled silently if
// PLUGIN_RM_TABLE_NAME env var is not set.
// ---------------------------------------------------------------------------

const PLUGIN_RM_TABLE_NAME = process.env["PLUGIN_RM_TABLE_NAME"];
const PLUGIN_RM_CACHE_TTL_MS = parseInt(process.env["PLUGIN_RM_CACHE_TTL_MS"] || "5000", 10);
const ddbClient = PLUGIN_RM_TABLE_NAME ? new DynamoDBClient({}) : null;

let pluginStatusCache = null;
let pluginStatusCacheExpiresAt = 0;

async function loadPluginStatuses() {
  const now = Date.now();
  if (pluginStatusCache !== null && now < pluginStatusCacheExpiresAt) {
    return pluginStatusCache;
  }
  const dict = {};
  let exclusiveStartKey = undefined;
  do {
    const res = await ddbClient.send(new ScanCommand({
      TableName: PLUGIN_RM_TABLE_NAME,
      Limit: 1000,
      ExclusiveStartKey: exclusiveStartKey,
    }));
    for (const raw of res.Items || []) {
      try {
        const item = unmarshall(raw);
        if (typeof item.name === "string" && typeof item.status === "string") {
          dict[item.name] = item.status;
        }
      } catch (_) {}
    }
    exclusiveStartKey = res.LastEvaluatedKey;
  } while (exclusiveStartKey);
  pluginStatusCache = dict;
  pluginStatusCacheExpiresAt = now + PLUGIN_RM_CACHE_TTL_MS;
  return dict;
}

function extractFieldName(event) {
  // AppSync resolver template populates `event.meta.info` with
  // `${parentTypeName}.${fieldName}` (see AppSync_Resolver_Functions.invokeCommandGenerator).
  const info = event?.meta?.info;
  if (typeof info !== "string") return null;
  const dot = info.indexOf(".");
  return dot >= 0 ? info.slice(dot + 1) : info;
}

function pluginRejection(msgId, errorCode, detail) {
  return {
    __typename: "CommandRejected",
    msgId,
    errorCode,
    errorDetail: detail,
  };
}

async function checkPluginStatus(event) {
  if (ddbClient === null) return null;
  const fieldName = extractFieldName(event);
  if (fieldName === null) return null;
  const underscore = fieldName.indexOf("_");
  const pluginPrefix = underscore >= 0 ? fieldName.slice(0, underscore) : fieldName;
  if (pluginPrefix === "Platform") return null;
  let statuses;
  try {
    statuses = await loadPluginStatuses();
  } catch (err) {
    log.warn("checkPluginStatus: failed to load Plugin RM statuses", { comp: "AggregateEntryPoint", detail: err?.message ?? String(err) });
    return null;
  }
  const status = statuses[pluginPrefix];
  const msgId = "00000000-0000-0000-0000-000000000000";
  const detailPrefix = `Mutation.${fieldName}`;
  switch (status) {
    case undefined:
    case "Connected":
      return null;
    case "Disconnected":
      return pluginRejection(msgId, "PluginUnavailable", `${detailPrefix}: plugin is disconnected`);
    case "Inactive":
      return pluginRejection(msgId, "PluginInactive", `${detailPrefix}: plugin is inactive`);
    case "Retired":
      return pluginRejection(msgId, "PluginRetired", `${detailPrefix}: plugin version has been retired`);
    default:
      return null;
  }
}

// Build the per-aggregate parts shared by Route 1 (AppSync direct invoke) and
// Route 2 (SQS event source): the in-process command handler (used both as the
// inline dispatch target and as the SQS message handler) plus the resolved
// queue ref for the fire-and-forget async path.
// `pgConnection`, when present, is the resolved PgConnection.connectionConfig
// ({host,port,database,username,secretArn}) serialized into HANDLER_CONFIG by the
// runtime builder for a Postgres-backed aggregate. Its presence selects the
// Postgres EventLog runtime; absence keeps the DynamoDB path byte-identical.
// `eventLogTableName` doubles as the Postgres `event_log.log_name` discriminator
// (all aggregates share one Postgres table, unlike DynamoDB's table-per-aggregate).
function buildAggregateParts(specModule, behaviorModule, eventLogTableName, queueUrl, pgConnection) {
  const patchedSpec = patchSpecId(specModule);
  let rawStorageOps;
  if (pgConnection) {
    const pgOps = pgEventLogOpsFor(pgConnection, eventLogTableName);
    rawStorageOps = {
      append: pgOps.append,
      replay: pgOps.replay,
      replayStream: pgOps.replayStream,
      appendStream: pgOps.appendStream,
    };
  } else {
    const resolvedTable = { name: eventLogTableName };
    rawStorageOps = {
      append: append(resolvedTable),
      replay: replay(resolvedTable),
      replayStream: replayStream(resolvedTable),
      appendStream: appendStream(resolvedTable),
    };
  }
  const eventLogOps = eventLogOperationsMake(patchedSpec)({
    Spec: patchedSpec,
    EventTopic: { Spec: patchedSpec },
    eventTopic: { publish: async () => {} },
    storage: rawStorageOps,
  });
  const aggregateCallback = aggregateCallbackMake(patchedSpec)(behaviorModule)({
    Spec: patchedSpec,
    EventLog: { Spec: patchedSpec },
    eventLog: eventLogOps,
  });
  const commandTopicCallback = commandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: aggregateCallback.handleCommands,
  });
  const resolvedQueue = makeQueueRef(queueUrl);
  return {
    patchedSpec,
    handleJsonCommands: commandTopicCallback.handleJsonCommands,
    sqsHandler: handleQueueEvent(resolvedQueue, commandTopicCallback.handleJsonCommands),
    resolvedQueue,
  };
}

function buildCommandGeneratorHandler(parts, dispatchMode) {
  const { patchedSpec, handleJsonCommands, resolvedQueue } = parts;
  const publishJsons = sqsPublishJsons(resolvedQueue, "SQS_FIFO");
  // Sync (default): dispatch inline so the AppSync resolver gets a typed
  // Accepted/Rejected outcome. Async: fire-and-forget to SQS, return Pending —
  // the SQS event source (Route 2) processes the command later.
  const publishJsonsAndWait = dispatchMode === "async"
    ? undefined
    : (jsons) => runInlineAndCollect(jsons, handleJsonCommands);
  // Positional args after ReScript compiles labeled params:
  //   (publishJsons, publishJsonsAndWait, serviceName, commandSchema, componentKind, stripIdFromParams)
  // The `undefined` for `stripIdFromParams` must be passed explicitly here —
  // omitting it shifts everything left, sending the schema object through the
  // serviceName slot (string-concat then throws "Cannot convert object to
  // primitive value" once the log line tries to print "CommandGenerator(<schema>)").
  const generateCommand = makeGenerateCommand(publishJsons, publishJsonsAndWait, patchedSpec.name, patchedSpec.commandSchema, "Aggregate", undefined);
  return (event, _context) => {
    // Add identity fallback: use payload.identity if present, otherwise construct from meta.user.
    const identity = (event.identity != null && typeof event.identity === 'object')
      ? event.identity
      : {
          userId: event.meta?.user ?? "anonymous",
          username: event.meta?.user ?? "anonymous",
          groups: [],
          provider: { TAG: "Custom", _0: "aws" },
        };
    // CommandGenerator.meta declares ip as array<string> (X-Forwarded-For chain).
    // The AppSync resolver template sends a single string (or null) from
    // identity.sourceIp — normalize to array so generateCommand's
    // `payload.meta.ip->Array.shift` doesn't crash on null/non-array values.
    const rawIp = event.meta?.ip;
    const ip = rawIp == null ? [] : Array.isArray(rawIp) ? rawIp : [rawIp];
    const meta = { ...event.meta, ip };
    return generateCommand({ ...event, meta, identity });
  };
}

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

function extractCorrelationId(records) {
  const first = records[0];
  if (!first) return undefined;
  const body = first.body;
  if (body == null) return undefined;
  try {
    const parsed = JSON.parse(body);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      const meta = parsed.meta;
      if (meta && typeof meta === "object" && !Array.isArray(meta)) {
        const cid = meta.correlationId;
        if (typeof cid === "string") return cid;
      }
    }
  } catch (_) {}
  return undefined;
}

// DISPATCH_MODE controls whether AppSync direct-invoke commands are run inline
// (sync, default) or pushed to SQS for asynchronous processing (async).
// Aggregate_Builder_Single bundles this entry point with sync; the async
// variant (Aggregate_Builder_Single_Async) sets DISPATCH_MODE=async.
const DISPATCH_MODE = process.env["DISPATCH_MODE"] === "async" ? "async" : "sync";

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const cmdTopicHandlers = {};
  const cmdGenHandlers = {};
  await Promise.all(config.handlers.map(async h => {
    const specModule = await dynamicImport(h.specModule);
    const behaviorModule = await dynamicImport(h.behaviorModule);
    const parts = buildAggregateParts(specModule, behaviorModule, h.eventLogTable, h.queueUrl, h.pgConnection);
    cmdTopicHandlers[h.queueArn] = parts.sqsHandler;
    cmdGenHandlers[specModule.name] = buildCommandGeneratorHandler(parts, DISPATCH_MODE);
  }));
  return [cmdTopicHandlers, cmdGenHandlers];
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  _currentRequestId = context?.awsRequestId || "unknown";
  const [cmdTopicHandlers, cmdGenHandlers] = await initPromise;

  // Route 1: AppSync direct invocation
  if (event.command != null && event.arguments != null) {
    // Plugin status gate (Part 2.3) — checked before dispatching to the
    // per-aggregate handler so a deactivated plugin's mutations are rejected
    // without touching the EventLog or CommandTopic.
    const rejection = await checkPluginStatus(event);
    if (rejection !== null) {
      log.warn("plugin status gate rejected: " + rejection.errorCode, { comp: "CommandGenerator" });
      return rejection;
    }
    const entries = Object.entries(cmdGenHandlers);
    const len = entries.length;
    let i = 0;
    let result = null;
    let found = false;
    while (i < len && !found) {
      const [name, cmdGenHandler] = entries[i];
      try {
        const r = await runEffect(undefined, cmdGenHandler(event, context));
        log.debug("processed command via " + name, { comp: "CommandGenerator" });
        result = r;
        found = true;
      } catch (e) {
        log.debug("handler '" + name + "' threw, trying next", { comp: "CommandGenerator", detail: e && e.message ? e.message : String(e) });
        i = i + 1;
      }
    }
    if (!found) {
      log.warn("no handler matched command", { comp: "CommandGenerator" });
      return null;
    }
    // generateCommand returns a ReScript commandOutcome variant
    // (Accepted/Rejected/Pending) compiled to a `{TAG, ...}` JS object. AppSync
    // resolves the CommandResult union by `__typename` — convert to that shape.
    return commandOutcomeToJson(result);
  }

  // Route 2: SQS CommandTopic events
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);
  const grouped = groupBySource(records);
  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const cmdHandler = cmdTopicHandlers[arn];
    if (cmdHandler !== undefined) {
      log.debug("found handler for CommandTopic " + arn, { comp: "AggregateRuntime" });
      await runEffect(correlationId, cmdHandler({ Records: subRecords }, context));
    } else {
      log.warn("no handler found: " + arn, { comp: "AggregateRuntime" });
    }
  }));
  return "";
}
