// EventMapper Lambda entry point (Micro mode).
// At cold start: reads HANDLER_CONFIG, dynamically imports Target Spec and Mappings,
// wires EventMapper_Callback.MakeCounterHandler + MakeEventCollectorHandler.

import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
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

  return {
    streamHandler: (event, context) =>
      handleStreamEvent(eventCollectorHandler.handleJsonEvents, event, context),
    // The mapper is named after the target it maps into.
    comp: `EventMapper(${patchedTarget.name})`,
  };
}

const initPromise = buildHandler();

export async function handler(event, context) {
  setRequestId(context?.awsRequestId);
  const { streamHandler, comp } = await initPromise;
  const records = event.Records || [];
  const grouped = groupBySource(records);

  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    log.debug("processing " + arn, { comp: "EventMapperRuntime" });
    await runEffect(streamHandler({ Records: subRecords }, context), {
      correlationId: extractMetaField(subRecords, "correlationId"),
      causationId: extractMetaField(subRecords, "causationId"),
      comp,
      timestamp: extractSentTimestamp(subRecords),
      retryCount: extractRetryCount(subRecords),
    });
  }));

  return "";
}
