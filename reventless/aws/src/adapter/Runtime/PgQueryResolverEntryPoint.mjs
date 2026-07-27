// Shared PgQueryResolver Lambda entry point (B3.2b).
//
// One in-VPC Lambda serves every Postgres-backed read model's GraphQL Query
// fields (they have no per-table AppSync data source). At cold start it reads
// QUERY_RESOLVER_CONFIG (one shared pgConnection + one handler per read model),
// dynamically imports each spec package, and registers a per-read-model
// `binding` into PgQueryResolver_Lambda. AppSync invokes `handler` with the
// resolver payload { readModelName, kind, index?, arguments, identity }, which
// PgQueryResolver_Lambda.dispatch routes.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// seams that are inherently untyped — the dynamic `import()` of the spec
// packages named in QUERY_RESOLVER_CONFIG, the `patchSpecId` fix-up, and the
// reads of the runtime-loaded modules' exports. QUERY_RESOLVER_CONFIG parsing,
// the pool/engine construction, the push-down record, and binding registration
// live type-checked in PgQueryResolverEntryPoint_Ops.res.

import { handler as dispatchHandler } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res.mjs";
import { patchSpecId, log } from "./HandlerFactoryHelpers.mjs";
import * as Ops from "./PgQueryResolverEntryPoint_Ops.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function buildAllBindings() {
  const config = Ops.parseResolverConfig(process.env["QUERY_RESOLVER_CONFIG"] || "");
  const pgConnection = config.pgConnection;
  if (!pgConnection) {
    log.warn("no pgConnection in QUERY_RESOLVER_CONFIG", { comp: "PgQueryResolver" });
    return;
  }

  Ops.registerNodeTypes(config);
  const pushdowns = Ops.makePushdowns(pgConnection);

  await Promise.all(config.handlers.map(async h => {
    const specModule = patchSpecId(await dynamicImport(h.specModule));
    Ops.registerBinding(pushdowns, pgConnection, h, {
      config: specModule.config,
      subIdConfig: specModule.subIdConfig,
      stateSchema: specModule.stateSchema,
      authorization: specModule.authorization,
    });
  }));
}

const initPromise = buildAllBindings();

// AppSync Lambda data source: the invocation payload IS the event.
export async function handler(event, context) {
  await initPromise;
  return dispatchHandler(event, context);
}
