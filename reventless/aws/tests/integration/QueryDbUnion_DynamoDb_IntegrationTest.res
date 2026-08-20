// A tagged-union state field, saved and read back through the real DynamoDB
// QueryDb path (DynamoDB Local — NOT run by the default unit suite; see
// `jest.integration.config.js` + `scripts/run-integration-tests.sh`).
//
// What a backend has to do here is carry a nested map with one extra key and
// hand it back unchanged. That is exactly what the AppSync resolvers rely on:
// they return the stored item as it is, and the `__typename` the write path
// stamped is the only thing that tells GraphQL which union member the value is.
// A backend that dropped or renamed the key would not produce a decode error —
// it would produce a member that resolves to null, and a null in a non-nullable
// field takes its parent row with it.

open JestGlobals

module H = AggIntegrationHarness

@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({lat: float, lng: float})
  | Unresolvable({reason: string})

let geolocationSchema = Reventless.TaggedUnion.named(~name="Geolocation", geolocationSchema)

module CustomersSpec = {
  module Id = Reventless.Id.StringPure
  let name = "UnionRoundTripCustomers"
  let moduleUrl = ""

  @schema
  type state = {customerId: string, geolocation: geolocation}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
  let authorization: Reventless.Authorization.permission = AllowAuthenticated
  let visibility: Reventless.Visibility.t = Public
}

let tableName = "qdb-union-round-trip"

describe("QueryDb (DynamoDB) round-trips a union field", () => {
  testPromise("a stored Located keeps its member type and its point", async () => {
    let table = await H.createQueryDbTable(tableName)
    let jsonOps = QueryDbEntryPoint_Ops.makeDynamoQueryDbOps(~tableName=table.name)
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

    // The item as a read door hands it back.
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

    await H.deleteTable(table)
  })
})
