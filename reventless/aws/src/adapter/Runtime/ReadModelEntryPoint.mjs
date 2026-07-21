// ReadModel Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Mappings modules,
// wires ReadModel_Callback.Make, builds handler map keyed by source URN.

import {
  patchSpecId,
  log,
  runEffect,
  setRequestId,
  extractMetaField,
  extractSentTimestamp,
  extractRetryCount,
} from "./HandlerFactoryHelpers.mjs";
import { Make as readModelCallbackMake } from "@reventlessdev/reventless-core/src/components/ReadModel/ReadModel_Callback.res.mjs";
// Typed cold-start core — DynamoDB QueryDb ops, compiler-checked against the
// framework signatures (see the module header and
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md).
import { makeDynamoQueryDbOps } from "./QueryDbEntryPoint_Ops.res.mjs";
import { opsFor as pgQdbOpsFor } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_Postgres_Runtime.res.mjs";
import { withLiveUpdates } from "./StateTopicPublish.mjs";
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

function groupBySource(records) {
  const dict = {};
  records.forEach(record => {
    const arn = record.eventSourceARN;
    const existing = dict[arn] || [];
    dict[arn] = existing.concat([record]);
  });
  return dict;
}

// `pgConnection`, when present, is the resolved PgConnection.connectionConfig the
// runtime builder injected for a Postgres-backed read model: bind the Postgres
// operation set (queryDbTableName is then the read-model spec name, the shared
// `qdb_<name>` discriminator). Absent → the DynamoDB path is byte-identical.
function buildReadModelHandler(specModule, mappingsModule, queryDbTableName, pgConnection, stateTopicName) {
  const patchedSpec = patchSpecId(specModule);
  let operations;
  if (pgConnection) {
    const indexes = (patchedSpec.config && patchedSpec.config.indexes) || [];
    const subIdField = patchedSpec.subIdConfig ? patchedSpec.subIdConfig.subIdField : undefined;
    const pgOps = pgQdbOpsFor(pgConnection, queryDbTableName, indexes, subIdField);
    // B3.3: on a subscription-enabled (Stream) Postgres read model, publish a
    // live-update descriptor after each save/delete (no DynamoDB stream exists).
    // `stateTopicName` (present only for stream RMs) + APPSYNC_ENDPOINT gate it;
    // absent → withLiveUpdates returns pgOps unchanged. Wrap BEFORE mkInjectIdSave
    // so the publish sees the id-injected state (id, subId, updatedAt).
    const livePgOps = withLiveUpdates(pgOps, {
      endpoint: process.env.APPSYNC_ENDPOINT,
      region: process.env.AWS_REGION,
      topicName: stateTopicName,
      subIdField,
    });
    operations = {
      ...livePgOps,
      save: mkInjectIdSave(livePgOps.save),
      saveBatch: mkInjectIdSaveBatch(livePgOps.saveBatch),
    };
  } else {
    // Typed core builds the 7 DynamoDB QueryDb ops; the shell keeps the id-
    // injection wrap on save/saveBatch (business logic, not framework-call drift).
    const base = makeDynamoQueryDbOps(queryDbTableName);
    operations = {
      ...base,
      save: mkInjectIdSave(base.save),
      saveBatch: mkInjectIdSaveBatch(base.saveBatch),
    };
  }

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
    const handler = buildReadModelHandler(specModule, mappingsModule, h.queryDbTableName, h.pgConnection, h.stateTopicName);
    // `comp` / `plugin` are resolved at deploy time and baked into
    // HANDLER_CONFIG (EventCollectorRuntime_Builder_Single) so the shell doesn't
    // re-derive component identity from module paths, and so the string matches
    // the ReScript dispatch boundary's `EventCollector(<Name>)` byte for byte.
    // Kept next to the handler: this Lambda hosts every read model, so the comp
    // is what separates their log lines.
    const registered = { handler, comp: h.comp, plugin: h.plugin };
    // Multiple read models can share one source stream — e.g. every admin read
    // model (Plugins, PluginHistory, PlatformEventGraph, UIFragmentRegistry)
    // projects the Plugin aggregate's EventLog stream. Accumulate ALL handlers
    // per source ARN; a plain `handlers[urn] = handler` collapses them to one
    // (whichever async builder wins the Promise.all race), silently dropping the
    // rest — which leaves their QueryDbs empty.
    (handlers[h.sourceUrn] ||= []).push(registered);
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
      log.debug("found " + streamHandlers.length + " handler(s) for " + arn, { comp: "ReadModelRuntime" });
      const correlationId = extractMetaField(subRecords, "correlationId");
      const causationId = extractMetaField(subRecords, "causationId");
      const timestamp = extractSentTimestamp(subRecords);
      const retryCount = extractRetryCount(subRecords);
      // Run every read model registered for this source stream (independent
      // QueryDbs, so concurrent is safe). Each carries its own comp so the
      // shared Lambda's log lines stay separable per read model.
      await Promise.all(
        streamHandlers.map(({ handler: streamHandler, comp, plugin }) =>
          runEffect(streamHandler({ Records: subRecords }, context), {
            correlationId,
            causationId,
            comp,
            plugin,
            timestamp,
            retryCount,
          })
        )
      );
    } else {
      log.warn("no handler found: " + arn, { comp: "ReadModelRuntime" });
    }
  }));

  return "";
}
