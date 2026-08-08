// ReadModel Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Mappings modules,
// wires ReadModel_Callback.Make, builds handler map keyed by source URN.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// seams that are inherently untyped — the dynamic `import()` of spec/mappings
// modules named in HANDLER_CONFIG, the shape fix-ups on those runtime-loaded
// modules (patchSpecId / fixMappingsModule), and the ReadModel_Callback.Make
// functor application consuming them. Everything else (HANDLER_CONFIG parsing,
// the QueryDb operation assembly incl. the id-injection wrap and the
// Postgres / live-update branch, handler registration, the routed dispatch
// boundary) lives type-checked in ReadModelEntryPoint_Ops.res /
// ProjectionEntryPoint_Ops.res / StreamRoutedEntryPoint_Ops.res.

import { patchSpecId, runtimeExtensionsReady } from "./HandlerFactoryHelpers.mjs";
import { Make as readModelCallbackMake } from "@reventlessdev/reventless-core/src/components/ReadModel/ReadModel_Callback.res.mjs";
import * as StreamOps from "./StreamRoutedEntryPoint_Ops.res.mjs";
import * as Ops from "./ReadModelEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

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

async function buildAllHandlers() {
  // Runtime extension seam: any registered out-of-tree extension gets its
  // onColdStart before a single handler is built, which is what makes the
  // framework's interception/publish hooks reachable here. No-op unless the
  // deployment registered one.
  await runtimeExtensionsReady;
  const handlers = {};
  const entries = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "");

  await Promise.all(entries.map(async (entry) => {
    const specModule = patchSpecId(await dynamicImport(entry.specModule));
    const mappingsModule = fixMappingsModule(await dynamicImport(entry.mappingsModule));
    const operations = Ops.buildOperations(entry, {
      config: specModule.config,
      subIdConfig: specModule.subIdConfig,
    });
    const callback = readModelCallbackMake(specModule)(mappingsModule)({
      ReadModelSpec: specModule,
      operations,
    });
    StreamOps.addToRegistry(
      handlers,
      entry.sourceUrn,
      Ops.makeRegisteredHandler(entry, callback.handleJsonEvents)
    );
  }));

  return handlers;
}

export const handler = StreamOps.makeRoutedHandler("ReadModelRuntime", buildAllHandlers());
