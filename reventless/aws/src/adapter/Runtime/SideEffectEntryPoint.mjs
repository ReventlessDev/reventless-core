// SideEffectHandler Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports SideEffect modules,
// wires SideEffectHandler_Callback.Make, builds handler map keyed by source URN.

import {
  log,
  runEffect,
  setRequestId,
  extractMetaField,
  extractSentTimestamp,
  extractRetryCount,
} from "./HandlerFactoryHelpers.mjs";
import { Make as sideEffectHandlerCallbackMake } from "@reventlessdev/reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

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
    // race), silently dropping the rest. `comp`/`plugin` come from
    // HANDLER_CONFIG — the shell has only module paths to identify a handler by.
    (handlers[h.sourceUrn] ||= []).push({ handler, comp: h.comp, plugin: h.plugin });
  }));

  return handlers;
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  setRequestId(context?.awsRequestId);
  const handlers = await initPromise;
  const records = event.Records || [];
  const grouped = groupBySource(records);

  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const streamHandlers = handlers[arn];
    if (streamHandlers !== undefined && streamHandlers.length > 0) {
      log.debug("found " + streamHandlers.length + " handler(s) for " + arn, { comp: "SideEffectRuntime" });
      const correlationId = extractMetaField(subRecords, "correlationId");
      const causationId = extractMetaField(subRecords, "causationId");
      const timestamp = extractSentTimestamp(subRecords);
      const retryCount = extractRetryCount(subRecords);
      await Promise.all(streamHandlers.map(({ handler: h, comp, plugin }) =>
        runEffect(h({ Records: subRecords }, context), {
          correlationId,
          causationId,
          comp,
          plugin,
          timestamp,
          retryCount,
        })
      ));
    } else {
      log.warn("no handler found: " + arn, { comp: "SideEffectRuntime" });
    }
  }));

  return "";
}
