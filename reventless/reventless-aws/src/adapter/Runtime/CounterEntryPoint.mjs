// Counter Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Target Spec and Mappings,
// wires Counter_Callback.Make + EventMapper_Callback.MakeCounterHandler.
// Routes DynamoDB Stream events from references and counts tables.

import { schema as surySchema, string as suryString, $$int as suryInt, parseJsonOrThrow } from "sury/src/S.res.mjs";
import { patchSpecId, makeTableRef, makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { parseDynamoDbStreamRecordState } from "@reventlessdev/reventless-aws/src/util/Util_DynamoDbStream_Runtime.res.mjs";
import { Make as counterCallbackMake } from "@reventlessdev/reventless-core/src/components/Counter/Counter_Callback.res.mjs";
import { MakeCounterHandler } from "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs";
import { count as qdbCount } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// Build the referencesView schema: {id: string, inc: int}
const referencesViewSchema = surySchema(s => ({
  id: s.m(suryString),
  inc: s.m(suryInt),
}));

async function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);

  const targetSpecModule = await dynamicImport(config.targetSpecModule);
  const mappingsModule = await dynamicImport(config.mappingsModule);

  const patchedTarget = patchSpecId(targetSpecModule);
  const countsTable = makeTableRef(config.countsTableName);
  const countsDbCount = qdbCount(countsTable);

  const pubJsons = sqsPublishJsons(makeQueueRef(config.publishQueueUrl), "SQS_FIFO");
  const queryEngine = { query: async () => [], queryAll: async () => [] };

  const counterHandler = MakeCounterHandler(patchedTarget)(mappingsModule)({ publishJsons: pubJsons, queryEngine });
  const callback = counterCallbackMake({
    name: "BundledCounter",
    countsDbCount,
    jsonEventsHandler: counterHandler.handleCounterEvents,
  });

  return [config.referencesStreamArn, config.countsStreamArn, callback];
}

const initPromise = buildHandler();

export async function handler(event, _context) {
  const [referencesStreamArn, countsStreamArn, callback] = await initPromise;
  const records = event.Records || [];

  const dynamoDbRecords = records.filter(r =>
    r.eventSource === "aws:dynamodb" &&
    (r.eventSourceARN === referencesStreamArn || r.eventSourceARN === countsStreamArn)
  );

  const referenceRecords = dynamoDbRecords.filter(r => r.eventSourceARN === referencesStreamArn);
  const countRecords = dynamoDbRecords.filter(r => r.eventSourceARN === countsStreamArn);

  const references = referenceRecords.flatMap(record => {
    const state = parseDynamoDbStreamRecordState(record);
    switch (state.TAG) {
      case 0: { // NewImage(id, newImage)
        const id = state._0;
        let inc;
        try {
          inc = parseJsonOrThrow(state._1, referencesViewSchema).inc;
        } catch (_) {
          inc = 1;
        }
        return [[id, inc]];
      }
      case 2: // NewAndOldImage — duplicate
        console.log("CounterEntryPoint (references): ignoring duplicate id: " + state._0);
        return [];
      default:
        return [];
    }
  });

  const counts = countRecords.flatMap(record => {
    const state = parseDynamoDbStreamRecordState(record);
    if (state.TAG === 0 || state.TAG === 2) {
      return [state._1];
    }
    return [];
  });

  await callback.counterHandler(references, counts);
  return "";
}
