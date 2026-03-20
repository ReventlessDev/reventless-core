/**
 * Factory for reconstructing AutomationSlice handler chains in bundled Lambda handlers.
 *
 * Handler chain (same as deploy-time):
 *   DynamoDB Stream event
 *   → EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(jsonEventsHandler, event)
 *   → jsonEventsHandler: decode event → Callback.phase1 → Callback.phase2(publishJsons) → syncToQueryDb
 *   → AutomationSlice_Callback.Make(Spec).{phase1, phase2}
 *   → publishJsons → CommandTopicChannel_SQS_Runtime.publishJsons(queue, "SQS_FIFO")
 */

import { Effect, Stream } from "effect";
import * as S from "sury/src/S.res.mjs";
import { Make as AutomationSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res.mjs";
import * as QueryDbRuntime from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
import { publishJsons as makePublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";
import { makeTableRef, makeQueueRef } from "./HandlerFactoryHelpers.mjs";

/**
 * Create an AutomationSlice EventCollector handler.
 *
 * @param {Object} specModule - Compiled AutomationSlice/OutboundTranslationSlice Spec module
 * @param {Function} callbackMake - Callback Make functor (AutomationSlice_Callback.Make or OutboundTranslationSlice_Callback.Make)
 * @param {string} queryDbTableName - DynamoDB table name for the TODO QueryDb
 * @param {string} dcbQueueUrl - SQS FIFO queue URL for publishing commands back to DCB CommandTopic
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createAutomationSliceHandler({
  specModule,
  callbackMake,
  queryDbTableName,
  dcbQueueUrl,
}) {
  // Create the callback (stateful — maintains todoItems across invocations)
  const callback = (callbackMake || AutomationSliceCallbackMake)(specModule);

  // Create publishJsons for the DCB CommandTopic queue
  const publishJsons = makePublishJsons(makeQueueRef(dcbQueueUrl), "SQS_FIFO");

  // Create QueryDb operations for TODO list persistence
  const table = makeTableRef(queryDbTableName);
  const queryDbSave = QueryDbRuntime.save(table);

  const syncToQueryDb = async () => {
    const items = Object.entries(callback.todoItems.contents);
    for (const [id, row] of items) {
      await queryDbSave(id, row, "Overwrite", undefined);
    }
  };

  const eventSchema = specModule.DcbEventLogSpec.eventSchema;

  // Replicate the inline jsonEventsHandler from AutomationSlice_Builder.construct
  // Chain: stream → mapEffect(decode) → flatMap(fromIterable) → runCollect → flatMap(phase1+phase2+sync)
  const jsonEventsHandler = (stream) =>
    Effect.flatMap(
      Stream.runCollect(
        Stream.flatMap(
          Stream.mapEffect(stream, (json) =>
            Effect.sync(() => {
              try {
                return [S.parseJsonOrThrow(json, eventSchema)];
              } catch (exn) {
                console.log("AutomationSlice: Failed to decode event:", exn);
                return [];
              }
            })
          ),
          (events) => Stream.fromIterable(events)
        )
      ),
      (eventsArr) =>
        Effect.promise(async () => {
          callback.phase1(eventsArr);
          await callback.phase2(publishJsons);
          await syncToQueryDb();
        })
    );

  return (event, context) =>
    handleStreamEvent(jsonEventsHandler, event, context);
}
