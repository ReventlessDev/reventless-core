// StateViewSlice Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Projection
// modules, builds a projection handler per slice, and routes stream events by
// source URN.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// inherently-untyped seam — the dynamic `import()` of spec/projection modules
// named in HANDLER_CONFIG and the reads of their exports. Everything else
// (HANDLER_CONFIG parsing incl. the compact-v2 expansion, the QueryDb operation
// assembly incl. the Postgres / live-update branch, the projection stream
// pipeline, the routed dispatch boundary) lives type-checked in
// StateViewSliceEntryPoint_Ops.res / ProjectionEntryPoint_Ops.res /
// StreamRoutedEntryPoint_Ops.res.

import * as StreamOps from "./StreamRoutedEntryPoint_Ops.res.mjs";
import * as Ops from "./StateViewSliceEntryPoint_Ops.res.mjs";
import { runtimeExtensionsReady } from "./HandlerFactoryHelpers.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function buildAllHandlers() {
  // Runtime extension seam: any registered out-of-tree extension gets its
  // onColdStart before a single handler is built, which is what makes the
  // framework's interception/publish hooks reachable here. No-op unless the
  // deployment registered one.
  await runtimeExtensionsReady;
  const handlers = {};
  const entries = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "");

  await Promise.all(entries.map(async (entry) => {
    const [specModule, projectionModule] = await Promise.all([
      dynamicImport(entry.specModule),
      dynamicImport(entry.projectionModule),
    ]);
    StreamOps.addToRegistry(
      handlers,
      entry.sourceUrn,
      Ops.makeRegisteredHandler(entry, {
        name: specModule.name,
        consumedEventSchema: specModule.consumedEventSchema,
        project: projectionModule.project,
        config: specModule.config,
        subIdConfig: specModule.subIdConfig,
      })
    );
  }));

  return handlers;
}

export const handler = StreamOps.makeRoutedHandler("StateViewSliceRuntime", buildAllHandlers());
