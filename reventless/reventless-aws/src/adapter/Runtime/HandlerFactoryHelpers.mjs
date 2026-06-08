// Shared runtime utilities for compiled Lambda entry points.

import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";

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
