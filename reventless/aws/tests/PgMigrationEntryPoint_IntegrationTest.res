// Rung-1 integration guard for the A3 schema-migration Lambda entry point.
//
// Drives the real `PgMigrationEntryPoint.runMigration` — the orchestration the
// deployed one-shot migration Lambda runs (parse HANDLER_CONFIG → build pool →
// PgSchema.ensureSchema). The pool source is injected so this exercises the
// whole path against a real Postgres WITHOUT the Secrets Manager round-trip
// (that AWS boundary is the only remaining unvalidated piece). Proves the
// migration leaves a queryable schema and is safely re-runnable.
//
// Run via `pnpm run test:integration:pg` (boots a Postgres sidecar, runs the PG
// suites serially, tears down). Excluded from the default parallel `pnpm test`.
// The guard test (no pgConnection → throws) needs no DB; the live path is
// skipped unless PG_URL is set (the script exports it).

open JestGlobals

@val external processEnv: dict<string> = "process.env"

// Drive the real ReScript `runMigration` with the pool injected — the guard
// rejects a HANDLER_CONFIG with no pgConnection; the real fields below are
// ignored because `~makePool` is injected. Returns "ok" on success.
let runMigrationWithPool = (pool: ReventlessPostgres.PgDriver.pool): promise<string> =>
  PgMigrationEntryPoint.runMigration(
    {
      pgConnection: {
        host: "ignored",
        port: 5432,
        database: "ignored",
        username: "ignored",
        secretArn: "ignored",
      },
    },
    ~makePool=_ => pool,
  )

describe("PgMigrationEntryPoint.runMigration", () => {
  testPromise("rejects a HANDLER_CONFIG with no pgConnection", async () => {
    // An empty config carries no pgConnection (a misconfigured deploy); the
    // guard must reject it rather than silently building a bad pool.
    let threw = try {
      let _ = await PgMigrationEntryPoint.runMigration({pgConnection: ?None})
      false
    } catch {
    | _ => true
    }
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
