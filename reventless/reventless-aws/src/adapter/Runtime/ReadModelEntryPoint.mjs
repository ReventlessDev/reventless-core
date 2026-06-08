// ReadModel Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Mappings modules,
// wires ReadModel_Callback.Make, builds handler map keyed by source URN.

import * as Effect from "effect/Effect";
import { patchSpecId, makeTableRef } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as readModelCallbackMake } from "@reventlessdev/reventless-core/src/components/ReadModel/ReadModel_Callback.res.mjs";
import { load as qdbLoad, loadStream as qdbLoadStream, save as qdbSave, saveBatch as qdbSaveBatch, count as qdbCount, $$delete as qdbDelete, deleteBatch as qdbDeleteBatch } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// Inject 'id' key into saved state objects
function mkInjectIdSave(rawSave) {
  return (id, state, saveMode, ttl) => {
    const injected = (state && typeof state === "object" && !Array.isArray(state))
      ? { ...state, id }
      : state;
    return rawSave(id, injected, saveMode, ttl);
  };
}

function mkInjectIdSaveBatch(rawSaveBatch) {
  return (items) =>
    rawSaveBatch(items.map(([id, state, ttl]) => {
      const injected = (state && typeof state === "object" && !Array.isArray(state))
        ? { ...state, id }
        : state;
      return [id, injected, ttl];
    }));
}

// Fix mappings module: ensure it has a `mappings` array
function fixMappingsModule(mod) {
  if (mod.mappings) return mod;
  const mappingValues = Object.values(mod).filter(
    (v) => v && typeof v === "object" && "sourceName" in v && "map" in v
  );
  if (mappingValues.length > 0) {
    return { ...mod, mappings: mappingValues };
  }
  return mod;
}

// Set at handler entry; read by runEffect to tag logs with the Lambda request id.
let _currentRequestId = "unknown";

function runEffect(correlationId, effect) {
  return effect
    // Promote correlationId/requestId to top-level JSON log fields — decoded by
    // EffectLogger.install() from Effect log annotations. Harmless no-op if the
    // unified logger isn't installed.
    .pipe(Effect.annotateLogs("correlationId", correlationId || "unknown"))
    .pipe(Effect.annotateLogs("requestId", _currentRequestId))
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

function buildReadModelHandler(specModule, mappingsModule, queryDbTableName) {
  const patchedSpec = patchSpecId(specModule);
  const table = makeTableRef(queryDbTableName);
  const rawSave = qdbSave(table);
  const rawSaveBatch = qdbSaveBatch(table);

  const operations = {
    load: qdbLoad(table),
    loadStream: qdbLoadStream(table),
    save: mkInjectIdSave(rawSave),
    saveBatch: mkInjectIdSaveBatch(rawSaveBatch),
    count: qdbCount(table),
    delete: qdbDelete(table),
    deleteBatch: qdbDeleteBatch(table),
  };

  const effectiveMappings = fixMappingsModule(mappingsModule);
  const callback = readModelCallbackMake(patchedSpec)(effectiveMappings)({
    ReadModelSpec: patchedSpec,
    operations,
  });

  return (event, context) => handleStreamEvent(callback.handleJsonEvents, event, context);
}

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const handlers = {};

  await Promise.all(config.handlers.map(async h => {
    const specModule = await dynamicImport(h.specModule);
    const mappingsModule = await dynamicImport(h.mappingsModule);
    const handler = buildReadModelHandler(specModule, mappingsModule, h.queryDbTableName);
    handlers[h.sourceUrn] = handler;
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
    const streamHandler = handlers[arn];
    if (streamHandler !== undefined) {
      console.log("----- readModelHandler: found handler for " + arn);
      await runEffect(undefined, streamHandler({ Records: subRecords }, context));
    } else {
      console.warn("readModelHandler: no handler found: " + arn);
    }
  }));

  return "";
}
