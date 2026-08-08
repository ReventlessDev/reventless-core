// ExtensionPoint Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec/Mappings,
// wires ExtensionPoint_Callback.Make + CommandTopic_Callback.Make,
// routes SQS events through handleQueueEvent.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// seams that are inherently untyped — the dynamic `import()` of the
// spec/mappings modules named in HANDLER_CONFIG, the `patchSpecId` fix-up, and
// the two functor applications consuming them. The callback config,
// HANDLER_CONFIG parsing, and the SQS dispatch boundary live type-checked in
// ExtensionPointEntryPoint_Ops.res.

import { patchSpecId, runtimeExtensionsReady } from "./HandlerFactoryHelpers.mjs";
import { Make as extensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import * as Ops from "./ExtensionPointEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function build() {
  // Runtime extension seam: any registered out-of-tree extension gets its
  // onColdStart before a single handler is built, which is what makes the
  // framework's interception/publish hooks reachable here. No-op unless the
  // deployment registered one.
  await runtimeExtensionsReady;
  const config = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "{}");

  const specModule = await dynamicImport(config.specModule);
  const mappingsModule = await dynamicImport(config.mappingsModule);

  const patchedSpec = patchSpecId(specModule);

  const callback = extensionPointCallbackMake(Ops.makeCallbackSpec(config))(patchedSpec)(mappingsModule);
  const commandTopicCallback = commandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: callback.handleIncomingCommands,
  });

  return Ops.makeBuilt(config, patchedSpec.name, commandTopicCallback.handleJsonCommands);
}

export const handler = Ops.makeHandler(build());
