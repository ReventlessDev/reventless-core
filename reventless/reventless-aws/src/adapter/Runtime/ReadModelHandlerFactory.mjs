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
import { patchSpecId, makeTableRef } from "./HandlerFactoryHelpers.mjs";

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
  // Patch Id module alias — `module Id = Id.String` doesn't produce a runtime
  // value in ESM exports.
  const patchedSpec = patchSpecId(specModule);

  // Build a table-like object for DynamoDB runtime operations.
  const table = makeTableRef(queryDbTableName);

  // Create QueryDb operations from the DynamoDB table.
  // The raw save/saveBatch operations expect the JSON item to already contain
  // the "id" hash key. At deploy time, QueryDb_Operations.save injects "id"
  // via Message.encode + Dict.set. Here we replicate that injection.
  const rawSave = QueryDbRuntime.save(table);
  const rawSaveBatch = QueryDbRuntime.saveBatch(table);

  const injectId = (id, json) => {
    if (json && typeof json === "object" && !Array.isArray(json)) {
      return { ...json, id };
    }
    return json;
  };

  const operations = {
    load: QueryDbRuntime.load(table),
    loadStream: QueryDbRuntime.loadStream(table),
    save: (id, state, saveMode, ttl) => rawSave(id, injectId(id, state), saveMode, ttl),
    saveBatch: (items) => rawSaveBatch(items.map(([id, state, ttl]) => [id, injectId(id, state), ttl])),
    count: QueryDbRuntime.count(table),
    delete: QueryDbRuntime.$$delete(table),
    deleteBatch: QueryDbRuntime.deleteBatch(table),
  };

  // The mappingsModule may export a `mappings` array directly (if it's a
  // Mappings wrapper module) or individual named Mapping modules (if it's a
  // raw projections file like CategoriesProjections.res.mjs).
  // ProjectionMapper.Make expects { mappings: array<module(Mapping)> }.
  let effectiveMappings = mappingsModule;
  if (!mappingsModule.mappings) {
    // Collect all exported values that look like Mapping modules
    // (they have sourceName and map fields from Projection.Mapping.Make).
    const mappingValues = Object.values(mappingsModule).filter(
      (v) => v && typeof v === "object" && "sourceName" in v && "map" in v
    );
    if (mappingValues.length > 0) {
      effectiveMappings = { ...mappingsModule, mappings: mappingValues };
    }
  }

  // Apply the ReadModel_Callback.Make functor chain:
  // Make(ReadModelSpec)(Mappings)({ReadModelSpec, operations})
  const callback = ReadModelCallbackMake(patchedSpec)(effectiveMappings)({
    ReadModelSpec: patchedSpec,
    operations: operations,
  });

  // Wrap handleJsonEvents in DynamoDB Stream event parsing.
  // handleStreamEvent extracts NewImage JSONs from stream records
  // and calls handleJsonEvents with a Stream of those JSONs.
  return (event, context) =>
    handleStreamEvent(callback.handleJsonEvents, event, context);
}
