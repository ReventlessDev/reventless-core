// Counter Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Target Spec and Mappings,
// wires Counter_Callback.Make + EventMapper_Callback.MakeCounterHandler.
// Routes DynamoDB Stream events from references and counts tables.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// seams that are inherently untyped — the dynamic `import()` of the
// target-spec/mappings modules named in HANDLER_CONFIG, the `patchSpecId`
// fix-up, and the MakeCounterHandler functor application consuming them.
// HANDLER_CONFIG parsing, the Counter_Callback.Make application, and the
// references/counts stream routing live type-checked in
// CounterEntryPoint_Ops.res.

import { patchSpecId } from "./HandlerFactoryHelpers.mjs";
import { MakeCounterHandler } from "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs";
import * as Ops from "./CounterEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function build() {
  const config = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "{}");

  const targetSpecModule = await dynamicImport(config.targetSpecModule);
  const mappingsModule = await dynamicImport(config.mappingsModule);

  const patchedTarget = patchSpecId(targetSpecModule);
  const counterHandler = MakeCounterHandler(patchedTarget)(mappingsModule)(Ops.makeCounterOps(config));

  return Ops.makeHandler(config, counterHandler.handleCounterEvents);
}

const initPromise = build();

export async function handler(event, context) {
  return (await initPromise)(event, context);
}
