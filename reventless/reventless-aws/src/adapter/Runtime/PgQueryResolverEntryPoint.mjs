// Shared PgQueryResolver Lambda entry point (B3.2b).
//
// One in-VPC Lambda serves every Postgres-backed read model's GraphQL Query
// fields (they have no per-table AppSync data source). At cold start it reads
// QUERY_RESOLVER_CONFIG (one shared pgConnection + one handler per read model),
// dynamically imports each spec package, and registers a per-read-model
// `binding` (ops + QueryEnginePostgres push-downs + indexes/subIdField/capability
// + baked labelField/includeIdParam + authorization) into
// PgQueryResolver_Lambda. AppSync invokes `handler` with the resolver payload
// { readModelName, kind, index?, arguments, identity }, which
// PgQueryResolver_Lambda.dispatch routes.
//
// ReScript labeled args compile positionally, so the engine push-downs
// (indexLookup/byIds/listPage/scan) are assigned straight into the `pushdowns`
// record — same calling convention PgQueryResolver_Lambda.dispatch invokes them
// with (verified against the compiled QueryEnginePostgres output).

import { poolFor } from "@reventlessdev/reventless-aws/src/adapter/Postgres/PgRuntime.res.mjs";
import { Make as makeEngine } from "@reventlessdev/reventless-postgres/src/QueryEnginePostgres.res.mjs";
import { opsFor as pgQdbOpsFor } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_Postgres_Runtime.res.mjs";
import { deriveServerCapability } from "@reventlessdev/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res.mjs";
import { register, handler as dispatchHandler } from "@reventlessdev/reventless-aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res.mjs";
import { patchSpecId, log } from "./HandlerFactoryHelpers.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// A bounded full-materialisation for the list fallback (shapes listPage
// declines). Kept high; the fallback is only hit for search/searchPrefix/ids/
// backward pagination, which the AutoUI does not issue for large models.
const SCAN_ALL_LIMIT = 100000;

async function buildAllBindings() {
  const configStr = process.env["QUERY_RESOLVER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const pgConnection = config.pgConnection;
  if (!pgConnection) {
    log.warn("no pgConnection in QUERY_RESOLVER_CONFIG", { comp: "PgQueryResolver" });
    return;
  }
  // Container-lifetime pool (memoised by poolFor); the engine and the ops set
  // share it, so a Lambda holds one pool regardless of read model count.
  const pool = poolFor(pgConnection);
  const engine = makeEngine({ pool });

  const pushdowns = {
    indexLookup: engine.indexLookup,
    byIds: engine.byIds,
    listPage: engine.listPage,
    itemsPage: engine.itemsPage,
    scanAll: (readModelName) => engine.scan(readModelName, [], SCAN_ALL_LIMIT),
  };

  await Promise.all((config.handlers || []).map(async h => {
    const specModule = patchSpecId(await dynamicImport(h.specModule));
    const indexes = (specModule.config && specModule.config.indexes) || [];
    const subIdField = specModule.subIdConfig ? specModule.subIdConfig.subIdField : undefined;
    const capability = deriveServerCapability(specModule.stateSchema);
    const ops = pgQdbOpsFor(pgConnection, h.readModelName, indexes, subIdField);

    register(h.readModelName, {
      ops,
      pushdowns,
      indexes,
      subIdField,
      capability,
      labelField: h.labelField,
      includeIdParam: h.includeIdParam,
      // Compiled string variant (e.g. "AllowAuthenticated"), injected on the
      // spec by @@reventless.spec — the shape Reventless.Authorization.isAllowed
      // matches on.
      authorization: specModule.authorization,
    });
    log.debug("registered resolver binding for " + h.readModelName, { comp: "PgQueryResolver" });
  }));
}

const initPromise = buildAllBindings();

// AppSync Lambda data source: the invocation payload IS the event.
export async function handler(event, context) {
  await initPromise;
  return dispatchHandler(event, context);
}
