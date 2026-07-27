// TaskBucket Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports the task callback
// module, and dispatches the resulting task actions (command publishing, CW
// Events schedules).
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// inherently-untyped seam — the dynamic `import()` of the callback module named
// in HANDLER_CONFIG and the read of its `callback` export. Everything else
// (HANDLER_CONFIG parsing, S3-event handling via TaskBucket_S3_Runtime, the
// exhaustive task-action dispatch, per-aggregate command publishing, the
// CloudWatch Events scheduler ops) lives type-checked in
// TaskBucketEntryPoint_Ops.res.

import * as Ops from "./TaskBucketEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function buildHandler() {
  const config = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "");
  const callbackModule = await dynamicImport(config.callbackModule);
  return Ops.makeHandler(callbackModule.callback, config);
}

const initPromise = buildHandler();

export async function handler(event, context) {
  const bucketHandler = await initPromise;
  return await bucketHandler(event, context);
}
