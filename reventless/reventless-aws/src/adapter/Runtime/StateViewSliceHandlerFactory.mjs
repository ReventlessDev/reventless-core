/**
 * Factory for reconstructing StateViewSlice handler chains in bundled Lambda handlers.
 *
 * Handler chain (same as deploy-time):
 *   DynamoDB Stream event
 *   → EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(jsonEventsHandler, event)
 *   → jsonEventsHandler: decode event with DcbEventLogSpec.eventSchema → Spec.project → Projection.handleAction
 *   → QueryDbStorage_DynamoDb_Runtime.{save, saveBatch, delete}
 */

import { Effect, Stream } from "effect";
import * as S from "sury/src/S.res.mjs";
import * as Projection from "@reventlessdev/reventless-core/src/Projection.res.mjs";
import * as QueryDbRuntime from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";
import { makeTableRef } from "./HandlerFactoryHelpers.mjs";

/**
 * Create a StateViewSlice EventCollector handler.
 *
 * @param {Object} specModule - Compiled StateViewSlice Spec module (must export: name, project, DcbEventLogSpec.eventSchema, stateSchema)
 * @param {string} queryDbTableName - DynamoDB table name for the QueryDb
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createStateViewSliceHandler({
  specModule,
  queryDbTableName,
}) {
  const table = makeTableRef(queryDbTableName);

  const queryDbOps = {
    load: QueryDbRuntime.load(table),
    loadStream: QueryDbRuntime.loadStream(table),
    save: QueryDbRuntime.save(table),
    saveBatch: QueryDbRuntime.saveBatch(table),
    count: QueryDbRuntime.count(table),
    delete: QueryDbRuntime.$$delete(table),
    deleteBatch: QueryDbRuntime.deleteBatch(table),
  };

  const eventSchema = specModule.DcbEventLogSpec.eventSchema;

  // Replicate the inline jsonEventsHandler from StateViewSlice_Builder.construct
  const jsonEventsHandler = (stream) =>
    Stream.runForEach(
      Stream.flatMap(
        Stream.mapEffect(stream, (json) =>
          Effect.sync(() => {
            try {
              return specModule.project(undefined, S.parseJsonOrThrow(json, eventSchema));
            } catch (exn) {
              console.log("StateViewSlice: Failed to decode event:", exn);
              return [];
            }
          })
        ),
        (actions) => Stream.fromIterable(actions)
      ),
      (action) =>
        Effect.map(
          Effect.promise(() => Projection.handleAction(action, queryDbOps, undefined)),
          () => {}
        )
    );

  return (event, context) =>
    handleStreamEvent(jsonEventsHandler, event, context);
}
