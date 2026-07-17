// ExtensionPoint Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Mappings,
// wires ExtensionPoint_Callback.Make + CommandTopic_Callback.Make,
// routes SQS events through handleQueueEvent.

import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef, log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as extensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

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
  _currentRequestId = context?.awsRequestId || "unknown";
  const sqsHandler = await initPromise;
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);

  log.debug("processing " + records.length.toString() + " record(s)", { comp: "ExtensionPointRuntime" });
  await runEffect(correlationId, sqsHandler(event, context));
  return "";
}
