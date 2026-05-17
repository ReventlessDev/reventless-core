// ExtensionPoint Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Mappings,
// wires ExtensionPoint_Callback.Make + CommandTopic_Callback.Make,
// routes SQS events through handleQueueEvent.

import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as extensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

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
  return handleQueueEvent(resolvedQueue, commandTopicCallback.handleJsonCommands);
}

const initPromise = buildHandler();

export async function handler(event, context) {
  const sqsHandler = await initPromise;
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);

  console.log("----- extensionPointHandler: processing " + records.length.toString() + " record(s)");
  await runEffect(correlationId, sqsHandler(event, context));
  return "";
}
