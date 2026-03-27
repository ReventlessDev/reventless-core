// SideEffectHandler Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports SideEffect modules,
// wires SideEffectHandler_Callback.Make, builds handler map keyed by source URN.

import * as Effect from "effect/Effect";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as sideEffectHandlerCallbackMake } from "@reventlessdev/reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

function runEffect(correlationId, effect) {
  return effect
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
    handlers[h.sourceUrn] = handler;
  }));

  return handlers;
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  const handlers = await initPromise;
  const records = event.Records || [];
  const grouped = groupBySource(records);

  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const streamHandler = handlers[arn];
    if (streamHandler !== undefined) {
      console.log("----- sideEffectHandler: found handler for " + arn);
      await runEffect(undefined, streamHandler({ Records: subRecords }, context));
    } else {
      console.warn("sideEffectHandler: no handler found: " + arn);
    }
  }));

  return "";
}
