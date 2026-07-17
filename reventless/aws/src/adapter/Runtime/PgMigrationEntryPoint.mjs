// One-shot Postgres schema-migration Lambda entry point (A3).
//
// Invoked once during `pulumi up` by an `aws.lambda.Invocation` resource, from
// INSIDE the DB's VPC, so the deploy runner needs no network path to a private
// RDS instance. Runs the exact idempotent `PgSchema.ensureSchema` the local
// backend runs at startup (reventless-local's `postgres` smart constructor), so
// the AWS schema is byte-identical to local — zero drift. Every statement is
// `IF NOT EXISTS`, so re-invocation (e.g. after a schema-DDL change bumps the
// Lambda layer) is safe.
//
// HANDLER_CONFIG shape:
//   { "pgConnection": { host, port, database, username, secretArn } }

import { poolFor } from "@reventlessdev/reventless-aws/src/adapter/Postgres/PgRuntime.res.mjs";
import { ensureSchema } from "@reventlessdev/reventless-postgres/src/PgSchema.res.mjs";
import { log } from "./HandlerFactoryHelpers.mjs";

// Config parse → pool → ensureSchema, with the pool source injectable so the
// orchestration is integration-testable against a real Postgres without the
// Secrets Manager round-trip (mirrors PgChangeFeedRelay_Runtime's
// relayWithPool/relay split). `opts.makePool` defaults to the production `poolFor`.
export async function runMigration(config, opts = {}) {
  if (!config.pgConnection) {
    throw new Error("PgMigrationEntryPoint: HANDLER_CONFIG has no pgConnection");
  }
  // `poolFor` memoises one pool per secret ARN per container and resolves the
  // RDS-managed password from Secrets Manager via a cached provider.
  const makePool = opts.makePool ?? poolFor;
  const pool = makePool(config.pgConnection);
  await ensureSchema(pool);
  log.info("ensureSchema completed for " + config.pgConnection.database, {
    comp: "PgMigration",
  });
  return "ok";
}

export async function handler(_event, _context) {
  const config = JSON.parse(process.env["HANDLER_CONFIG"] || "{}");
  return runMigration(config);
}
