// PluginExtensionPoint Lambda entry point.
// All imports are framework packages — no user modules needed.
// Handles Heartbeat, Cloner, and other plugin-level extension point commands.

import {
  patchSpecId,
  makeQueueRef,
  scanByTableName,
  log,
  runEffect,
  setRequestId,
  extractMetaField,
  extractSentTimestamp,
  extractRetryCount,
} from "./HandlerFactoryHelpers.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/plugin/runtime/Util_PluginMessage_Runtime.res.mjs";
import * as PluginExtensionPointSpec from "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs";
import { Make as pluginEPPluginMake } from "@reventlessdev/reventless-core/src/plugin/connect/PluginExtensionPoint_Plugin.res.mjs";
import { Make as extensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { createSchedule as cwCreateSchedule, deleteSchedule as cwDeleteSchedule } from "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs";

function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);

  const patchedSpec = patchSpecId(PluginExtensionPointSpec);

  // Reconstruct runtimeOps — only sendMessageToChannel is used by this
  // Lambda's incoming-command path (ForwardCommand). Cross-plugin
  // subscribe / unsubscribe directives were retired in Phase 3 Step 3.
  const runtimeOps = {
    messagePublish: { sendMessageToChannel: sendMessage },
  };

  // Instantiate Plugin EP mapping. updateApiSchema and manageSubscriptions are
  // admin-only hooks; this Lambda only handles incoming commands (Heartbeat,
  // ForwardCommand) so they stay undefined here.
  //
  // `environment` prefixes the disconnect schedule's EventBridge rule name, so it
  // must be stable across deploys and unique per stack. The stack name is both;
  // AWS_LAMBDA_FUNCTION_NAME is neither — it carries a content hash, so replacing
  // this Lambda would orphan every outstanding rule the previous generation
  // created. EventCollectorEntryPoint instantiates the same EP module and must
  // agree, or one Lambda creates rules the other cannot delete.
  const environment = process.env["Environment"] || "unknown";
  const pluginModule = pluginEPPluginMake({
    runtimeOps,
    environment,
    updateApiSchema: undefined,
    manageSubscriptions: undefined,
  });
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

  return {
    sqsHandler: handleQueueEvent(makeQueueRef(config.queueUrl), commandTopicCallback.handleJsonCommands),
    comp: `ExtensionPoint(${patchedSpec.name})`,
  };
}

const { sqsHandler, comp } = buildHandler();

export async function handler(event, context) {
  setRequestId(context?.awsRequestId);
  const records = event.Records || [];

  log.debug("processing " + records.length.toString() + " record(s)", { comp: "PluginExtensionPointRuntime" });
  await runEffect(sqsHandler(event, context), {
    correlationId: extractMetaField(records, "correlationId"),
    causationId: extractMetaField(records, "causationId"),
    comp,
    timestamp: extractSentTimestamp(records),
    retryCount: extractRetryCount(records),
  });
  return "";
}
