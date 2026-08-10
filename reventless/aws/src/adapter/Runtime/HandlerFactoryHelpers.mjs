// Shared runtime utilities for compiled Lambda entry points.

import * as Effect from "effect/Effect";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import {
  tag as requestContextTag,
  fromOptions as makeRequestContext,
} from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";

// Re-exported, not defined here: the seam must fire once per process, and a
// runtime too small to want this module's other imports awaits the same binding
// straight from its own module. See RuntimeExtensionsReady.mjs.
export { runtimeExtensionsReady } from "./RuntimeExtensionsReady.mjs";

// ─── Structured logging from the .mjs entry-point shims ─────────────────────
// Mirrors ReScript's Logger.t API and Logger.emit's JSON sink shape (time,
// level, message, service, plugin, comp, detail) so shim-side init/error
// traces land alongside ReScript logs as homogeneous JSON in CloudWatch.
//
// Usage: `log.debug("msg", { comp: "AggregateRuntime" })` —
// level-specific method, no stringly-typed level argument.

const LEVEL_DEBUG = 0;
const LEVEL_INFO = 1;
const LEVEL_WARN = 2;
const LEVEL_ERROR = 3;
const LEVEL_SILENT = 99;

function envMinLevel() {
  switch ((process.env.LOG_LEVEL || "info").toLowerCase()) {
    case "silent": return LEVEL_SILENT;
    case "debug":  return LEVEL_DEBUG;
    case "warn":   return LEVEL_WARN;
    case "error":  return LEVEL_ERROR;
    default:       return LEVEL_INFO;
  }
}

// Per-plugin Lambdas follow the naming pattern `<Plugin>Plugin<Suffix>` (e.g.
// `CatalogPluginEventColl`, `OrderingPluginHeartbeat`). Multi-plugin Lambdas
// (`AllAggregatesCmdHandler`, `AllReadModels`, the platform-level `PluginAggr*`)
// don't carry a single plugin identity; returns null so callers omit the field.
export function derivePluginFromLambdaName(name) {
  if (typeof name !== "string") return null;
  const match = /^([A-Z][a-zA-Z0-9]+)Plugin(?:[A-Z]|$|-)/.exec(name);
  return match ? match[1] : null;
}

const PLUGIN_NAME = derivePluginFromLambdaName(process.env.AWS_LAMBDA_FUNCTION_NAME);
const SERVICE_NAME = process.env.REVENTLESS_SERVICE || process.env.AWS_LAMBDA_FUNCTION_NAME;

function emit(level, levelLabel, message, extra) {
  if (level < envMinLevel()) return;
  const fields = { time: new Date().toISOString(), level: levelLabel, message };
  if (SERVICE_NAME) fields.service = SERVICE_NAME;
  if (PLUGIN_NAME) fields.plugin = PLUGIN_NAME;
  if (extra && typeof extra === "object") {
    for (const [k, v] of Object.entries(extra)) {
      if (v !== undefined && v !== null) fields[k] = v;
    }
  }
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(fields));
}

export const log = {
  debug: (message, extra) => emit(LEVEL_DEBUG, "DEBUG", message, extra),
  info:  (message, extra) => emit(LEVEL_INFO,  "INFO",  message, extra),
  warn:  (message, extra) => emit(LEVEL_WARN,  "WARN",  message, extra),
  error: (message, extra) => emit(LEVEL_ERROR, "ERROR", message, extra),
};

// Plugin name derived from the Lambda function name (null on multi-plugin
// Lambdas). Export so shim runEffect wrappers can annotate Effect logs with it.
export const pluginName = PLUGIN_NAME;

