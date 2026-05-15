// Aggregate Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec+Behavior modules,
// wires EventLog_Operations, Aggregate_Callback, CommandTopic_Callback.
// Handles both SQS CommandTopic events (Route 2) and AppSync direct invocation (Route 1).

import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as eventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/EventLog/EventLog_Operations.res.mjs";
import { Make as aggregateCallbackMake } from "@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { makeGenerateCommand } from "@reventlessdev/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res.mjs";
import { append, replay, replayStream, appendStream } from "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs";
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
    console.warn("checkPluginStatus: failed to load Plugin RM statuses:", err?.message ?? err);
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
    default:
      return null;
  }
}

function buildCommandTopicHandler(specModule, behaviorModule, eventLogTableName, queueUrl) {
  const patchedSpec = patchSpecId(specModule);
  const resolvedTable = { name: eventLogTableName };
  const rawStorageOps = {
    append: append(resolvedTable),
    replay: replay(resolvedTable),
    replayStream: replayStream(resolvedTable),
    appendStream: appendStream(resolvedTable),
  };
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
  return handleQueueEvent(makeQueueRef(queueUrl), commandTopicCallback.handleJsonCommands);
}

function buildCommandGeneratorHandler(specModule, _behaviorModule, queueUrl) {
  const resolvedQueue = makeQueueRef(queueUrl);
  const publishJsons = sqsPublishJsons(resolvedQueue, "SQS_FIFO");
  const generateCommand = makeGenerateCommand(publishJsons, specModule.name, specModule.commandSchema, "Aggregate", undefined);
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
    return generateCommand({ ...event, identity });
  };
}

function runEffect(correlationId, effect) {
  return effect
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

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const cmdTopicHandlers = {};
  const cmdGenHandlers = {};
  await Promise.all(config.handlers.map(async h => {
    const specModule = await dynamicImport(h.specModule);
    const behaviorModule = await dynamicImport(h.behaviorModule);
    cmdTopicHandlers[h.queueArn] = buildCommandTopicHandler(specModule, behaviorModule, h.eventLogTable, h.queueUrl);
    cmdGenHandlers[specModule.name] = buildCommandGeneratorHandler(specModule, behaviorModule, h.queueUrl);
  }));
  return [cmdTopicHandlers, cmdGenHandlers];
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  const [cmdTopicHandlers, cmdGenHandlers] = await initPromise;

  // Route 1: AppSync direct invocation
  if (event.command != null && event.arguments != null) {
    // Plugin status gate (Part 2.3) — checked before dispatching to the
    // per-aggregate handler so a deactivated plugin's mutations are rejected
    // without touching the EventLog or CommandTopic.
    const rejection = await checkPluginStatus(event);
    if (rejection !== null) {
      console.log("----- commandGeneratorHandler: plugin status gate rejected (" + rejection.errorCode + ")");
      return rejection;
    }
    const entries = Object.entries(cmdGenHandlers);
    const len = entries.length;
    let i = 0;
    let result = "";
    let found = false;
    while (i < len && !found) {
      const [name, cmdGenHandler] = entries[i];
      try {
        const r = await runEffect(undefined, cmdGenHandler(event, context));
        console.log("----- commandGeneratorHandler: processed command via " + name);
        result = r;
        found = true;
      } catch (_) {
        i = i + 1;
      }
    }
    if (!found) {
      console.warn("commandGeneratorHandler: no handler matched command");
    }
    return result;
  }

  // Route 2: SQS CommandTopic events
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);
  const grouped = groupBySource(records);
  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const cmdHandler = cmdTopicHandlers[arn];
    if (cmdHandler !== undefined) {
      console.log("----- aggregateHandler: found handler for CommandTopic " + arn);
      await runEffect(correlationId, cmdHandler({ Records: subRecords }, context));
    } else {
      console.warn("aggregateHandler: no handler found: " + arn);
    }
  }));
  return "";
}
