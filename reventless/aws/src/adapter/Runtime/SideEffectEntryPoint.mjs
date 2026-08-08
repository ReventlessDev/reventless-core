// SideEffectHandler Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports SideEffect modules,
// wires SideEffectHandler_Callback.Make, builds handler map keyed by source URN.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// seams that are inherently untyped — the dynamic `import()` of the side-effect
// modules named in HANDLER_CONFIG and the SideEffectHandler_Callback.Make
// functor application consuming them. HANDLER_CONFIG parsing and handler
// registration live type-checked in SideEffectEntryPoint_Ops.res; the routed
// dispatch boundary in StreamRoutedEntryPoint_Ops.res.

import { Make as sideEffectHandlerCallbackMake } from "@reventlessdev/reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res.mjs";
import * as StreamOps from "./StreamRoutedEntryPoint_Ops.res.mjs";
import * as Ops from "./SideEffectEntryPoint_Ops.res.mjs";
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
    const sideEffectModules = await Promise.all(
      entry.sideEffectModules.map(async modPath => await dynamicImport(modPath))
    );
    const callback = sideEffectHandlerCallbackMake({
      sideEffects: sideEffectModules,
      queryEngine: Ops.noopQueryEngine,
    });
    StreamOps.addToRegistry(
      handlers,
      entry.sourceUrn,
      Ops.makeRegisteredHandler(entry, callback.handleJsonEvents)
    );
  }));

  return handlers;
}

export const handler = StreamOps.makeRoutedHandler("SideEffectRuntime", buildAllHandlers());
