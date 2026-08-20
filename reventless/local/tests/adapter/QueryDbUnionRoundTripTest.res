// A tagged-union state field, saved and read back under both local backends.
//
// The stamp that puts `__typename` beside `TAG` runs in QueryDb_Operations, so
// what a backend has to do is carry a nested object with one extra key and hand
// it back. Cheap to assume and cheap to check — and the failure it guards
// against is not a decode error but a union member that resolves to null, which
// takes its non-nullable parent with it and reads as data loss.
//
// The spec is declared here rather than shared with reventless-core's fixture:
// a package's `type: dev` sources are not visible to another package, and the
// union is four lines.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({lat: float, lng: float})
  | Unresolvable({reason: string})

let geolocationSchema = Reventless.TaggedUnion.named(~name="Geolocation", geolocationSchema)

module CustomersSpec = {
  module Id = Reventless.Id.StringPure
  let name = "UnionRoundTripCustomers"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {customerId: string, geolocation: geolocation}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

let runUnderMemory = async fn => {
  BackendState.setMemory()
  await fn()
}

let runUnderSqlite = async fn => {
  let db = SqliteDriver.openDb(~path=":memory:")
  BackendState.setSqlite(~db, ~path=":memory:")
  await fn()
  BackendState.setMemory()
  db->SqliteDriver.close
}

describe("QueryDb round-trips a union field", () => {
  let scenario = async () => {
    module TestBus = LocalBus.Make()
    module Storage = LocalQueryDbStorage.Make(TestBus)
    let s = Storage.make(
      ~name="union-round-trip",
      ~indexes=[],
      ~api=(),
      ~apiRole=(),
      ~owner=None,
      ~opts,
    )
    let jsonOps = await s.operations->TestRunner.resolve
    module Ops = ReventlessCore.QueryDb_Operations.Make(
      CustomersSpec,
      {
        let jsonOps = jsonOps
      },
    )

    let _ = await Ops.save(
      "c-1",
      {customerId: "c-1", geolocation: Located({lat: 48.2082, lng: 16.3738})},
      ReventlessCore.QueryDb.Any,
      None,
    )

    // The stored row, as any read door would hand it back.
    let stored =
      await jsonOps.loadStream("c-1")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    let typename =
      stored
      ->Array.get(0)
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("geolocation"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("__typename"))
      ->Option.flatMap(JSON.Decode.string)
    expect(typename)->toEqual(Some("GeolocationLocated"))

    let items =
      await Ops.loadStream("c-1"->CustomersSpec.Id.makeFromString)
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    switch items {
    | [{geolocation: Located({lat, lng})}] => expect((lat, lng))->toEqual((48.2082, 16.3738))
    | _ => expect("round trip")->toBe("Located with its point intact")
    }
  }

  testPromise("in-memory", () => runUnderMemory(scenario))
  testPromise("sqlite", () => runUnderSqlite(scenario))
})
