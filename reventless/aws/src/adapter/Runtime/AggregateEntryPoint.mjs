// Aggregate Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec+Behavior modules,
// wires EventLog_Operations, Aggregate_Callback, CommandTopic_Callback.
// Handles both SQS CommandTopic events (Route 2) and AppSync direct invocation (Route 1).

import {
  patchSpecId,
  makeQueueRef,
  log,
  runEffect,
  setRequestId,
  extractMetaField,
  extractSentTimestamp,
  extractRetryCount,
} from "./HandlerFactoryHelpers.mjs";
import { Make as eventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/EventLog/EventLog_Operations.res.mjs";
import { Make as aggregateCallbackMake } from "@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { makeCommandGenerator } from "./CommandGeneratorEntryPoint_Ops.res.mjs";
import { commandOutcomeToJson, runInlineAndCollect } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
// Typed cold-start core — EventLog storage-ops selection/wiring, compiler-checked
// against the framework signatures (see the module header and
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md).
import { makeStorageOps } from "./AggregateEntryPoint_Ops.res.mjs";
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
  // Typed core: backend-specific EventLog storage ops (Postgres when pgConnection
  // is present, else DynamoDB). Returns the full 6-field EventLog_Adapter.operations
  // — the shell previously dropped latestSnapshot/writeSnapshot.
  const rawStorageOps = makeStorageOps(eventLogTableName, pgConnection);
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
  // Typed core (CommandGeneratorEntryPoint_Ops.res) pins the arg order and the
  // componentKind/stripIdFromParams positions against the framework signature.
  // stripIdFromParams=true matches the framework default the old shell relied on
  // by passing `undefined`.
  const generateCommand = makeCommandGenerator(publishJsons, publishJsonsAndWait, patchedSpec.name, patchedSpec.commandSchema, "Aggregate", true);
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

// The dispatch `comp`, matching the ReScript boundary's
// `AggregateRuntime(<aggregateName>)` (AggregateRuntime_Builder_Common). Derived
// in-shell rather than baked into HANDLER_CONFIG because the aggregate name is
// already in hand here — unlike the event-collector resource name the read-model
// entry point has to be handed.
const aggregateComp = (aggregateName) => `AggregateRuntime(${aggregateName})`;

function groupBySource(records) {
  const dict = {};
  records.forEach(record => {
    const arn = record.eventSourceARN;
    const existing = dict[arn] || [];
    dict[arn] = existing.concat([record]);
  });
  return dict;
}

// DISPATCH_MODE controls whether AppSync direct-invoke commands are run inline
// (sync, default) or pushed to SQS for asynchronous processing (async).
// Aggregate_Builder_Single bundles this entry point with sync; the async
// variant (Aggregate_Builder_Single_Async) sets DISPATCH_MODE=async.
const DISPATCH_MODE = process.env["DISPATCH_MODE"] === "async" ? "async" : "sync";

// Exported for tests: build the [cmdTopicHandlers, cmdGenHandlers] pair from an
// already-parsed `HANDLER_CONFIG` shape, with an injectable module loader. In
// production, `buildAllHandlers` wraps this with the env config + the Lambda's
// `/var/task/node_modules` dynamic import; the integration test injects a loader
// returning pre-imported spec/behavior modules so it can drive the real
// cmdGenHandler end-to-end against DynamoDB Local. (Mirrors the DCB entry point.)
export async function buildHandlersForConfig(config, opts = {}) {
  const loadModule = opts.loadModule ?? dynamicImport;
  const dispatchMode = opts.dispatchMode ?? DISPATCH_MODE;
  const cmdTopicHandlers = {};
  const cmdGenHandlers = {};
  await Promise.all((config.handlers || []).map(async h => {
    const specModule = await loadModule(h.specModule);
    const behaviorModule = await loadModule(h.behaviorModule);
    const parts = buildAggregateParts(specModule, behaviorModule, h.eventLogTable, h.queueUrl, h.pgConnection);
    // Pair each handler with the comp of the aggregate it belongs to: this
    // Lambda can host every aggregate in the platform, so the comp is what keeps
    // their log lines separable.
    const comp = aggregateComp(specModule.name);
    cmdTopicHandlers[h.queueArn] = { handler: parts.sqsHandler, comp };
    cmdGenHandlers[specModule.name] = {
      handler: buildCommandGeneratorHandler(parts, dispatchMode),
      comp,
    };
  }));
  return [cmdTopicHandlers, cmdGenHandlers];
}

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  return buildHandlersForConfig(JSON.parse(configStr));
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  setRequestId(context?.awsRequestId);
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
      const [name, { handler: cmdGenHandler, comp }] = entries[i];
      try {
        // Route 1 carries its envelope on `event.meta` (AppSync direct invoke),
        // not in an SQS record — and there is no send time or receive count on
        // this path, so latency/retry fields stay absent rather than faked.
        const r = await runEffect(cmdGenHandler(event, context), {
          correlationId: event.meta?.correlationId,
          causationId: event.meta?.causationId,
          comp,
        });
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
  const grouped = groupBySource(records);
  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const registered = cmdTopicHandlers[arn];
    if (registered !== undefined) {
      const { handler: cmdHandler, comp } = registered;
      log.debug("found handler for CommandTopic " + arn, { comp: "AggregateRuntime" });
      await runEffect(cmdHandler({ Records: subRecords }, context), {
        correlationId: extractMetaField(subRecords, "correlationId"),
        causationId: extractMetaField(subRecords, "causationId"),
        comp,
        timestamp: extractSentTimestamp(subRecords),
        retryCount: extractRetryCount(subRecords),
      });
    } else {
      log.warn("no handler found: " + arn, { comp: "AggregateRuntime" });
    }
  }));
  return "";
}
