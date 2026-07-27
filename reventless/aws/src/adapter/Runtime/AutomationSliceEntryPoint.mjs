// AutomationSlice / OutboundTranslationSlice Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports each slice's spec +
// body modules, applies the curried callback functor, and routes stream events
// by source URN.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// inherently-untyped seam — the dynamic `import()` of the spec + body modules
// named in HANDLER_CONFIG and the curried functor applications consuming them
// (AutomationSlice_Callback.Make(Spec)(Automation) /
// OutboundTranslationSlice_Callback.Make(Spec)(Translation)). Everything else
// (HANDLER_CONFIG parsing, the phase-1/phase-2 pipelines, the TODO-list
// QueryDb sync, the routed dispatch boundary) lives type-checked in
// AutomationSliceEntryPoint_Ops.res / StreamRoutedEntryPoint_Ops.res.

import { Make as automationSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res.mjs";
import { Make as outboundTranslationSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res.mjs";
import * as StreamOps from "./StreamRoutedEntryPoint_Ops.res.mjs";
import * as Ops from "./AutomationSliceEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function buildAllHandlers() {
  const handlers = {};
  const entries = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "");

  await Promise.all(entries.map(async (entry) => {
    if (!entry.bodyModule) {
      Ops.warnMissingBodyModule(entry);
      return;
    }
    const [specModule, bodyModule] = await Promise.all([
      dynamicImport(entry.specModule),
      dynamicImport(entry.bodyModule),
    ]);
    const registered = entry.callbackType === "outbound"
      ? Ops.makeOutboundRegisteredHandler(
          entry,
          specModule.name,
          specModule.consumedEventSchema,
          outboundTranslationSliceCallbackMake(specModule)(bodyModule)
        )
      : Ops.makeAutomationRegisteredHandler(
          entry,
          specModule.name,
          automationSliceCallbackMake(specModule)(bodyModule)
        );
    StreamOps.addToRegistry(handlers, entry.sourceUrn, registered);
  }));

  return handlers;
}

export const handler = StreamOps.makeRoutedHandler("AutomationSliceRuntime", buildAllHandlers());
