// EventMapper Lambda entry point (Micro mode).
// At cold start: reads HANDLER_CONFIG, dynamically imports Target Spec and Mappings,
// wires EventMapper_Callback.MakeCounterHandler + MakeEventCollectorHandler.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// seams that are inherently untyped — the dynamic `import()` of the
// target-spec/mappings modules named in HANDLER_CONFIG, the shape fix-ups on
// those runtime-loaded modules (patchSpecId / patchMappingsSourceIds), and the
// MakeCounterHandler functor application consuming them. HANDLER_CONFIG
// parsing, the publish/query operations, the MakeEventCollectorHandler
// application, and the per-source dispatch boundary live type-checked in
// EventMapperEntryPoint_Ops.res.

import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import { patchSpecId, runtimeExtensionsReady } from "./HandlerFactoryHelpers.mjs";
import { MakeCounterHandler } from "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs";
import * as Ops from "./EventMapperEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// Patch Source.Id on each mapping
function patchMappingsSourceIds(mappingsModule) {
  return {
    ...mappingsModule,
    mappings: (mappingsModule.mappings || []).map((mapping) => ({
      ...mapping,
      Source: {
        ...mapping.Source,
        Id: mapping.Source.Id || IdString,
      },
    })),
  };
}

async function build() {
  // Runtime extension seam: any registered out-of-tree extension gets its
  // onColdStart before a single handler is built, which is what makes the
  // framework's interception/publish hooks reachable here. No-op unless the
  // deployment registered one.
  await runtimeExtensionsReady;
  const config = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "{}");

  const targetSpecModule = await dynamicImport(config.targetSpecModule);
  const mappingsModule = await dynamicImport(config.mappingsModule);

  const patchedTarget = patchSpecId(targetSpecModule);
  const patchedMappings = patchMappingsSourceIds(mappingsModule);

  const counterOps = Ops.makeCounterOps(config);
  const counterHandler = MakeCounterHandler(patchedTarget)(patchedMappings)(counterOps);

  // The mapper is named after the target it maps into.
  return [
    Ops.makeStreamHandler(counterOps, counterHandler.commonEventsHandler),
    `EventMapper(${patchedTarget.name})`,
  ];
}

export const handler = Ops.makeHandler(build());
