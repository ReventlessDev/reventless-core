// A tagged-union state field, saved and read back through the real Postgres
// QueryDb path.
//
// Run via `pnpm run test:integration:pg` (boots a Postgres sidecar, runs the PG
// suites serially, tears down). Self-skips unless PG_URL is set.
//
// The Postgres resolver is the one backend that stamps a `__typename` of its own
// — the top-level row's ([PgQueryResolver_Lambda]) — and it stamps only that one.
// A union field sits one level in, which is precisely why the member stamp is
// written by the *write* path instead: what this suite proves is that the key
// survives the jsonb round trip, so the resolver has something to return.

open JestGlobals

@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({lat: float, lng: float})
  | Unresolvable({reason: string})

let geolocationSchema = Reventless.TaggedUnion.named(~name="Geolocation", geolocationSchema)

module CustomersSpec = {
  module Id = Reventless.Id.StringPure
  let name = "PgUnionCustomers"
  let moduleUrl = ""

  @schema
  type state = {customerId: string, geolocation: geolocation}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
  let authorization: Reventless.Authorization.permission = AllowAuthenticated
  let visibility: Reventless.Visibility.t = Public
}

switch NodeProcess.env->Dict.get("PG_URL") {
| None =>
  testSync("Postgres union round trip (skipped — set PG_URL to run)", () =>
    expect(true)->toBe(true)
  )
| Some(url) =>
  let pool = ReventlessPostgres.PgDriver.makePool({connectionString: url})

  let jsonOps = ReventlessPostgres.QueryDbStorage_Postgres.makeOperations(
    ~pool,
    ~name=CustomersSpec.name,
    ~indexes=[],
    ~subIdField=None,
  )

  module Ops = ReventlessCore.QueryDb_Operations.Make(
    CustomersSpec,
    {
      let jsonOps = jsonOps
    },
  )

  beforeAllAsync(async () => {
    await ReventlessPostgres.PgSchema.ensureSchema(pool)
    await ReventlessPostgres.PgSchema.truncateAll(pool)
    let _ = await pool->ReventlessPostgres.PgDriver.query(
      `DROP TABLE IF EXISTS qdb_${CustomersSpec.name}`,
      [],
    )
  })
  afterAll(() => {
    let _ = pool->ReventlessPostgres.PgDriver.endPool
  })

  describe("QueryDb (Postgres) round-trips a union field", () => {
    testPromise("a stored Located keeps its member type and its point", async () => {
      let _ = await Ops.save(
        "c-1"->CustomersSpec.Id.makeFromString,
        {customerId: "c-1", geolocation: Located({lat: 48.2082, lng: 16.3738})},
        ReventlessCore.QueryDb.Any,
        None,
      )

      switch await jsonOps.load("c-1") {
      | Ok(rows) =>
        let typename =
          rows
          ->Array.get(0)
          ->Option.flatMap(JSON.Decode.object)
          ->Option.flatMap(o => o->Dict.get("geolocation"))
          ->Option.flatMap(JSON.Decode.object)
          ->Option.flatMap(o => o->Dict.get("__typename"))
          ->Option.flatMap(JSON.Decode.string)
        expect(typename)->toEqual(Some("GeolocationLocated"))
      | Error(_) => expect("load failed")->toBe("Ok")
      }

      switch await Ops.load("c-1"->CustomersSpec.Id.makeFromString) {
      | Ok([{geolocation: Located({lat, lng})}]) =>
        expect((lat, lng))->toEqual((48.2082, 16.3738))
      | _ => expect("round trip")->toBe("Located with its point intact")
      }
    })
  })
}
