// EventMapper Lambda entry point (Micro mode).
// At cold start: reads HANDLER_CONFIG, dynamically imports Target Spec and Mappings,
// wires EventMapper_Callback.MakeCounterHandler + MakeEventCollectorHandler.

import * as Effect from "effect/Effect";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import { patchSpecId, makeQueueRef, log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { MakeCounterHandler, MakeEventCollectorHandler } from "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// Patch Source.Id on each mapping
function patchMappingsSourceIds(mappingsModule) {
  return {
    ...mappingsModule,
    mappings: (mappingsModule.mappings || []).map((mapping) => ({
      ...mapping,
      Source: {
        ...mapping.Source,
        Id: mapping.Source.Id || IdString,
      },
    })),
  };
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

function groupBySource(records) {
  const dict = {};
  records.forEach(record => {
    const arn = record.eventSourceARN;
    const existing = dict[arn] || [];
    dict[arn] = existing.concat([record]);
  });
  return dict;
}

async function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);

  const targetSpecModule = await dynamicImport(config.targetSpecModule);
  const mappingsModule = await dynamicImport(config.mappingsModule);

  const patchedTarget = patchSpecId(targetSpecModule);
  const patchedMappings = patchMappingsSourceIds(mappingsModule);

  const publishJsons = sqsPublishJsons(makeQueueRef(config.queueUrl), "SQS_FIFO");
  const queryEngine = {
    query: async () => { log.error("queryEngine not available in bundled mode", { comp: "EventMapperEntryPoint" }); return []; },
    get: async () => { log.error("queryEngine not available in bundled mode", { comp: "EventMapperEntryPoint" }); return undefined; },
  };

  const counterHandler = MakeCounterHandler(patchedTarget)(patchedMappings)({ publishJsons, queryEngine });
  const noopAsync = async (_) => {};
  const eventCollectorHandler = MakeEventCollectorHandler({
    publishJsons,
    count: noopAsync,
    addToCounterTarget: noopAsync,
    commonEventsHandler: counterHandler.commonEventsHandler,
  });

  return (event, context) => handleStreamEvent(eventCollectorHandler.handleJsonEvents, event, context);
}

const initPromise = buildHandler();

export async function handler(event, context) {
  _currentRequestId = context?.awsRequestId || "unknown";
  const streamHandler = await initPromise;
  const records = event.Records || [];
  const grouped = groupBySource(records);

  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    log.debug("processing " + arn, { comp: "EventMapperRuntime" });
    await runEffect(undefined, streamHandler({ Records: subRecords }, context));
  }));

  return "";
}
