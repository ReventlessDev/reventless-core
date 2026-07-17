// SideEffectHandler Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports SideEffect modules,
// wires SideEffectHandler_Callback.Make, builds handler map keyed by source URN.

import * as Effect from "effect/Effect";
import { log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as sideEffectHandlerCallbackMake } from "@reventlessdev/reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";

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

function groupBySource(records) {
  const dict = {};
  records.forEach(record => {
    const arn = record.eventSourceARN;
    const existing = dict[arn] || [];
    dict[arn] = existing.concat([record]);
  });
  return dict;
}

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const handlers = {};

  await Promise.all(config.handlers.map(async h => {
    const sideEffectModules = await Promise.all(
      h.sideEffectModules.map(async modPath => await dynamicImport(modPath))
    );
    const noOpQueryEngine = { scan: async () => [], query: async () => [] };
    const callback = sideEffectHandlerCallbackMake({ sideEffects: sideEffectModules, queryEngine: noOpQueryEngine });
    const handler = (event, context) => handleStreamEvent(callback.handleJsonEvents, event, context);
    // Multiple side-effect handlers can share one source stream. Accumulate all
    // per source ARN; a plain assignment collapses them to one (Promise.all
    // race), silently dropping the rest.
    (handlers[h.sourceUrn] ||= []).push(handler);
  }));

  return handlers;
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  _currentRequestId = context?.awsRequestId || "unknown";
  const handlers = await initPromise;
  const records = event.Records || [];
  const grouped = groupBySource(records);

  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const streamHandlers = handlers[arn];
    if (streamHandlers !== undefined && streamHandlers.length > 0) {
      log.debug("found " + streamHandlers.length + " handler(s) for " + arn, { comp: "SideEffectRuntime" });
      await Promise.all(streamHandlers.map(h =>
        runEffect(undefined, h({ Records: subRecords }, context))
      ));
    } else {
      log.warn("no handler found: " + arn, { comp: "SideEffectRuntime" });
    }
  }));

  return "";
}
