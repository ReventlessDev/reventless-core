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
  const sweeps = [];
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
    // A slice can listen on several streams — its plugin's DCB log and any
    // Aggregate EventTopic it named. Register the one handler under each, since
    // the router dispatches by the record's own eventSourceARN. `sourceUrn` is
    // the pre-multi-source spelling, kept as a fallback so an older handler
    // config still routes.
    const sourceUrns = entry.sourceUrns?.length
      ? entry.sourceUrns
      : entry.sourceUrn
        ? [entry.sourceUrn]
        : [];
    for (const sourceUrn of sourceUrns) {
      StreamOps.addToRegistry(handlers, sourceUrn, registered.registered);
    }
    // Every slice can also be swept without an event — see the scheduled branch
    // below. Collected regardless of how many streams it listens on, so a
    // multi-source slice is swept once rather than once per stream.
    sweeps.push(registered);
  }));

  return { handlers, sweeps };
}

const builtPromise = buildAllHandlers();
const routed = StreamOps.makeRoutedHandler(
  "AutomationSliceRuntime",
  builtPromise.then((b) => b.handlers),
);

// The scheduled sweep arrives as the EventBridge rule's constant Input, which
// has no `records` — so this branch is the one place that must probe an untyped
// Lambda payload, which is what this shell exists for. Everything it dispatches
// to is type-checked in AutomationSliceEntryPoint_Ops.
export const handler = async (event, context) =>
  event?.reventlessSweep
    ? Ops.runSweeps((await builtPromise).sweeps)
    : routed(event, context);
