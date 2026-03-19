/**
 * Factory for reconstructing Counter handler chains in bundled Lambda handlers.
 *
 * At deploy time, the Counter handler captures countsDbCount (QueryDb operation)
 * and jsonEventsHandler (EventMapper's CounterHandler.handleCounterEvents) via
 * Pulumi Output chains. In bundled Lambdas, these are reconstructed from static
 * module imports and environment variables.
 *
 * Handler chain (same as deploy-time):
 *   DynamoDB Streams event (references + counts tables)
 *   → handleStreamEvent: partition by stream ARN
 *   → counterHandler(~references, ~counts):
 *     → Group references by counterId
 *     → For each: countsDbCount(counterId, "count", -dec)
 *     → Filter counts where count==0 → emit CountFinished via jsonEventsHandler
 *     → jsonEventsHandler = EventMapper_Callback.MakeCounterHandler.handleCounterEvents
 *       → commonEventsHandler → publishJsons
 */

import { Make as CounterCallbackMake } from "@reventlessdev/reventless-core/src/components/Counter/Counter_Callback.res.mjs";
import { MakeCounterHandler } from "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs";
import * as QueryDbRuntime from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
import { publishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { parseDynamoDbStreamRecordState } from "@reventlessdev/reventless-aws/src/util/Util_DynamoDbStream_Runtime.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import * as S from "sury/src/S.res.mjs";

/**
 * Create a Counter handler for DynamoDB stream events.
 *
 * @param {Object} params
 * @param {Object} params.targetSpecModule - Target aggregate spec module (name, Id, commandSchema)
 * @param {Object} params.mappingsModule - EventMapper Mappings module (mappings array, counter)
 * @param {string} params.countsTableName - DynamoDB table name for the counts QueryDb
 * @param {string} params.publishQueueUrl - SQS queue URL for publishing commands to target aggregate
 * @param {string} params.referencesStreamArn - DynamoDB stream ARN for references table
 * @param {string} params.countsStreamArn - DynamoDB stream ARN for counts table
 * @returns {Function} Handler: (DynamoDBStreamEvent, context) => promise<unit>
 */
export function createCounterHandler({
  targetSpecModule,
  mappingsModule,
  countsTableName,
  publishQueueUrl,
  referencesStreamArn,
  countsStreamArn,
}) {
  // Patch Id module alias
  const patchedTarget = {
    ...targetSpecModule,
    Id: targetSpecModule.Id || IdString,
  };

  // Reconstruct countsDbCount from table name
  const countsTable = { name: countsTableName, hashKey: "id" };
  const countsDbCount = QueryDbRuntime.count(countsTable);

  // Reconstruct publishJsons from SQS queue URL
  const pubJsons = publishJsons(publishQueueUrl, "SQS_FIFO");

  // No-op query engine for event mappings
  const noOpQueryEngine = {
    query: async () => [],
    queryAll: async () => [],
  };

  // Create the CounterHandler via EventMapper_Callback.MakeCounterHandler
  const counterHandler = MakeCounterHandler(patchedTarget)(mappingsModule)({
    publishJsons: pubJsons,
    queryEngine: noOpQueryEngine,
  });

  // Create the Counter_Callback via Counter_Callback.Make
  const callback = CounterCallbackMake({
    name: "BundledCounter",
    countsDbCount,
    jsonEventsHandler: counterHandler.handleCounterEvents,
  });

  // Schema for parsing reference records (matches @schema type referencesView = {id: string, inc: int})
  const referencesViewSchema = S.schema((s) => ({
    id: s.m(S.string),
    inc: s.m(S.int),
  }));

  // Inline reimplementation of handleStreamEvent
  // (avoids importing CounterHandler_DynamoDbStream_Runtime which captures Pulumi Outputs)
  return async (event, _context) => {
    const records = event.Records || [];

    const dynamoDbRecords = records.filter(
      (r) =>
        r.eventSource === "aws:dynamodb" &&
        (r.eventSourceARN === referencesStreamArn ||
          r.eventSourceARN === countsStreamArn)
    );

    const referenceRecords = dynamoDbRecords.filter(
      (r) => r.eventSourceARN === referencesStreamArn
    );
    const countRecords = dynamoDbRecords.filter(
      (r) => r.eventSourceARN === countsStreamArn
    );

    // Variant TAG layout: NewImage=0, OldImage=1, NewAndOldImage=2, Invalid=3
    const references = referenceRecords
      .map((record) => {
        const state = parseDynamoDbStreamRecordState(record);
        if (state.TAG === 0) {
          // NewImage(id, newImage)
          const id = state._0;
          const newImage = state._1;
          let inc = 1;
          try {
            const parsed = S.parseJsonOrThrow(newImage, referencesViewSchema);
            inc = parsed.inc;
          } catch {
            // default to 1
          }
          return [id, inc];
        }
        if (state.TAG === 2) {
          // NewAndOldImage(id, _, _) → duplicate, skip
          console.log(
            `BundledCounterHandlerFactory (references): ignoring duplicate id: ${state._0}`
          );
        }
        return null;
      })
      .filter((x) => x !== null);

    const counts = countRecords
      .map((record) => {
        const state = parseDynamoDbStreamRecordState(record);
        // NewImage(_, newImage) or NewAndOldImage(_, newImage, _)
        if (state.TAG === 0) return state._1;
        if (state.TAG === 2) return state._1;
        return null;
      })
      .filter((x) => x !== null);

    await callback.counterHandler(references, counts);
  };
}
