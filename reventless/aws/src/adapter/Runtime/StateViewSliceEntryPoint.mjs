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
// StateViewSliceEntryPoint_Ops.res and ProjectionEntryPoint_Ops.res.

import * as ProjectionOps from "./ProjectionEntryPoint_Ops.res.mjs";
import * as Ops from "./StateViewSliceEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function buildAllHandlers() {
  const handlers = {};
  const entries = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "");

  await Promise.all(entries.map(async (entry) => {
    const [specModule, projectionModule] = await Promise.all([
      dynamicImport(entry.specModule),
      dynamicImport(entry.projectionModule),
    ]);
    ProjectionOps.addToRegistry(
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

export const handler = ProjectionOps.makeRoutedHandler("StateViewSliceRuntime", buildAllHandlers());
