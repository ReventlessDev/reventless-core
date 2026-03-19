/**
 * Factory for reconstructing ReadModel handler chains in bundled Lambda handlers.
 *
 * At deploy time, ReadModel handlers capture QueryDb operations and projection
 * mapping closures via Pulumi Output chains. In bundled Lambdas, these values
 * come from environment variables and static module imports instead.
 *
 * Handler chain (same as deploy-time):
 *   DynamoDB Stream event
 *   → EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(jsonEventsHandler, event)
 *   → ReadModel_Callback.Make(Spec)(Mappings)({operations}).handleJsonEvents
 *   → ProjectionMapper.Make(Spec)(Mappings).map → Projection.handleAction
 *   → QueryDbStorage_DynamoDb_Runtime.{save, saveBatch, delete}
 */

import { Make as ReadModelCallbackMake } from "@reventlessdev/reventless-core/src/components/ReadModel/ReadModel_Callback.res.mjs";
import * as QueryDbRuntime from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";

/**
 * Create a ReadModel EventCollector handler for a single read model.
 *
 * @param {Object} specModule - Compiled ReadModel Spec module (must export: name, Id, stateSchema, subIdConfig)
 * @param {Object} mappingsModule - Compiled Mappings module (must export: mappings array)
 * @param {string} queryDbTableName - DynamoDB table name for the QueryDb
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createReadModelHandler({
  specModule,
  mappingsModule,
  queryDbTableName,
}) {
  // Patch Id module alias — same issue as aggregates:
  // `module Id = Id.String` doesn't produce a runtime value in ESM exports.
  const patchedSpec = { ...specModule, Id: specModule.Id || IdString };

  // Build a table-like object for DynamoDB runtime operations.
  // QueryDbStorage_DynamoDb_Runtime functions use table.name, table.hashKey, table.rangeKey.
  const table = { name: queryDbTableName, hashKey: "id" };

  // Create QueryDb operations from the DynamoDB table.
  const operations = {
    load: QueryDbRuntime.load(table),
    loadStream: QueryDbRuntime.loadStream(table),
    save: QueryDbRuntime.save(table),
    saveBatch: QueryDbRuntime.saveBatch(table),
    count: QueryDbRuntime.count(table),
    delete: QueryDbRuntime.$$delete(table),
    deleteBatch: QueryDbRuntime.deleteBatch(table),
  };

  // Apply the ReadModel_Callback.Make functor chain:
  // Make(ReadModelSpec)(Mappings)({ReadModelSpec, operations})
  const callback = ReadModelCallbackMake(patchedSpec)(mappingsModule)({
    ReadModelSpec: patchedSpec,
    operations: operations,
  });

  // Wrap handleJsonEvents in DynamoDB Stream event parsing.
  // handleStreamEvent extracts NewImage JSONs from stream records
  // and calls handleJsonEvents with a Stream of those JSONs.
  return (event, context) =>
    handleStreamEvent(callback.handleJsonEvents, event, context);
}
