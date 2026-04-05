// StateViewSlice Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec modules,
// builds projection handler that decodes events and runs Projection.handleAction.
// Routes DynamoDB Stream events by source URN.

import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { parseJsonOrThrow } from "sury/src/S.res.mjs";
import { makeTableRef } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { handleAction } from "@reventlessdev/reventless-core/src/Projection.res.mjs";
import { load, loadStream, save, saveBatch, count, $$delete, deleteBatch } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
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

function buildJsonEventsHandler(specModule, queryDbTableName) {
  const table = makeTableRef(queryDbTableName);
  const queryDbOps = {
    load: load(table),
    loadStream: loadStream(table),
    save: save(table),
    saveBatch: saveBatch(table),
    count: count(table),
    delete: $$delete(table),
    deleteBatch: deleteBatch(table),
  };
  const eventSchema = specModule.consumedEventSchema;
  const project = specModule.project;

  return stream => Stream.runForEach(
    Stream.flatMap(
      Stream.mapEffect(stream, json => Effect.sync(() => {
        try {
          const eventJson = json.event != null ? json.event : json;
          return project(parseJsonOrThrow(eventJson, eventSchema));
        } catch (exn) {
          console.log("StateViewSlice: Failed to decode event:", exn);
          return [];
        }
      })),
      actions => Stream.fromIterable(actions)
    ),
    action => Effect.map(
      Effect.promise(() => handleAction(action, queryDbOps, undefined)),
      _ => {}
    )
  );
}

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const handlers = {};
  await Promise.all(config.handlers.map(async h => {
    const specModule = await dynamicImport(h.specModule);
    const jsonEventsHandler = buildJsonEventsHandler(specModule, h.queryDbTableName);
    const streamHandler = (event, context) => handleStreamEvent(jsonEventsHandler, event, context);
    const existing = handlers[h.sourceUrn] || [];
    existing.push(streamHandler);
    handlers[h.sourceUrn] = existing;
  }));
  return handlers;
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  const handlers = await initPromise;
  const records = event.Records || [];
  const grouped = groupBySource(records);

  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const streamHandlers = handlers[arn];
    if (streamHandlers !== undefined && streamHandlers.length > 0) {
      console.log("----- stateViewSliceHandler: found " + streamHandlers.length + " handler(s) for " + arn);
      await Promise.all(streamHandlers.map(h =>
        runEffect(undefined, h({ Records: subRecords }, context))
      ));
    } else {
      console.warn("stateViewSliceHandler: no handler found: " + arn);
    }
  }));
  return "";
}
