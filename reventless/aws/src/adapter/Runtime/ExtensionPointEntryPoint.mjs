// ExtensionPoint Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Mappings,
// wires ExtensionPoint_Callback.Make + CommandTopic_Callback.Make,
// routes SQS events through handleQueueEvent.

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
import { Make as extensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);

  const specModule = await dynamicImport(config.specModule);
  const mappingsModule = await dynamicImport(config.mappingsModule);

  const patchedSpec = patchSpecId(specModule);

  // Build publishToAggregates dict from env var queue URLs. The deploy-side
  // builder writes HANDLER_CONFIG.publishToAggregates as { aggregateName: envVarName }
  // (see ExtensionPointRuntime_Builder_PerExtensionPoint.res), so iterate accordingly.
  const publishToAggregates = {};
  for (const [aggName, envVarName] of Object.entries(config.publishToAggregates || {})) {
    const queueUrl = process.env[envVarName] || "";
    publishToAggregates[aggName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
  }

  const callbackConfig = {
    publishToAggregates,
    commandTopicResources: [],
    scheduler: {
      create: async () => { throw new Error("Scheduler not available in bundled ExtensionPoint handler"); },
      delete: async () => { throw new Error("Scheduler not available in bundled ExtensionPoint handler"); },
    },
    queryEngine: {
      scan: async () => { throw new Error("QueryEngine not available in bundled ExtensionPoint handler"); },
      query: async () => { throw new Error("QueryEngine not available in bundled ExtensionPoint handler"); },
    },
    resourceNaming: { name: (n) => n, resolve: (n) => n },
  };

  const callback = extensionPointCallbackMake(callbackConfig)(patchedSpec)(mappingsModule);
  const commandTopicCallback = commandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: callback.handleIncomingCommands,
  });

  const resolvedQueue = makeQueueRef(config.queueUrl);
  // Pair the handler with the extension point it serves so the invocation's log
  // lines name the component, not just this Lambda.
  return {
    sqsHandler: handleQueueEvent(resolvedQueue, commandTopicCallback.handleJsonCommands),
    comp: `ExtensionPoint(${patchedSpec.name})`,
  };
}

const initPromise = buildHandler();

export async function handler(event, context) {
  setRequestId(context?.awsRequestId);
  const { sqsHandler, comp } = await initPromise;
  const records = event.Records || [];

  log.debug("processing " + records.length.toString() + " record(s)", { comp: "ExtensionPointRuntime" });
  await runEffect(sqsHandler(event, context), {
    correlationId: extractMetaField(records, "correlationId"),
    causationId: extractMetaField(records, "causationId"),
    comp,
    timestamp: extractSentTimestamp(records),
    retryCount: extractRetryCount(records),
  });
  return "";
}
