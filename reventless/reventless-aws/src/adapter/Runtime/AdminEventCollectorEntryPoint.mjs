// Plugin EventCollector Lambda entry point — shared between the admin and every
// per-plugin EventCollector Lambda. Despite the historical "Admin" filename, this
// module is plugin-agnostic: behaviour is driven entirely by HANDLER_CONFIG.
//
// HANDLER_CONFIG schema (JSON in env var "HANDLER_CONFIG"):
//
// {
//   "queueUrl":                       string  // SQS URL of the EventCollector this Lambda drains
//   "pluginExtensionPointCmdTopicUrl":string  // SQS URL of CorePluginExtPoint cmd topic (admin's Plugin EP)
//   "eventTopicArn":                  string  // SNS ARN the EP's outgoing events publish to ("NOT_AVAILABLE" if none)
//   "pluginReadModelTableName":       string  // DynamoDB table for Plugin RM (used by QueryEngine.scan)
//   "pluginSchemaPersistenceTableName":string // DynamoDB table holding deploy-time SDL fragments
//                                              // (rows keyed "deploy-schema:<name>"). Durable source
//                                              // for the runtime schema stitch; "NOT_AVAILABLE" →
//                                              // fall back to Plugin RM Connected-row scan.
//   "appSyncApiId":                   string  // "NOT_AVAILABLE" disables schema stitching
//   "clonerEnabled":                  boolean
//   "schedulerRoleArn":               string  // IAM role for CloudWatch Events schedule targets
//   "schedulerQueueArn":              string  // ARN of the cmd topic the scheduler publishes to ("" → no commandTopicResources)
//   "schedulerQueueName":             string
//   "pluginDefinition":               Plugin.pluginDefinition  // serialized; admin uses a fake one (id="Admin@INTERNAL")
//   "extensionPoints": [                       // EPs whose OUTGOING events this Lambda processes; admin: 1 entry, plugins: []
//     {
//       "specModule":      string,   // dynamic import specifier for the EP spec module
//       "mappingsModule":  string,   // dynamic import specifier for the EP mapping factory (exports `Make`)
//       "eventTopicArn":   string,   // SNS ARN the EP's outgoing events publish to (per-EP override of top-level eventTopicArn)
//       "aggregateNames":  string[]  // delegate aggregate names — service keys for outgoingExtensionPointEventHandlers
//     }
//   ],
//   "connectExtension": {                      // The auto-included PluginConnectExtension entry; null for admin Lambda
//     "specModule":         string,
//     "mappingsModule":     string,
//     "extensionPointName": string             // service key for incomingConnectExtensionEventHandlers (e.g. "Core.Plugin")
//   } | null,
//   "extensions": [                            // User-declared extensions — wired into incoming/outgoing dicts at cold start
//     {
//       "name":               string,          // extension component name (used for logs / dedupe)
//       "specModule":         string,          // dynamic import for the ExtensionPoint spec module
//       "mappingsModule":     string,          // dynamic import for the user extension file (`module Mapping`)
//       "delegateModule":     string,          // dynamic import for the Delegate spec (aggregate / slice)
//       "extensionPointName": string,          // service key for incomingExtensionEventHandlers (e.g. "Ordering.Orders")
//       "aggregateNames":     string[],        // outgoing service keys + filter into top-level publishToAggregates
//       "readModelNames":     string[]         // RMs this extension may enqueue events into (filter into readModelQueueUrls)
//     }
//   ],
//   "publishToAggregates": {                   // aggregateName → env-var name holding the aggregate's cmd-topic SQS URL
//     "Plugin": "PTA_Plugin_QUEUE_URL",
//     "RecordProductDemand": "PTA_RecordProductDemand_QUEUE_URL"
//   },
//   "readModelQueueUrls": {                    // rmName → env-var name holding the RM's EventCollector SQS URL
//     "ProductDemands": "PRM_ProductDemands_QUEUE_URL"
//   },
//   "readModelNamesForSourceName": {           // deploy-side inversion of RM.sourceNames; sourceServiceName → [rmName]
//     "Ordering.Orders": ["ProductDemands"]
//   }
// }
//
// Why this shape and not separate entry points per Lambda: at deploy time both the
// admin EventCollector and every per-plugin EventCollector share the same code
// asset (this file). The runtime differences are entirely data — which EPs to
// process outgoing events for (admin only) and which Connect extension to wire
// (plugin only). Plugin_Callback.Make routes incoming SQS events to the right
// service-keyed handler dict; we reconstruct those dicts here from HANDLER_CONFIG.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef, scanByTableName, log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { subscribeQueueToTopic, unsubscribeQueueFromTopic } from "@reventlessdev/rescript-aws-sdk/src/SNS_Helpers.res.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/util/Util_PluginMessage_Runtime.res.mjs";
import { publish as snsPublish } from "@reventlessdev/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS_Runtime.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { Make as extensionPointOperationsMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res.mjs";
import { Make as extensionOperationsMake } from "@reventlessdev/reventless-core/src/components/Extension/Extension_Operations.res.mjs";
import { Make as extensionMappingMake } from "@reventlessdev/reventless-infra/src/types/ExtensionMapping.res.mjs";
import { Make as extensionPointMappingMake } from "@reventlessdev/reventless-infra/src/types/ExtensionPointMapping.res.mjs";
import { Make as pluginCallbackMake } from "@reventlessdev/reventless-core/src/components/Plugin/Plugin_Callback.res.mjs";
import { handleDynamoDbOrSqsEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res.mjs";
import { createSchedule as cwCreateSchedule, deleteSchedule as cwDeleteSchedule } from "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs";
import {
  stitch as graphqlStitch,
  decode as decodeFragment,
  countRootTypeFields,
  isCatastrophicSchemaShrink,
} from "@reventlessdev/reventless-core/src/components/Api/GraphQL_Stitcher.res.mjs";
import { baseFragment as adminBaseFragment } from "@reventlessdev/reventless-core/src/admin/AdminApi.res.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";

// The Plugin RM state schema uses `@s.matches(_jsNullable …)` for many
// optional fields — top-level AND nested. DDB writes drop undefined
// attributes, so the unmarshalled row arrives with the relevant keys
// *missing* (not set to null). Sury's strict parser then rejects them as
// "received undefined". Tracking and patching every nullable path by hand is
// whack-a-mole; instead, manageSubscriptions and reconcileSubscriptions only
// need a tiny subset of the state (id / status / extensions / extensionPoints
// / eventCollector), so they sidestep sury entirely and read the DDB row
// directly via this small projection. mkUpdateApiSchema does the same for
// apiSchemaFragment further below.
function projectPluginRow(row) {
  if (!row || typeof row !== "object") return null;
  if (typeof row.id !== "string" || typeof row.status !== "string") return null;
  const dcbEventLog =
    row.dcbEventLog &&
    typeof row.dcbEventLog === "object" &&
    typeof row.dcbEventLog.name === "string" &&
    typeof row.dcbEventLog.eventTopicArn === "string"
      ? { name: row.dcbEventLog.name, eventTopicArn: row.dcbEventLog.eventTopicArn }
      : null;
  return {
    id: row.id,
    status: row.status,
    eventCollector: typeof row.eventCollector === "string" ? row.eventCollector : "",
    extensions: Array.isArray(row.extensions)
      ? row.extensions
          .filter((e) => e && typeof e.extensionPointName === "string")
          .map((e) => ({
            name: typeof e.name === "string" ? e.name : "",
            extensionPointName: e.extensionPointName,
            dcbSources: Array.isArray(e.dcbSources)
              ? e.dcbSources.filter((s) => typeof s === "string")
              : [],
          }))
      : [],
    extensionPoints: Array.isArray(row.extensionPoints)
      ? row.extensionPoints
          .filter((ep) => ep && typeof ep.name === "string" && typeof ep.eventTopic === "string")
          .map((ep) => ({
            name: ep.name,
            commandTopic: typeof ep.commandTopic === "string" ? ep.commandTopic : "",
            eventTopic: ep.eventTopic,
          }))
      : [],
    dcbEventLog,
  };
}

function parseHandlerConfig(rawJson) {
  if (!rawJson) throw new Error("HANDLER_CONFIG env var is empty");
  let config;
  try {
    config = JSON.parse(rawJson);
  } catch (e) {
    throw new Error("HANDLER_CONFIG JSON parse error: " + (e && e.message));
  }
  const required = [
    "queueUrl",
    "pluginExtensionPointCmdTopicUrl",
    "eventTopicArn",
    "pluginReadModelTableName",
    "appSyncApiId",
    "schedulerRoleArn",
    "schedulerQueueArn",
    "schedulerQueueName",
    "extensionPoints",
    "extensions",
    "publishToAggregates",
  ];
  for (const k of required) {
    if (config[k] === undefined) {
      throw new Error("HANDLER_CONFIG missing required field: " + k);
    }
  }
  if (!Array.isArray(config.extensionPoints)) throw new Error("HANDLER_CONFIG.extensionPoints must be an array");
  if (!Array.isArray(config.extensions)) throw new Error("HANDLER_CONFIG.extensions must be an array");
  // connectExtension is allowed to be null or absent (admin case)
  if (config.connectExtension === undefined) config.connectExtension = null;
  // Optional fields with empty defaults — admin context omits them entirely.
  if (config.readModelQueueUrls === undefined) config.readModelQueueUrls = {};
  if (config.readModelNamesForSourceName === undefined) config.readModelNamesForSourceName = {};
  // Per-extension defaults so older serialisers (or partial admin configs) keep working.
  for (const ext of config.extensions) {
    if (!Array.isArray(ext.aggregateNames)) ext.aggregateNames = [];
    if (!Array.isArray(ext.readModelNames)) ext.readModelNames = [];
    if (typeof ext.name !== "string") ext.name = ext.extensionPointName || "unknown";
    if (typeof ext.delegateModule !== "string") ext.delegateModule = "";
  }
  return config;
}

function injectAwsAuthAll(fragment, group) {
  const parts = decodeFragment(fragment);
  const augmentedMutations = parts.mutations.map(
    (field) => field + "\n    @aws_auth(cognito_groups: [\"" + group + "\"])"
  );
  const augmentedQueries = parts.queries.map(
    (field) => field + " @aws_auth(cognito_groups: [\"" + group + "\"])"
  );
  const encoded = JSON.stringify({
    types: parts.types,
    mutations: augmentedMutations,
    queries: augmentedQueries,
  });
  return { encoded, protocol: "graphql" };
}

async function updateAppSyncSchema(apiId, sdl) {
  const { AppSyncClient, StartSchemaCreationCommand } = await import("@aws-sdk/client-appsync");
  const client = new AppSyncClient({});
  await client.send(new StartSchemaCreationCommand({ apiId, definition: sdl }));
}

// Fetch the current live AppSync schema as an SDL string for the shrink guard.
// Returns "" (not an error) when the API has no schema yet (first deploy) or
// introspection fails — the caller treats an empty current schema as "no
// baseline to protect", so the push proceeds.
async function getCurrentSchemaSdl(apiId) {
  try {
    const { AppSyncClient, GetIntrospectionSchemaCommand } = await import("@aws-sdk/client-appsync");
    const client = new AppSyncClient({});
    const resp = await client.send(new GetIntrospectionSchemaCommand({ apiId, format: "SDL" }));
    if (!resp || !resp.schema) return "";
    // resp.schema is a Uint8Array of the SDL text.
    return Buffer.from(resp.schema).toString("utf-8");
  } catch (e) {
    log.warn(`could not introspect current schema (${(e && e.message) || e}) — skipping shrink guard`, { comp: "updateApiSchema" });
    return "";
  }
}

// Shrink-guard threshold: abort the push if the new SDL has fewer than
// (threshold × current) root fields. Configurable via env; default 0.5 (50%).
// Anything outside (0, 1) falls back to the default.
function parseShrinkThreshold(raw) {
  const n = raw ? Number(raw) : NaN;
  return Number.isFinite(n) && n > 0 && n < 1 ? n : 0.5;
}

// Emit a CloudWatch metric via Embedded Metric Format (EMF). Any Lambda log line
// shaped like this is auto-parsed by CloudWatch into the metric
// Reventless/Runtime SchemaShrinkRejected (dimension ApiId) — no PutMetricData
// call, SDK dependency, or extra IAM permission required.
// NOTE: must stay as a raw `console.log` of the exact EMF envelope — routing
// through `log.info` would add `time`/`level`/`message` siblings and break
// CloudWatch's EMF auto-detect (the `_aws` block must be at the root of the
// log record).
function emitShrinkRejectionMetric(apiId, currentRootFields, newRootFields) {
  try {
    // eslint-disable-next-line no-console
    console.log(
      JSON.stringify({
        _aws: {
          Timestamp: Date.now(),
          CloudWatchMetrics: [
            {
              Namespace: "Reventless/Runtime",
              Dimensions: [["ApiId"]],
              Metrics: [{ Name: "SchemaShrinkRejected", Unit: "Count" }],
            },
          ],
        },
        ApiId: apiId,
        SchemaShrinkRejected: 1,
        currentRootFields,
        newRootFields,
      })
    );
  } catch (_) {}
}

const DEPLOY_SCHEMA_PREFIX = "deploy-schema:";

// Read every plugin's deploy-time SDL fragment from the dedicated
// PluginSchemaPersistence table (rows keyed "deploy-schema:<name>", written by
// Platform.preResolversSchemaHook at deploy time). begins_with("deploy-schema:")
// matches only Domain fragments — the platform ("deploy-schema-platform:") and
// hash ("deploy-schema-hash:") rows have a hyphen at that position, so they are
// excluded. Each row's `fragment` attribute is the encoded SDL string; wrap it
// in the {encoded, protocol} shape the stitcher consumes.
async function collectDeploySchemaFragments(tableName) {
  const rows = await scanByTableName(
    tableName,
    [["id", { TAG: "BeginsWith" }, { TAG: "String", _0: DEPLOY_SCHEMA_PREFIX }]],
    1000
  );
  return rows
    .map((row) =>
      row && typeof row.fragment === "string"
        ? { encoded: row.fragment, protocol: "graphql" }
        : null
    )
    .filter(Boolean);
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

function extractCorrelationId(records) {
  const first = records && records[0];
  if (!first) return undefined;
  const body = first.body;
  if (!body) return undefined;
  try {
    const parsed = JSON.parse(body);
    if (parsed && typeof parsed === "object") {
      const meta = parsed.meta;
      if (meta && typeof meta === "object" && typeof meta.correlationId === "string") {
        return meta.correlationId;
      }
    }
  } catch (_) {}
  return undefined;
}

const invalidNameChars = /[^.\-_a-zA-Z0-9]/g;
const resourceNaming = {
  validateName: (n) => n.replace(invalidNameChars, "_"),
  urnName: (arn) => {
    const parts = arn.split(":");
    return parts[5] || "unknown";
  },
};

// Admin-mediated cross-plugin SNS subscription manager (Plan Phase 3, Step 1).
// When DoConnectPlugin / DoDisconnectPlugin fires on the admin EP mapping, we
// scan the Plugin RM for currently-Connected peers and wire (or tear down) SNS
// subscriptions between this plugin's EventCollector queue and peer plugins'
// EP event topics — in both directions:
//   - peer EP topic → this plugin's EC queue, for each of this plugin's
//     extensions whose `extensionPointName` matches a peer EP
//   - this plugin's EP topics → peer EC queues, for each peer extension whose
//     `extensionPointName` matches one of this plugin's EPs
// subscribeQueueToTopic is idempotent (lists existing subscriptions first);
// unsubscribeQueueFromTopic is best-effort and swallows the "no subscription"
// case. Failures are logged but do not throw — admin's RM projection still
// proceeds and cold-start reconciliation will re-attempt missed work.
function mkManageSubscriptions(tableName) {
  if (!tableName || tableName === "NOT_AVAILABLE") return undefined;
  const trySubscribe = async (queueArn, topicArn, label) => {
    if (!queueArn || !topicArn) return;
    try {
      await subscribeQueueToTopic(queueArn, topicArn);
      log.info(`subscribed ${label}: ${topicArn} -> ${queueArn}`, { comp: "manageSubscriptions" });
    } catch (e) {
      const msg = (e && e.message) || String(e);
      log.error(`subscribe failed ${label}: ${topicArn} -> ${queueArn}`, { comp: "manageSubscriptions", detail: msg });
    }
  };
  const tryUnsubscribe = async (queueArn, topicArn, label) => {
    if (!queueArn || !topicArn) return;
    try {
      await unsubscribeQueueFromTopic(queueArn, topicArn);
      log.info(`unsubscribed ${label}: ${topicArn} -> ${queueArn}`, { comp: "manageSubscriptions" });
    } catch (e) {
      const msg = (e && e.message) || String(e);
      log.error(`unsubscribe failed ${label}: ${topicArn} -> ${queueArn}`, { comp: "manageSubscriptions", detail: msg });
    }
  };
  const scanConnectedPeers = async (excludeId) => {
    const rows = await scanByTableName(
      tableName,
      [["status", { TAG: "Contains" }, { TAG: "String", _0: "Connected" }]],
      1000
    );
    const peers = [];
    for (const row of rows) {
      const state = projectPluginRow(row);
      if (state && state.id !== excludeId) peers.push(state);
    }
    return peers;
  };
  // Extract the plugin display name from a versioned id like "Catalog@1.0.0-alpha.65".
  const pluginNameOfId = (id) => (typeof id === "string" ? id.split("@")[0] : "");
  return async (pluginDef, action) => {
    const isConnect = action === "connect";
    const op = isConnect ? trySubscribe : tryUnsubscribe;
    const peers = await scanConnectedPeers(pluginDef.id);
    // Subscriptions are wired between SNS topics and SQS queues that are owned
    // per PLUGIN NAME, not per version (the EC queue, EP event topics, and DCB
    // event topic ARNs all live in the plugin's stack and are stable across
    // version-to-version upgrades). When a superseded version is Retired and
    // its row transitions to Disconnected, this hook fires with action="disconnect"
    // — but if a newer version of the same plugin is still Connected, the
    // subscriptions are still in use. Tearing them down here would silently
    // break cross-plugin event flow for the live version (and only cold-start
    // reconciliation on the surviving plugin would heal it — which happens on
    // its next Lambda init, not immediately). Skip the tear-down in that case.
    if (!isConnect) {
      const myName = pluginNameOfId(pluginDef.id);
      const liveSibling = peers.find((p) => pluginNameOfId(p.id) === myName);
      if (liveSibling) {
        log.info(`disconnect skipped for ${pluginDef.id}: sibling version ${liveSibling.id} still Connected and shares the same EC queue / EP topics`, { comp: "manageSubscriptions" });
        return;
      }
    }
    // Subscriptions for this plugin's extensions: peer EP topic → this EC queue
    for (const ext of pluginDef.extensions || []) {
      for (const peer of peers) {
        const peerEp = (peer.extensionPoints || []).find(
          (ep) => ep.name === ext.extensionPointName
        );
        if (peerEp) {
          await op(pluginDef.eventCollector, peerEp.eventTopic, `${ext.extensionPointName} -> ${pluginDef.id}`);
        }
      }
    }
    // Subscriptions for this plugin's EPs: this EP topic → peer EC queues
    for (const ep of pluginDef.extensionPoints || []) {
      for (const peer of peers) {
        const matchingExt = (peer.extensions || []).find(
          (e) => e.extensionPointName === ep.name
        );
        if (matchingExt) {
          await op(peer.eventCollector, ep.eventTopic, `${ep.name} -> ${peer.id}`);
        }
      }
    }
    // ── Phase 4: DCB topic subscriptions ──────────────────────────────────
    // For each DCB source this plugin's extensions reference, subscribe this
    // plugin's EventCollector to the owning peer plugin's DCB EventTopic.
    for (const ext of pluginDef.extensions || []) {
      for (const dcbSourceName of ext.dcbSources || []) {
        const peer = peers.find(
          (p) => p.dcbEventLog && p.dcbEventLog.name === dcbSourceName
        );
        if (peer) {
          await op(
            pluginDef.eventCollector,
            peer.dcbEventLog.eventTopicArn,
            `dcb ${dcbSourceName} -> ${pluginDef.id}`
          );
        }
      }
    }
    // If THIS plugin has a DCB EventLog, subscribe each peer plugin's
    // EventCollector that references it via dcbSources.
    if (pluginDef.dcbEventLog) {
      const myDcbName = pluginDef.dcbEventLog.name;
      for (const peer of peers) {
        const consuming = (peer.extensions || []).some((e) =>
          (e.dcbSources || []).includes(myDcbName)
        );
        if (consuming) {
          await op(
            peer.eventCollector,
            pluginDef.dcbEventLog.eventTopicArn,
            `dcb ${myDcbName} -> ${peer.id}`
          );
        }
      }
    }
  };
}

// Cold-start reconciliation — scan the Plugin RM for every Connected plugin
// and rerun manageSubscriptions(p, "connect") for each. Idempotent at the SNS
// level (subscribeQueueToTopic dedupes), so this is safe to run repeatedly;
// it catches subscriptions lost out-of-band (topic deleted+recreated, plugin
// restarted with a new EC ARN, etc.). Fire-and-forget — admin still serves
// incoming events while reconciliation completes.
async function reconcileSubscriptionsOnce(tableName, manageSubscriptions) {
  if (!tableName || tableName === "NOT_AVAILABLE" || !manageSubscriptions) return;
  try {
    const rows = await scanByTableName(
      tableName,
      [["status", { TAG: "Contains" }, { TAG: "String", _0: "Connected" }]],
      1000
    );
    for (const row of rows) {
      const state = projectPluginRow(row);
      if (state) {
        try {
          await manageSubscriptions(state, "connect");
        } catch (e) {
          log.warn("manageSubscriptions failed", { comp: "reconcileSubscriptions", detail: (e && e.message) || String(e) });
        }
      }
    }
  } catch (e) {
    log.warn("scan failed", { comp: "reconcileSubscriptions", detail: (e && e.message) || String(e) });
  }
}

// Re-stitch and push the live AppSync schema on each plugin Connect/Disconnect.
//
// Source of plugin fragments (option A): the durable PluginSchemaPersistence
// table (deploy-time "deploy-schema:<name>" rows), NOT the lifecycle-volatile
// Plugin RM "Connected" rows. Reading the deploy-time source means lifecycle
// churn (a redeploy window where every plugin is briefly Disconnected, an
// eventually-consistent scan, etc.) can no longer shrink the stitched schema —
// every push re-asserts the full deployed set rather than clobbering field
// resolvers with whatever subset happened to be Connected at scan time. The
// Plugin RM scan remains only as a fallback for older platform stacks deployed
// before the dedicated table existed (schemaTableName === "NOT_AVAILABLE").
//
// Circuit breaker (option D, defense-in-depth): before pushing, introspect the
// current live schema and compare root-type (Mutation + Query) field counts. If
// the new SDL drops below the configured fraction of the live field count, abort
// the push, log loudly, and emit a CloudWatch metric — catching any
// catastrophic shrink the source switch alone misses.
function mkUpdateApiSchema(schemaTableName, apiId, clonerEnabled) {
  if (!apiId || apiId === "NOT_AVAILABLE") return undefined;
  const hasSchemaTable = !!schemaTableName && schemaTableName !== "NOT_AVAILABLE";
  return async (queryEngine) => {
    let fragments;
    if (hasSchemaTable) {
      fragments = await collectDeploySchemaFragments(schemaTableName);
      log.info(`stitching ${fragments.length} deploy-schema fragment(s) from ${schemaTableName}`, { comp: "updateApiSchema" });
    } else {
      const resolved = await queryEngine.scan(
        "Plugin",
        [["status", { TAG: "Contains" }, { TAG: "String", _0: "Connected" }]],
        1000
      );
      fragments = resolved.map((json) => json && json.apiSchemaFragment).filter(Boolean);
      log.warn(`PluginSchemaPersistence table unavailable — falling back to ${fragments.length} Connected Plugin RM fragment(s)`, { comp: "updateApiSchema" });
    }
    const adminBase = injectAwsAuthAll(adminBaseFragment(clonerEnabled || false), "Admin");
    const sdl = graphqlStitch(adminBase, fragments);

    // Shrink guard — never let a transient/incomplete stitch clobber the live schema.
    const threshold = parseShrinkThreshold(process.env["RUNTIME_SCHEMA_SHRINK_THRESHOLD"]);
    const currentSdl = await getCurrentSchemaSdl(apiId);
    if (isCatastrophicSchemaShrink(currentSdl, sdl, threshold)) {
      const currentRootFields =
        countRootTypeFields(currentSdl, "Mutation") + countRootTypeFields(currentSdl, "Query");
      const newRootFields =
        countRootTypeFields(sdl, "Mutation") + countRootTypeFields(sdl, "Query");
      log.error(`ABORTED schema push for ${apiId}: new SDL has ${newRootFields} root field(s) vs ${currentRootFields} live (threshold ${threshold}). Refusing to clobber resolvers.`, { comp: "updateApiSchema" });
      emitShrinkRejectionMetric(apiId, currentRootFields, newRootFields);
      return;
    }
    await updateAppSyncSchema(apiId, sdl);
  };
}

function buildPublishToAggregates(map) {
  const out = {};
  for (const [aggName, envVarName] of Object.entries(map || {})) {
    const queueUrl = process.env[envVarName] || "";
    out[aggName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
  }
  return out;
}

function dictByServiceKeys(serviceKeys, handler) {
  const dict = {};
  for (const k of serviceKeys || []) {
    if (!dict[k]) dict[k] = [];
    dict[k].push(handler);
  }
  return dict;
}

function mergeDicts(...dicts) {
  const out = {};
  for (const d of dicts) {
    for (const [k, v] of Object.entries(d)) {
      out[k] = (out[k] || []).concat(v);
    }
  }
  return out;
}

// pluginDefinition is shipped as a file in the asset zip rather than packed
// into HANDLER_CONFIG (AWS Lambda's UpdateFunctionConfiguration request has a
// 5120-byte limit; pluginStructure alone — schemas inline per component —
// blew past that). The Lambda runtime extracts the zip to /var/task, and the
// re-export index.mjs lives at /var/task/index.mjs alongside
// pluginDefinition.json. process.cwd() is /var/task in Lambda, so a relative
// path resolves correctly. The file is parsed once at cold start.
function loadPluginDefinition() {
  try {
    const raw = readFileSync(new URL("./pluginDefinition.json", `file://${process.cwd()}/`), "utf-8");
    return JSON.parse(raw);
  } catch (e) {
    const msg = (e && e.message) || String(e);
    throw new Error("Failed to load pluginDefinition.json from asset zip: " + msg);
  }
}

// Cross-plugin spec packages (e.g. "@reventlessdev/online-shop-hybrid-catalog-spec")
// are bundled into the function asset under /var/task/node_modules/ by
// PluginRuntime_Builder.forPluginEventCollector. This entry-point file, however,
// lives in the Lambda LAYER at /opt/nodejs/node_modules/.../AdminEventCollectorEntryPoint.mjs,
// so a bare `await import("@reventlessdev/online-shop-hybrid-catalog-spec/...")`
// from here resolves through /opt/nodejs/node_modules/ and never reaches the
// function asset. Anchoring createRequire at file:///var/task/index.mjs makes
// resolution walk /var/task/node_modules first (and NODE_PATH-listed dirs as
// fallback, which Lambda sets to /opt/nodejs/node_modules — so static-import
// targets like reventless-core still resolve too). We then turn the resolved
// filesystem path into a file:// URL and dynamic-import it.
const importFromAsset = (() => {
  const requireFromAsset = createRequire(`file://${process.cwd()}/index.mjs`);
  return async (specifier) => {
    const resolved = requireFromAsset.resolve(specifier);
    return import(pathToFileURL(resolved).href);
  };
})();

async function buildHandler() {
  const config = parseHandlerConfig(process.env["HANDLER_CONFIG"]);
  const pluginDefinition = loadPluginDefinition();
  const lambdaFunctionName = process.env["AWS_LAMBDA_FUNCTION_NAME"] || "unknown";

  // runtimeOps carries only what the admin EP mapping's callHandler actually
  // needs: sendMessageToChannel for ForwardCommand. Cross-plugin SNS
  // subscription wiring moved to manageSubscriptionsFn (Phase 3 Step 1 +
  // Step 3) — the topicSubscription stubs that the plugin Connect extension
  // used to call no longer exist on either side.
  const runtimeOps = {
    messagePublish: { sendMessageToChannel: sendMessage },
  };

  const queryEngine = {
    scan: (readModelName, filterConfigs, limit) =>
      scanByTableName(config.pluginReadModelTableName, filterConfigs, limit),
    query: async () => {
      throw new Error("QueryEngine.query not available in bundled Plugin EventCollector");
    },
  };

  const scheduler = {
    createSchedule: cwCreateSchedule(config.schedulerRoleArn),
    deleteSchedule: cwDeleteSchedule,
  };

  const commandTopicResources = config.schedulerQueueArn !== ""
    ? [{
        name: config.schedulerQueueName,
        id: config.schedulerQueueName,
        urn: config.schedulerQueueArn,
        service: "unknown",
        resourceInfo: "NoInfo",
        role: "",
        region: "",
        resourceType: "",
        configuration: {},
        tags: {},
      }]
    : [];

  const updateApiSchemaFn = mkUpdateApiSchema(
    config.pluginSchemaPersistenceTableName,
    config.appSyncApiId,
    config.clonerEnabled,
  );

  const manageSubscriptionsFn = mkManageSubscriptions(config.pluginReadModelTableName);

  // EP operations — admin has 1 entry (Plugin EP), plugins have N user EPs.
  //
  // Two mapping shapes flow through `config.extensionPoints`:
  //
  //   1. Admin-internal (PluginExtensionPoint_Plugin.res.mjs) — exports a
  //      `Make(Spec)` functor consuming runtime ops. Used only by the admin
  //      Lambda's Plugin EP. Returns `{Mapping}`.
  //
  //   2. User-authored (e.g. Products_ExtensionPointMapping.res.mjs) — exports
  //      the Mapping fields at top level (mapIncomingCommand, mapOutgoingEvent,
  //      Delegate, ...) with NO `Make` functor. Used by every plugin EC Lambda
  //      that declares an ExtensionPoint. The ExtensionPoint spec module is
  //      erased at compile time and must be re-attached at runtime.
  //
  // Dispatch on `typeof Make === function` to handle both. Mirrors the
  // user-extensions branch below which already does this for ExtensionMappings.
  const epHandlers = await Promise.all(config.extensionPoints.map(async (ep) => {
    const specMod = patchSpecId(await importFromAsset(ep.specModule));
    const mappingsMod = await importFromAsset(ep.mappingsModule);

    let mappingsModule;
    if (typeof mappingsMod.Make === "function") {
      // Admin's Plugin EP: invoke the Make functor with runtime ops.
      const epModule = mappingsMod.Make({
        runtimeOps,
        environment: lambdaFunctionName,
        updateApiSchema: updateApiSchemaFn,
        manageSubscriptions: manageSubscriptionsFn,
      });
      mappingsModule = { mappings: [epModule.Mapping] };
    } else {
      // User EP: reconstruct MappingImpl from top-level exports, re-attach
      // the erased ExtensionPoint spec module, then transform input shape
      // (mapIncomingCommand/mapOutgoingEvent) into the runtime T shape via
      // ExtensionPointMapping.Make. `Delegate.Id` is also patched via
      // patchSpecId — the inner `module Delegate = { module Id = Id.String; … }`
      // is erased at compile time the same way the top-level `module Id` is,
      // and ExtensionPointMapping.Make reads `Delegate.Id.schema` at runtime to
      // decode incoming events.
      const mappingImpl = {
        ...mappingsMod,
        ExtensionPoint: specMod,
        Delegate: patchSpecId(mappingsMod.Delegate),
        moduleUrl: ep.mappingsModule,
      };
      const transformedMapping = extensionPointMappingMake(mappingImpl);
      mappingsModule = { mappings: [transformedMapping] };
    }

    const resolvedTopic = {
      name: ep.eventTopicArn,
      id: ep.eventTopicArn,
      arn: ep.eventTopicArn,
    };
    const ops = extensionPointOperationsMake(specMod)(mappingsModule)({
      publishToEventTopic: (id, meta, json) => snsPublish(resolvedTopic, id, meta, json),
      commandTopicResources,
      scheduler,
      queryEngine,
      resourceNaming,
    });
    return {
      aggregateNames: ep.aggregateNames || [],
      outgoingHandler: ops.outgoingJsonEventsHandler,
    };
  }));

  // Connect extension — exactly one entry per plugin Lambda; null for admin.
  const publishToAggregates = buildPublishToAggregates(config.publishToAggregates);
  const publishToPluginExtensionPoint = sqsPublishJsons(
    makeQueueRef(config.pluginExtensionPointCmdTopicUrl),
    "SQS_FIFO",
  );

  let connectExtensionHandler = null;
  if (config.connectExtension) {
    const ext = config.connectExtension;
    const specMod = patchSpecId(await importFromAsset(ext.specModule));
    const mappingsMod = await importFromAsset(ext.mappingsModule);
    // After Phase 3 of plugin-eventcollector-runtime-rewire, the Connect
    // extension Spec carries only pluginDefinition — cross-plugin subscribe /
    // unsubscribe directives moved to admin's manageSubscriptions hook.
    const extBuilder = mappingsMod.Make({
      pluginDefinition,
    });
    // PluginConnectExtension_Builder.Make returns a module exposing:
    //   - ConnectPluginMapping  (single mapping)
    //   - ConnectPluginMappings (Mappings module: {Spec, name, mappings, moduleUrl})
    // Use ConnectPluginMappings as the Mappings arg to Extension_Operations.Make.
    const mappingsModule = extBuilder.ConnectPluginMappings;
    const ops = extensionOperationsMake(specMod)(mappingsModule)({
      publishToAggregates,
      publishToPluginExtensionPoint,
      readModelNamesForSourceName: {},
      publishToReadModels: {},
      queryEngine,
    });
    connectExtensionHandler = {
      extensionPointName: ext.extensionPointName,
      incomingHandler: ops.incomingJsonEventsHandler,
    };
  }

  // User-declared extensions — per-entry: three dynamic imports (EP spec,
  // user mapping file, Delegate spec), reconstruct the full Mapping object
  // (compiled .res.mjs erases Mapping.ExtensionPoint / Mapping.Delegate), run
  // it through ExtensionMapping.Make, and build per-extension Extension_Operations.
  const userExtensionHandlers = await Promise.all(config.extensions.map(async (ext) => {
    if (!ext.specModule || !ext.mappingsModule || !ext.delegateModule) {
      log.warn("extension '" + ext.name + "' missing module specifier(s); skipping. specModule=" + ext.specModule + ", mappingsModule=" + ext.mappingsModule + ", delegateModule=" + ext.delegateModule, { comp: "AdminEventCollectorEntryPoint" });
      return null;
    }
    const epSpec = patchSpecId(await importFromAsset(ext.specModule));
    const userMod = await importFromAsset(ext.mappingsModule);
    const delegateSpec = patchSpecId(await importFromAsset(ext.delegateModule));

    // Reconstruct Mapping with the freshly imported specs re-attached. The
    // moduleUrl / delegateModuleUrl fields satisfy the ExtensionMapping.Mapping
    // module type — ExtensionMapping.Make doesn't currently consume them at
    // runtime, but we set them for shape parity.
    const fullMapping = {
      ExtensionPoint: epSpec,
      Delegate: delegateSpec,
      moduleUrl: ext.mappingsModule,
      delegateModuleUrl: ext.delegateModule,
      mapIncomingEvent: userMod.Mapping.mapIncomingEvent,
      mapOutgoingEvent: userMod.Mapping.mapOutgoingEvent,
    };
    const transformedMapping = extensionMappingMake(fullMapping);
    const mappingsModule = {
      name: ext.name,
      moduleUrl: ext.mappingsModule,
      mappings: [transformedMapping],
    };

    // Per-extension publishToAggregates filtered to ext.aggregateNames —
    // each aggregate's cmd-topic SQS URL is looked up via the
    // PTA_<aggName>_QUEUE_URL env var name carried in HANDLER_CONFIG.
    const extPublishToAggregates = {};
    for (const aggName of ext.aggregateNames) {
      const envVarName = config.publishToAggregates[aggName];
      if (!envVarName) continue;
      const queueUrl = process.env[envVarName] || "";
      if (!queueUrl) continue;
      extPublishToAggregates[aggName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
    }

    // Per-extension publishToReadModels — each RM's EventCollector SQS URL
    // is looked up via the PRM_<rmName>_QUEUE_URL env var name carried in
    // HANDLER_CONFIG.readModelQueueUrls.
    const extPublishToReadModels = {};
    for (const rmName of ext.readModelNames) {
      const envVarName = config.readModelQueueUrls[rmName];
      if (!envVarName) continue;
      const queueUrl = process.env[envVarName] || "";
      if (!queueUrl) continue;
      extPublishToReadModels[rmName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
    }

    // readModelNamesForSourceName scoped to this extension's EP — Extension_Operations
    // uses this dict to decide which RMs receive each incoming event.
    const extReadModelNamesForSourceName = {
      [ext.extensionPointName]:
        config.readModelNamesForSourceName[ext.extensionPointName] || [],
    };

    const ops = extensionOperationsMake(epSpec)(mappingsModule)({
      publishToAggregates: extPublishToAggregates,
      publishToPluginExtensionPoint,
      readModelNamesForSourceName: extReadModelNamesForSourceName,
      publishToReadModels: extPublishToReadModels,
      queryEngine,
    });

    return {
      extensionPointName: ext.extensionPointName,
      aggregateNames: ext.aggregateNames,
      incomingHandler: ops.incomingJsonEventsHandler,
      outgoingHandler: ops.outgoingJsonEventsHandler,
    };
  }));
  const extensionHandlers = userExtensionHandlers.filter(Boolean);

  // Build the four service-keyed dicts that Plugin_Callback.Make consumes.
  const outgoingExtensionPointEventHandlers = epHandlers
    .map((eph) => dictByServiceKeys(eph.aggregateNames, eph.outgoingHandler))
    .reduce(mergeDicts, {});
  const incomingConnectExtensionEventHandlers = connectExtensionHandler
    ? { [connectExtensionHandler.extensionPointName]: [connectExtensionHandler.incomingHandler] }
    : {};
  const outgoingExtensionEventHandlers = extensionHandlers
    .map((eh) => dictByServiceKeys(eh.aggregateNames, eh.outgoingHandler))
    .reduce(mergeDicts, {});
  const incomingExtensionEventHandlers = extensionHandlers
    .map((eh) => ({ [eh.extensionPointName]: [eh.incomingHandler] }))
    .reduce(mergeDicts, {});

  const callback = pluginCallbackMake({
    pluginDefinition,
    incomingConnectExtensionEventHandlers,
    outgoingExtensionPointEventHandlers,
    outgoingExtensionEventHandlers,
    incomingExtensionEventHandlers,
  });

  // Cold-start reconciliation — awaited so it finishes inside the same
  // invocation that initialised the Lambda. Fire-and-forget doesn't work on
  // Lambda: any unfinished promise pauses when the runtime freezes between
  // invocations and rarely gets a chance to resume. Idempotent at the SNS
  // level, so the modest extra init latency is paid only on true cold starts.
  await reconcileSubscriptionsOnce(config.pluginReadModelTableName, manageSubscriptionsFn);

  return handleDynamoDbOrSqsEvent(makeQueueRef(config.queueUrl), callback.handleJsonEvents);
}

const sqsHandlerPromise = buildHandler();

export async function handler(event, context) {
  _currentRequestId = context?.awsRequestId || "unknown";
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);
  log.debug("processing " + records.length.toString() + " record(s)", { comp: "PluginEventCollectorRuntime" });
  const sqsHandler = await sqsHandlerPromise;
  await runEffect(correlationId, sqsHandler(event, context));
  return "";
}
