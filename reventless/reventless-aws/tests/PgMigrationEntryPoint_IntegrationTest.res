// Rung-1 integration guard for the A3 schema-migration Lambda entry point.
//
// Drives the real `PgMigrationEntryPoint.runMigration` — the orchestration the
// deployed one-shot migration Lambda runs (parse HANDLER_CONFIG → build pool →
// PgSchema.ensureSchema). The pool source is injected so this exercises the
// whole path against a real Postgres WITHOUT the Secrets Manager round-trip
// (that AWS boundary is the only remaining unvalidated piece). Proves the
// migration leaves a queryable schema and is safely re-runnable.
//
// The guard test (no pgConnection → throws) runs always; the live path is
// skipped unless PG_URL is set, keeping default `pnpm test` dependency-free:
//   PG_URL=postgres://postgres:postgres@localhost:5432/postgres pnpm test

open JestGlobals

@val external processEnv: dict<string> = "process.env"

// Import the .mjs entry point and call runMigration with the pool injected.
// Returns "ok" on success. A minimal pgConnection satisfies the guard; the real
// fields are ignored because `makePool` is injected.
let runMigrationWithPool: (
  ReventlessPostgres.PgDriver.pool,
) => promise<string> = %raw(`
  async (pool) => {
    const { runMigration } = await import(
      "@reventlessdev/reventless-aws/src/adapter/Runtime/PgMigrationEntryPoint.mjs"
    );
    const config = {
      pgConnection: {
        host: "ignored", port: 5432, database: "ignored",
        username: "ignored", secretArn: "ignored",
      },
    };
    return await runMigration(config, { makePool: () => pool });
  }
`)

// runMigration with an empty config — the guard must reject a HANDLER_CONFIG
// that carries no pgConnection (a misconfigured deploy), rather than silently
// building a bad pool.
let runMigrationMissingConfigThrows: unit => promise<bool> = %raw(`
  async () => {
    const { runMigration } = await import(
      "@reventlessdev/reventless-aws/src/adapter/Runtime/PgMigrationEntryPoint.mjs"
    );
    try { await runMigration({}, {}); return false; }
    catch { return true; }
  }
`)

describe("PgMigrationEntryPoint.runMigration", () => {
  testPromise("rejects a HANDLER_CONFIG with no pgConnection", async () => {
    let threw = await runMigrationMissingConfigThrows()
    expect(threw)->toBe(true)
  })

  switch processEnv->Dict.get("PG_URL") {
  | None =>
    testSync("live migration (skipped — set PG_URL to run)", () => expect(true)->toBe(true))
  | Some(url) =>
    let pool = ReventlessPostgres.PgDriver.makePool({connectionString: url})
    afterAll(() => {
      let _ = pool->ReventlessPostgres.PgDriver.endPool
    })

    testPromise("runs ensureSchema, leaving both event logs queryable", async () => {
      let _ = await runMigrationWithPool(pool)
      // countAll queries the tables ensureSchema creates — it resolves (>= 0)
      // only if `event_log` / `dcb_event` exist, and throws otherwise.
      let classicCount = await ReventlessPostgres.EventLogStorage_Postgres.countAll(pool)
      let dcbCount = await ReventlessPostgres.DcbEventLogStorage_Postgres.countAll(pool)
      expect(classicCount >= 0 && dcbCount >= 0)->toBe(true)
    })

    testPromise("is idempotent — a second run does not throw", async () => {
      let _ = await runMigrationWithPool(pool)
      let again = await runMigrationWithPool(pool)
      expect(again)->toBe("ok")
    })
  }
})
