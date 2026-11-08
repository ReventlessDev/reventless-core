// Live-Postgres: a query clause with no event type matches nothing, in the read and in the
// append condition (`dcb_condition_where`). Run via `pnpm run test:integration:pg`; self-skips
// unless PG_URL is set.

open JestGlobals
open ReventlessCore
open Reventless

let opts: Pulumi.CustomResourceOptions.t = {}

let charger: DcbTag.tag = {key: "chargerId", value: "charger-1"}

let noted = (): DcbEventLog_Adapter.rawStoredEvent => {
  eventType: "FaultNoted",
  data: JSON.Encode.object(Dict.fromArray([("chargerId", JSON.Encode.string("charger-1"))])),
  tags: [charger],
  meta: ReventlessCore.Message.generateMeta(~service="matches-nothing-it"),
}

switch NodeProcess.env->Dict.get("PG_URL") {
| None =>
  testSync("Postgres empty-clause integration (skipped — set PG_URL to run)", () =>
    expect(true)->toBe(true)
  )
| Some(url) =>
  let pool = ReventlessPostgres.PgDriver.makePool({connectionString: url})

  beforeAllAsync(async () => {
    await ReventlessPostgres.PgSchema.ensureSchema(pool)
    await ReventlessPostgres.PgSchema.truncateAll(pool)
  })
  afterAll(() => {
    let _ = pool->ReventlessPostgres.PgDriver.endPool
  })

  describe("a clause with no event type (Postgres)", () => {
    testPromise("reads nothing, and as a condition never conflicts", async () => {
      let (_n, ops, _s) = ReventlessPostgres.DcbEventLogStorage_Postgres.makeStorage(
        ~pool,
        ~name="matches-nothing",
        ~indexes=[],
        ~partitionTag=DcbTag.Simple({key: "chargerId"}),
        ~opts,
      )
      let _ = await ops.append([noted()])
      let nothing: DcbTag.query = [{eventTypes: [], tags: [charger]}]
      let read = (await ops.read(~query=nothing)).events->Array.length
      let all = (await ops.read(~query=[{tags: [charger]}])).events->Array.length
      // From before the event: a clause that matched it would conflict.
      let appended = await ops.append([noted()], ~condition={query: nothing})
      expect((read, all, appended->Result.isOk))->toEqual((0, 1, true))
    })
  })
}
