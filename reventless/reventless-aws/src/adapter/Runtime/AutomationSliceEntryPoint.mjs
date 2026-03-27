// AutomationSlice Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec modules,
// supports both AutomationSlice and OutboundTranslationSlice callbacks.
// Decodes events, runs phase1/phase2, then syncs to QueryDb.

import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import * as Chunk from "effect/Chunk";
import { parseJsonOrThrow } from "sury/src/S.res.mjs";
import { makeTableRef, makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { save as qdbSave } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { Make as automationSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";
import { Make as outboundTranslationSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res.mjs";

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

function buildHandler(specModule, callbackMake, queryDbTableName, dcbQueueUrl) {
  const callback = callbackMake(specModule);
  const publishJsons = sqsPublishJsons(makeQueueRef(dcbQueueUrl), "SQS_FIFO");
  const table = makeTableRef(queryDbTableName);
  const rawSave = qdbSave(table);

  const syncToQueryDb = async () => {
    const items = Object.entries(callback.todoItems.contents);
    await Promise.all(items.map(async entry => await rawSave(entry[0], entry[1], "Overwrite", undefined)));
  };

  const eventSchema = specModule.consumedEventSchema;

  const jsonEventsHandler = stream => Effect.flatMap(
    Stream.runCollect(
      Stream.flatMap(
        Stream.mapEffect(stream, json => Effect.sync(() => {
          try {
            const eventJson = json.event != null ? json.event : json;
            return [parseJsonOrThrow(eventJson, eventSchema)];
          } catch (exn) {
            console.log("AutomationSlice: Failed to decode event:", exn);
            return [];
          }
        })),
        events => Stream.fromIterable(events)
      )
    ),
    chunk => Effect.promise(async () => {
      const eventsArr = Chunk.toReadonlyArray(chunk);
      callback.phase1(eventsArr);
      await callback.phase2(publishJsons);
      return await syncToQueryDb();
    })
  );

  return (event, context) => handleStreamEvent(jsonEventsHandler, event, context);
}

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const handlers = {};
  await Promise.all(config.handlers.map(async h => {
    const specModule = await dynamicImport(h.specModule);
    const callbackMake = h.callbackType === "outbound"
      ? prim => outboundTranslationSliceCallbackMake(prim)
      : prim => automationSliceCallbackMake(prim);
    handlers[h.sourceUrn] = buildHandler(specModule, callbackMake, h.queryDbTableName, h.dcbQueueUrl);
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
      console.log("----- automationSliceHandler: found handler for " + arn);
      await runEffect(undefined, streamHandler({ Records: subRecords }, context));
    } else {
      console.warn("automationSliceHandler: no handler found: " + arn);
    }
  }));
  return "";
}
