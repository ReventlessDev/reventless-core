open JestGlobals
open QueryDbFixtures
open TaggedUnionFixtures

// The write-time `__typename` stamp, and the storage round trip it has to
// survive. Both AppSync and graphql-js resolve a union member from `__typename`
// on the value they are handed; the AppSync resolvers hand back the stored item
// unchanged, and the live change channel carries the row as raw JSON past the
// typed field entirely. So the stamp lands here, once, and everything downstream
// reads a row that already says which arm it is.

module Customers = QueryDb_Operations.Make(
  CustomersSpec,
  {
    let jsonOps = mockJsonOps
  },
)

module Sightings = QueryDb_Operations.Make(
  SightingsSpec,
  {
    let jsonOps = mockJsonOps
  },
)

module Items = QueryDb_Operations.Make(
  ItemQueryDbSpec,
  {
    let jsonOps = mockJsonOps
  },
)

let _ = beforeEach(() => reset())

let storedRow = id =>
  store.contents->Dict.get(id)->Option.getOr([])->Array.get(0)->Option.getOr(JSON.Encode.null)

let field = (json, name) =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))->Option.getOr(JSON.Encode.null)

let string = json => json->JSON.Decode.string

describe("QueryDb_Operations stamps union members", () => {
  testPromise("the stored value carries __typename beside TAG", async () => {
    let state: CustomersSpec.state = {
      customerId: "c-1",
      geolocation: Located({point: {lat: 48.2082, lng: 16.3738}}),
    }
    let _ = await Customers.save("c-1", state, Init, None)
    let geo = storedRow("c-1")->field("geolocation")
    expect(geo->field("TAG")->string)->toEqual(Some("Located"))
    expect(geo->field("__typename")->string)->toEqual(Some("GeolocationLocated"))
  })

  testPromise("every arm is stamped as the member type it is", async () => {
    let _ = await Customers.save(
      "c-2",
      {customerId: "c-2", geolocation: Pending({requestedFor: "1 High St"})},
      Init,
      None,
    )
    let _ = await Customers.save(
      "c-3",
      {customerId: "c-3", geolocation: Unresolvable({reason: "ambiguous"})},
      Init,
      None,
    )
    expect(storedRow("c-2")->field("geolocation")->field("__typename")->string)->toEqual(
      Some("GeolocationPending"),
    )
    expect(storedRow("c-3")->field("geolocation")->field("__typename")->string)->toEqual(
      Some("GeolocationUnresolvable"),
    )
  })

  testPromise("an optional union and an array of them are stamped too", async () => {
    let state: SightingsSpec.state = {
      sightingId: "s-1",
      lastSeen: Some(Located({point: {lat: 1.0, lng: 2.0}})),
      history: [Pending({requestedFor: "somewhere"}), Unresolvable({reason: "gone"})],
    }
    let _ = await Sightings.save("s-1", state, Init, None)
    let row = storedRow("s-1")
    expect(row->field("lastSeen")->field("__typename")->string)->toEqual(
      Some("GeolocationLocated"),
    )
    let history = row->field("history")->JSON.Decode.array->Option.getOr([])
    expect(history->Array.map(h => h->field("__typename")->string))->toEqual([
      Some("GeolocationPending"),
      Some("GeolocationUnresolvable"),
    ])
  })

  testPromise("an absent optional union leaves nothing behind", async () => {
    let _ = await Sightings.save(
      "s-2",
      {sightingId: "s-2", lastSeen: None, history: []},
      Init,
      None,
    )
    expect(storedRow("s-2")->field("lastSeen"))->toEqual(JSON.Encode.null)
  })

  // What keeps this releasable ahead of any adopter: a view with no union field
  // is walked and written exactly as it was written before the walk existed.
  testPromise("a view with no union field stores what it always stored", async () => {
    let _ = await Items.save("item-1", {name: "Widget", count: 5}, Init, None)
    expect(storedRow("item-1")->JSON.stringify)->toBe(
      `{"name":"Widget","count":5,"id":"item-1"}`,
    )
  })

  testPromise("saveBatch stamps every row", async () => {
    let batch = [
      (
        "c-4",
        ({customerId: "c-4", geolocation: Located({point: {lat: 0.0, lng: 0.0}})}: CustomersSpec.state),
        None,
      ),
      (
        "c-5",
        ({customerId: "c-5", geolocation: Pending({requestedFor: "x"})}: CustomersSpec.state),
        None,
      ),
    ]
    let _ = await Customers.saveBatch(batch)
    expect((
      storedRow("c-4")->field("geolocation")->field("__typename")->string,
      storedRow("c-5")->field("geolocation")->field("__typename")->string,
    ))->toEqual((Some("GeolocationLocated"), Some("GeolocationPending")))
  })
})

describe("a stamped row decodes back", () => {
  testPromise("the extra key does not disturb the parse", async () => {
    let _ = await Customers.save(
      "c-6",
      {customerId: "c-6", geolocation: Located({point: {lat: 48.2082, lng: 16.3738}})},
      Init,
      None,
    )
    let result = await Customers.loadStream("c-6")->Stream.runCollect->Effect.runPromise
    switch result {
    | [{geolocation: Located({point})}] => expect((point.lat, point.lng))->toEqual((48.2082, 16.3738))
    | _ => expect("round trip")->toBe("Located with its point intact")
    }
  })

  // A row written before the field existed. Replay is what a read model is for,
  // so this is a convenience rather than a contract — but it must not throw,
  // because a single unparseable row otherwise fails the whole page.
  testPromise("a row written before the union field arrives as the first arm", async () => {
    store.contents->Dict.set(
      "c-7",
      [JSON.Encode.object(Dict.fromArray([("customerId", JSON.Encode.string("c-7"))]))],
    )
    let result = await Customers.loadStream("c-7")->Stream.runCollect->Effect.runPromise
    switch result {
    | [{geolocation: Pending({requestedFor})}] => expect(requestedFor)->toBe("")
    | _ => expect("healed row")->toBe("Pending")
    }
  })
})
