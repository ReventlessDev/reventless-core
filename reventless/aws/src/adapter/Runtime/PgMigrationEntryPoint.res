// One-shot Postgres schema-migration Lambda entry point (A3) — compiled,
// type-checked ReScript (replaces the hand-written PgMigrationEntryPoint.mjs
// shell; no dynamic user-module import, so no untyped seam is needed).
//
// Invoked once during `pulumi up` by an `aws.lambda.Invocation` resource, from
// INSIDE the DB's VPC, so the deploy runner needs no network path to a private
// RDS instance. Runs the exact idempotent `PgSchema.ensureSchema` the local
// backend runs at startup (reventless-local's `postgres` smart constructor), so
// the AWS schema is byte-identical to local — zero drift. Every statement is
// `IF NOT EXISTS`, so re-invocation (e.g. after a schema-DDL change bumps the
// Lambda layer) is safe.
//
// Runtime-pure: `PgConnection.connectionConfig` is referenced as a type only
// (erased — no runtime import of the Pulumi-carrying PgConnection module);
// PgRuntime/PgSchema are runtime modules. Deploy-time wiring lives in
// PgMigration_Builder.
//
// HANDLER_CONFIG shape:
//   { "pgConnection": { host, port, database, username, secretArn } }


// Structured JSON logging shared by every deployed entry point (HandlerFactoryHelpers).
type logExtra = {comp?: string}
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logInfo: (string, logExtra) => unit = "info"

type handlerConfig = {pgConnection?: PgConnection.connectionConfig}
@val @scope("JSON") external parseHandlerConfig: string => handlerConfig = "parse"

// Config parse → pool → ensureSchema, with the pool source injectable so the
// orchestration is integration-testable against a real Postgres without the
// Secrets Manager round-trip (mirrors PgChangeFeedRelay_Runtime's
// relayWithPool/relay split). `~makePool` defaults to the production `poolFor`,
// which memoises one pool per secret ARN per container and resolves the
// RDS-managed password from Secrets Manager via a cached provider.
let runMigration = async (
  config: handlerConfig,
  ~makePool: PgConnection.connectionConfig => ReventlessPostgres.PgDriver.pool=PgRuntime.poolFor,
): string => {
  switch config.pgConnection {
  | None => JsError.throwWithMessage("PgMigrationEntryPoint: HANDLER_CONFIG has no pgConnection")
  | Some(conn) =>
    let pool = makePool(conn)
    await ReventlessPostgres.PgSchema.ensureSchema(pool)
    logInfo(`ensureSchema completed for ${conn.database}`, {comp: "PgMigration"})
    "ok"
  }
}

// Runtime extension seam: HandlerFactoryHelpers loads and fires any registered
// out-of-tree extension once, at module load. Awaiting its promise before this
// handler does any work is what makes "before the first request" a fact rather
// than a hope; it is already resolved on every invocation after the first, and
// resolves immediately when nothing is registered.
@module("./HandlerFactoryHelpers.mjs")
external runtimeExtensionsReady: promise<unit> = "runtimeExtensionsReady"

let handler = async (_event: JSON.t, _context: PulumiAws.Lambda.context) => {
  await runtimeExtensionsReady
  let config = NodeProcess.env->Dict.get("HANDLER_CONFIG")->Option.getOr("{}")->parseHandlerConfig
  await runMigration(config)
}
