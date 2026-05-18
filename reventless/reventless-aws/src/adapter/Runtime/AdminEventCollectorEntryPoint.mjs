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
//   "extensions": [],                          // User-declared extensions — reserved for future; not yet wired
//   "publishToAggregates": {                   // aggregateName → env-var name holding the aggregate's cmd-topic SQS URL
//     "Plugin": "PTA_Plugin_QUEUE_URL"
//   }
// }
//
// Why this shape and not separate entry points per Lambda: at deploy time both the
// admin EventCollector and every per-plugin EventCollector share the same code
// asset (this file). The runtime differences are entirely data — which EPs to
// process outgoing events for (admin only) and which Connect extension to wire
// (plugin only). Plugin_Callback.Make routes incoming SQS events to the right
// service-keyed handler dict; we reconstruct those dicts here from HANDLER_CONFIG.

import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef, scanByTableName } from "./HandlerFactoryHelpers.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/util/Util_PluginMessage_Runtime.res.mjs";
import { publish as snsPublish } from "@reventlessdev/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS_Runtime.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { Make as extensionPointOperationsMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res.mjs";
import { Make as extensionOperationsMake } from "@reventlessdev/reventless-core/src/components/Extension/Extension_Operations.res.mjs";
import { Make as pluginCallbackMake } from "@reventlessdev/reventless-core/src/components/Plugin/Plugin_Callback.res.mjs";
import { handleDynamoDbOrSqsEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res.mjs";
import { createSchedule as cwCreateSchedule, deleteSchedule as cwDeleteSchedule } from "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs";
import { stitch as graphqlStitch, decode as decodeFragment } from "@reventlessdev/reventless-core/src/components/Api/GraphQL_Stitcher.res.mjs";
import { baseFragment as adminBaseFragment } from "@reventlessdev/reventless-core/src/admin/AdminApi.res.mjs";
import { stateSchema as pluginReadModelStateSchema } from "@reventlessdev/reventless-core/src/admin/PluginReadModelSpec.res.mjs";
import { parseOrThrow as suryParseOrThrow } from "sury/src/S.res.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";

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
    "pluginDefinition",
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

function runEffect(correlationId, effect) {
  return effect
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

function mkUpdateApiSchema(tableName, apiId, clonerEnabled) {
  if (!apiId || apiId === "NOT_AVAILABLE") return undefined;
  return async (queryEngine) => {
    const plugins = queryEngine.scan(
      "Plugin",
      [["status", { TAG: "Contains" }, { TAG: "String", _0: "Connected" }]],
      1000
    );
    const resolved = await plugins;
    const fragments = resolved
      .map((json) => {
        try {
          const state = suryParseOrThrow(json, pluginReadModelStateSchema);
          return state.apiSchemaFragment;
        } catch (_) { return undefined; }
      })
      .filter(Boolean);
    const adminBase = injectAwsAuthAll(
      adminBaseFragment(clonerEnabled || false),
      "Admin"
    );
    const sdl = graphqlStitch(adminBase, fragments);
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

async function buildHandler() {
  const config = parseHandlerConfig(process.env["HANDLER_CONFIG"]);
  const lambdaFunctionName = process.env["AWS_LAMBDA_FUNCTION_NAME"] || "unknown";

  const runtimeOps = {
    messagePublish: { sendMessageToChannel: sendMessage },
    topicSubscription: {
      // Cross-plugin subscribe/unsubscribe is deferred — see plan
      // docs/plans/plugin-eventcollector-runtime-rewire.md (Step 5 deferral note).
      // PluginConnectExtension.callHandler iterates extensionPointsOutputs/extensionsOutputs
      // which are empty in the runtime-reconstructed Spec, so these no-ops are unreachable
      // for the initial Connect flow.
      subscribeChannelToTopic: async () => {},
      unsubscribeChannelFromTopic: async () => {},
    },
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
    config.pluginReadModelTableName,
    config.appSyncApiId,
    config.clonerEnabled,
  );

  // EP operations — admin has 1 entry (Plugin EP), plugins have 0.
  const epHandlers = await Promise.all(config.extensionPoints.map(async (ep) => {
    const specMod = patchSpecId(await import(ep.specModule));
    const mappingsMod = await import(ep.mappingsModule);
    const epModule = mappingsMod.Make({
      runtimeOps,
      environment: lambdaFunctionName,
      updateApiSchema: updateApiSchemaFn,
    });
    const mappingsModule = { mappings: [epModule.Mapping] };
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
    const specMod = patchSpecId(await import(ext.specModule));
    const mappingsMod = await import(ext.mappingsModule);
    const extBuilder = mappingsMod.Make({
      pluginDefinition: config.pluginDefinition,
      // Cross-plugin extensionPoints/extensionsOutputs are deferred — see plan.
      // ConnectPluginExtension.callHandler iterates these (empty → no-op).
      extensionPointsOutputs: [],
      extensionsOutputs: [],
      runtimeOps,
      resourceNaming,
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

  // User-declared extensions — placeholder for future scope. Plan defers wiring;
  // when added, populate outgoingExtensionEventHandlers (by aggregateNames) and
  // incomingExtensionEventHandlers (by extensionPointName) here.
  if (config.extensions.length > 0) {
    console.warn("AdminEventCollectorEntryPoint: user extensions in HANDLER_CONFIG are not yet wired; ignoring " + config.extensions.length + " entry/entries");
  }

  // Build the four service-keyed dicts that Plugin_Callback.Make consumes.
  const outgoingExtensionPointEventHandlers = epHandlers
    .map((eph) => dictByServiceKeys(eph.aggregateNames, eph.outgoingHandler))
    .reduce(mergeDicts, {});
  const incomingConnectExtensionEventHandlers = connectExtensionHandler
    ? { [connectExtensionHandler.extensionPointName]: [connectExtensionHandler.incomingHandler] }
    : {};
  const outgoingExtensionEventHandlers = {};
  const incomingExtensionEventHandlers = {};

  const callback = pluginCallbackMake({
    pluginDefinition: config.pluginDefinition,
    incomingConnectExtensionEventHandlers,
    outgoingExtensionPointEventHandlers,
    outgoingExtensionEventHandlers,
    incomingExtensionEventHandlers,
  });

  return handleDynamoDbOrSqsEvent(makeQueueRef(config.queueUrl), callback.handleJsonEvents);
}

const sqsHandlerPromise = buildHandler();

export async function handler(event, context) {
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);
  console.log("----- pluginEventCollectorHandler: processing " + records.length.toString() + " record(s)");
  const sqsHandler = await sqsHandlerPromise;
  await runEffect(correlationId, sqsHandler(event, context));
  return "";
}