// ─── Dispatch boundary for the entry-point shells ───────────────────────────
// The deployed Lambda is an archive whose index.handler is one of the .mjs entry
// points here — the AWS runtime builders take `~handler as _` and discard the
// ReScript closure, so ReventlessCore.Runtime.annotateInvocation (the ReScript
// dispatch boundary, used by reventless-local) never runs in a Lambda. This is
// its counterpart: the single place where every deployed invocation gets its log
// annotations and its RequestContext, so `comp` / `causationId` attribution is
// the same on both platforms.
//
// Options object rather than positional arguments: the shells call this from
// twelve sites and the field set grows, so a new field must not be able to
// shift an existing one. Same reason RequestContext exposes `fromOptions` —
// ReScript labelled arguments compile to positional ones.
//
// See docs/plans/entrypoint-dispatch-parity-and-latency-fields.md.

// Set at handler entry via setRequestId; read on each dispatch to tag logs with
// the Lambda request id.
let _currentRequestId = "unknown";

export function setRequestId(id) {
  _currentRequestId = id || "unknown";
}

export function runEffect(effect, opts = {}) {
  const { correlationId, causationId, comp, timestamp, retryCount, plugin } = opts;
  const cid = correlationId || "unknown";
  // `plugin` per dispatch (from HANDLER_CONFIG, resolved at deploy time) beats
  // the Lambda-name-derived fallback: a shared Lambda (AllReadModels,
  // AllAggregatesCmdHandler) hosts components from several plugins, so its name
  // carries no single plugin identity.
  const resolvedPlugin = plugin || pluginName;
  let e = effect
    // Promote correlationId/requestId/plugin/comp/causationId to top-level JSON
    // log fields — decoded by EffectLogger.install() from Effect log
    // annotations. Harmless no-op if the unified logger isn't installed.
    .pipe(Effect.annotateLogs("correlationId", cid))
    .pipe(Effect.annotateLogs("requestId", _currentRequestId));
  if (resolvedPlugin) e = e.pipe(Effect.annotateLogs("plugin", resolvedPlugin));
  if (comp) e = e.pipe(Effect.annotateLogs("comp", comp));
  if (causationId) e = e.pipe(Effect.annotateLogs("causationId", causationId));
  // Only annotate a redelivery. A constant "1" on every line is noise, and its
  // absence is what makes `filter retryCount > 1` a usable query.
  if (retryCount > 1) e = e.pipe(Effect.annotateLogs("retryCount", String(retryCount)));
  return e
    .pipe(
      Effect.provideService(
        requestContextTag,
        makeRequestContext({
          correlationId: cid,
          causationId,
          component: comp,
          pluginName: resolvedPlugin || undefined,
          timestamp,
          retryCount,
        }),
      ),
    )
    .pipe(Effect.runPromise);
}

// ─── Message-envelope + transport-attribute extraction ──────────────────────
// Mirrors RuntimeEnvironment_Lambda.extractMetaField (ReScript side, same
// position in the batch) so both dispatch boundaries read the same fields.

// Read one envelope meta field (correlationId, causationId, …) off the first
// record. Two transports, two shapes:
//   SQS            — the envelope is a JSON `body` string with a nested `meta`.
//   DynamoDB stream — the EventLog row stores meta keys *flat* as top-level
//                     attributes (Message.composeMeta rebuilds `meta` from them),
//                     so read NewImage.<field>.S.
// Undefined when neither shape yields a string.
export function extractMetaField(records, field) {
  const first = (records || [])[0];
  if (!first) return undefined;
  if (typeof first.body === "string") {
    let parsed;
    try {
      parsed = JSON.parse(first.body);
    } catch (_) {
      return undefined;
    }
    const value = parsed?.meta?.[field];
    return typeof value === "string" ? value : undefined;
  }
  const attr = first.dynamodb?.NewImage?.[field];
  return typeof attr?.S === "string" ? attr.S : undefined;
}

// Send time of the triggering message, ms since epoch. SQS stamps
// `SentTimestamp` (ms, server-side clock — not the producer's); a DynamoDB
// stream record carries `ApproximateCreationDateTime` in *seconds*. Undefined
// when neither is present, so a handler can tell "no send time" from "zero
// latency".
export function extractSentTimestamp(records) {
  const first = (records || [])[0];
  if (!first) return undefined;
  const sqsSent = first.attributes?.SentTimestamp;
  if (sqsSent !== undefined) {
    const ms = Number(sqsSent);
    return Number.isFinite(ms) ? ms : undefined;
  }
  const streamCreated = first.dynamodb?.ApproximateCreationDateTime;
  if (streamCreated !== undefined) {
    const secs = Number(streamCreated);
    return Number.isFinite(secs) ? secs * 1000 : undefined;
  }
  return undefined;
}

