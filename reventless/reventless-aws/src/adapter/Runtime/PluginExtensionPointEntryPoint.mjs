// PluginExtensionPoint Lambda entry point.
// All imports are framework packages — no user modules needed.
// Handles Heartbeat, Cloner, and other plugin-level extension point commands.

import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef, scanByTableName } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/util/Util_PluginMessage_Runtime.res.mjs";
import * as PluginExtensionPointSpec from "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs";
import { Make as pluginEPPluginMake } from "@reventlessdev/reventless-core/src/admin/PluginExtensionPoint_Plugin.res.mjs";
import { Make as extensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { createSchedule as cwCreateSchedule, deleteSchedule as cwDeleteSchedule } from "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs";

function runEffect(correlationId, effect) {
  return effect
    .pipe(Effect.provideService(requestContextTag, { correlationId: correlationId || "unknown" }))
    .pipe(Effect.runPromise);
}

function extractCorrelationId(records) {
  const first = records[0];
  if (!first) return undefined;
  const body = first.body;
  if (!body) return undefined;
  try {
    const parsed = JSON.parse(body);
    if (typeof parsed === "object" && parsed !== null) {
      const meta = parsed.meta;
      if (meta && typeof meta === "object" && typeof meta.correlationId === "string") {
        return meta.correlationId;
      }
    }
  } catch (_) {}
  return undefined;
}

function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);

  const patchedSpec = patchSpecId(PluginExtensionPointSpec);

  // Reconstruct runtimeOps
  const runtimeOps = {
    messagePublish: { sendMessageToChannel: sendMessage },
    topicSubscription: {
      subscribeChannelToTopic: async () => {},
      unsubscribeChannelFromTopic: async () => {},
    },
  };

  // Instantiate Plugin EP mapping
  const lambdaFunctionName = process.env["AWS_LAMBDA_FUNCTION_NAME"] || "unknown";
  const pluginModule = pluginEPPluginMake({ runtimeOps, environment: lambdaFunctionName, updateApiSchema: undefined });
  const mappingsModule = { mappings: [pluginModule.Mapping] };

  // Reconstruct publishToAggregates. The deploy-side builder writes
  // HANDLER_CONFIG.publishToAggregates as { aggregateName: envVarName }
  // (see PluginExtensionPointRuntime_Builder.res), so iterate accordingly.
  const publishToAggregates = {};
  for (const [aggName, envVarName] of Object.entries(config.publishToAggregates || {})) {
    const queueUrl = process.env[envVarName] || "";
    publishToAggregates[aggName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
  }

  // Reconstruct queryEngine
  const queryEngine = {
    scan: (readModelName, filterConfigs, limit) => scanByTableName(config.pluginReadModelTableName, filterConfigs, limit),
    query: async () => { throw new Error("QueryEngine.query not available in bundled Plugin EP handler"); },
  };

  // Reconstruct scheduler
  const scheduler = {
    createSchedule: cwCreateSchedule(config.schedulerRoleArn),
    deleteSchedule: cwDeleteSchedule,
  };

  // CommandTopic resources for scheduler targets
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

  const invalidNameChars = /[^.\-_a-zA-Z0-9]/g;
  const resourceNaming = {
    validateName: (n) => n.replace(invalidNameChars, "_"),
    urnName: (arn) => { const parts = arn.split(":"); return parts[5] || "unknown"; },
  };

  const callbackConfig = { publishToAggregates, commandTopicResources, scheduler, queryEngine, resourceNaming };
  const callback = extensionPointCallbackMake(callbackConfig)(patchedSpec)(mappingsModule);
  const commandTopicCallback = commandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: callback.handleIncomingCommands,
  });

  return handleQueueEvent(makeQueueRef(config.queueUrl), commandTopicCallback.handleJsonCommands);
}

const sqsHandler = buildHandler();

export async function handler(event, context) {
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);

  console.log("----- pluginExtensionPointHandler: processing " + records.length.toString() + " record(s)");
  await runEffect(correlationId, sqsHandler(event, context));
  return "";
}
