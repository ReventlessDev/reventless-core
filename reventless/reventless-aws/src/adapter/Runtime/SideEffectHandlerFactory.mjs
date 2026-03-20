/**
 * Factory for reconstructing SideEffectHandler handler chains in bundled Lambda handlers.
 *
 * At deploy time, SideEffectHandler captures sideEffects array and queryEngine
 * via Pulumi Output chains. In bundled Lambdas, SideEffect modules are imported
 * statically and queryEngine is a no-op (side effects rarely query).
 *
 * Handler chain (same as deploy-time):
 *   DynamoDB Stream event
 *   → EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(jsonEventsHandler, event)
 *   → SideEffectHandler_Callback.Make({sideEffects, queryEngine}).handleJsonEvents
 *   → findSideEffect by meta.service → SideEffect.execute(id, meta, event, queryEngine)
 */

import { Make as SideEffectHandlerCallbackMake } from "@reventlessdev/reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";

/**
 * No-op query engine for bundled side effect handlers.
 * Side effects that need queryEngine will get empty results.
 * TODO: reconstruct from env vars if needed.
 */
const noOpQueryEngine = {
  query: async (_queryDbName, _query) => [],
  queryAll: async (_queryDbName) => [],
};

/**
 * Create a SideEffectHandler EventCollector handler.
 *
 * @param {Object} params
 * @param {Array<Object>} params.sideEffectModules - Compiled SideEffect.T modules (must export: Source.name, Source.Id, Source.eventSchema, execute)
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createSideEffectHandler({ sideEffectModules }) {
  // Pack each module into the first-class module format expected by SideEffectHandler_Callback.
  // ReScript first-class modules are plain objects at runtime.
  const sideEffects = sideEffectModules.map((mod) => mod);

  const callback = SideEffectHandlerCallbackMake({
    sideEffects,
    queryEngine: noOpQueryEngine,
  });

  return (event, context) =>
    handleStreamEvent(callback.handleJsonEvents, event, context);
}