// Delivery attempt: 1 on first delivery. SQS counts redeliveries in
// `ApproximateReceiveCount`; DynamoDB streams have no equivalent, so a stream
// record reports 1.
export function extractRetryCount(records) {
  const first = (records || [])[0];
  const raw = first?.attributes?.ApproximateReceiveCount;
  if (raw === undefined) return 1;
  const count = parseInt(raw, 10);
  return Number.isFinite(count) && count > 0 ? count : 1;
}

// Patch a spec module's Id field to use IdString if undefined.
// Workaround for `module Id = Id.String` not producing an ESM export.
export const patchSpecId = (specModule) => ({ ...specModule, Id: specModule.Id || IdString });

// Create a minimal DynamoDB table stub from a table name.
export function makeTableRef(name) {
  return { name, hashKey: "id" };
}

// Create a minimal SQS queue stub from a queue URL.
export function makeQueueRef(url) {
  return { id: url, name: url, arn: "" };
}

// DynamoDB scan with filter expression support.
export async function scanByTableName(tableName, filterConfigs, limit) {
  if (!scanByTableName._client) {
    scanByTableName._client = DynamoDBDocumentClient.from(new DynamoDBClient({}));
  }
  var client = scanByTableName._client;
  var filterParts = [];
  var attrNames = {};
  var attrValues = {};

  (filterConfigs || []).forEach(function(entry, idx) {
    var fieldName = entry[0];
    var comparator = entry[1];
    var value = entry[2];
    var valueName = fieldName + idx;
    attrNames["#" + fieldName] = fieldName;

    var attrValue;
    if (typeof value === "object" && value !== null && "TAG" in value) {
      attrValue = value._0;
    } else {
      attrValue = value;
    }
    attrValues[":" + valueName] = attrValue;

    var comp = typeof comparator === "object" ? comparator.TAG || comparator : comparator;
    switch (comp) {
      case "Equal": filterParts.push("#" + fieldName + " = :" + valueName); break;
      case "Unequal": filterParts.push("#" + fieldName + " <> :" + valueName); break;
      case "Contains": filterParts.push("contains( #" + fieldName + ", :" + valueName + " )"); break;
      case "NotContains": filterParts.push("NOT contains( #" + fieldName + ", :" + valueName + " )"); break;
      case "BeginsWith": filterParts.push("begins_with( #" + fieldName + ", :" + valueName + " )"); break;
      case "Exists": filterParts.push("attribute_exists( #" + fieldName + " )"); break;
      case "NotExists": filterParts.push("attribute_not_exists( #" + fieldName + " )"); break;
      case "LessOrEqual": filterParts.push("#" + fieldName + " <= :" + valueName); break;
      case "Less": filterParts.push("#" + fieldName + " < :" + valueName); break;
      case "GreaterOrEqual": filterParts.push("#" + fieldName + " >= :" + valueName); break;
      case "Greater": filterParts.push("#" + fieldName + " > :" + valueName); break;
      default: filterParts.push("#" + fieldName + " = :" + valueName);
    }
  });

  var params = { TableName: tableName, Limit: limit };
  if (filterParts.length > 0) {
    params.FilterExpression = filterParts.join(" AND ");
    params.ExpressionAttributeNames = attrNames;
    params.ExpressionAttributeValues = attrValues;
  }

  var items = [];
  var lastKey;
  do {
    if (lastKey) params.ExclusiveStartKey = lastKey;
    var result = await client.send(new ScanCommand(params));
    if (result.Items) items.push.apply(items, result.Items);
    lastKey = result.LastEvaluatedKey;
  } while (lastKey && items.length < limit);

  return items;
}
