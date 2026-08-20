open JestGlobals

// Load-bearing: `ofSearch` mapping an unavailable provider to no arm, and the
// two schema markers, whose loss degrades the field to `String` silently.

let candidate = (~label, ~lat=48.2082, ~lng=16.3738, ~relevance=?): Geocoding.candidate => {
  label,
  point: {lat, lng},
  relevance,
}

describe("Geolocation.ofSearch maps every geocoder outcome:", () => {
  // Retryable, so the row keeps whatever it had.
  testSync("an unavailable provider produces no arm at all", () => {
    expect(
      Geolocation.ofSearch(~requestedFor="Stephansplatz 1", Error(Unavailable("timeout"))),
    )->toEqual(None)
  })

  // Beside the case above: both mean "no point", only one is a verdict.
  testSync("a provider that answered with nothing produces a verdict", () => {
    let reason =
      Geolocation.ofSearch(~requestedFor="Nowhere St", Error(NoMatch))->Option.flatMap(
        Geolocation.reason,
      )
    expect(reason->Option.isSome)->toBe(true)
  })

  testSync("a confident candidate produces its point", () => {
    let located = Geolocation.ofSearch(
      ~requestedFor="Stephansplatz 1",
      Ok([candidate(~label="Stephansplatz 1, Vienna", ~relevance=0.995)]),
    )
    expect(located->Option.flatMap(Geolocation.point))->toEqual(
      Some(({lat: 48.2082, lng: 16.3738}: GeoPoint.t)),
    )
  })

  testSync("an empty candidate list produces a verdict, not a point", () => {
    let result = Geolocation.ofSearch(~requestedFor="Nowhere St", Ok([]))
    expect(result->Option.map(Geolocation.isLocated))->toEqual(Some(false))
  })
})

// Why `confidentMatch` was widened into `assess`: reasons must stay distinct.
describe("Geolocation.ofSearch says which rule declined:", () => {
  let reasonFor = candidates =>
    Geolocation.ofSearch(~requestedFor="Springfield", Ok(candidates))
    ->Option.flatMap(Geolocation.reason)
    ->Option.getOr("")

  testSync("a loose match names the score and the floor it missed", () => {
    let reason = reasonFor([candidate(~label="Somewhere-ish", ~relevance=0.55)])
    expect(reason->String.includes("Somewhere-ish"))->toBe(true)
    expect(reason->String.includes("0.55"))->toBe(true)
  })

  testSync("an ambiguous match names both candidates", () => {
    let reason = reasonFor([
      candidate(~label="Springfield, IL", ~relevance=0.99),
      candidate(~label="Springfield, MA", ~relevance=0.985),
    ])
    expect(reason->String.includes("Springfield, IL"))->toBe(true)
    expect(reason->String.includes("Springfield, MA"))->toBe(true)
  })

  // Unscored is not a low score, and wants a different response.
  testSync("an unscored answer says so rather than reporting a score", () => {
    let reason = reasonFor([candidate(~label="Unscored")])
    expect(reason->String.includes("without scoring"))->toBe(true)
  })

  testSync("the two declining reasons are not the same sentence", () => {
    let loose = reasonFor([candidate(~label="Somewhere-ish", ~relevance=0.55)])
    let ambiguous = reasonFor([
      candidate(~label="Springfield, IL", ~relevance=0.99),
      candidate(~label="Springfield, MA", ~relevance=0.985),
    ])
    expect(loose == ambiguous)->toBe(false)
  })

  // Provider-calibrated, so a caller must be able to move them.
  testSync("a caller's own floor is honoured", () => {
    let candidates = [candidate(~label="Somewhere-ish", ~relevance=0.55)]
    let withDefault = Geolocation.ofSearch(~requestedFor="x", Ok(candidates))
    let withLowFloor = Geolocation.ofSearch(~requestedFor="x", ~minRelevance=0.5, Ok(candidates))
    expect(withDefault->Option.map(Geolocation.isLocated))->toEqual(Some(false))
    expect(withLowFloor->Option.map(Geolocation.isLocated))->toEqual(Some(true))
  })
})

describe("Geolocation accessors answer without matching arms:", () => {
  testSync("point is present only when located", () => {
    expect(Geolocation.point(Located({point: {lat: 1.0, lng: 2.0}})))->toEqual(
      Some(({lat: 1.0, lng: 2.0}: GeoPoint.t)),
    )
    expect(Geolocation.point(Pending({requestedFor: "x"})))->toEqual(None)
    expect(Geolocation.point(Unresolvable({reason: "y"})))->toEqual(None)
  })

  // No reason on `Pending` is the distinction, not an omission.
  testSync("only an unresolvable row carries a reason", () => {
    expect(Geolocation.reason(Unresolvable({reason: "ambiguous"})))->toEqual(Some("ambiguous"))
    expect(Geolocation.reason(Pending({requestedFor: "x"})))->toEqual(None)
    expect(Geolocation.reason(Located({point: {lat: 1.0, lng: 2.0}})))->toEqual(None)
  })
})

// Independent metadata writes on one schema; either lost is invisible until a deploy.
describe("the Geolocation schema carries both markers:", () => {
  let schema = Geolocation.schema->S.castToUnknown

  testSync("it classifies as a union named Geolocation", () => {
    expect(TaggedUnion.getName(schema))->toEqual(Some("Geolocation"))
  })

  testSync("it has exactly the three arms, and they are well-formed", () => {
    let tags = TaggedUnion.armsOf(schema)->Option.getOr([])->Array.map(a => a.tag)
    expect(tags->Array.toSorted(String.compare))->toEqual(["Located", "Pending", "Unresolvable"])
  })

  testSync("the semantic marker survives beside the union name", () => {
    expect(Semantic.get(schema)->Option.map(s => s.id))->toEqual(Some(Semantic.Id.geolocation))
  })

  // A published contract: the UI selects these by name.
  testSync("the member type names are the union's name plus the arm's", () => {
    expect(TaggedUnion.memberTypeName(~union="Geolocation", ~arm="Located"))->toEqual(
      "GeolocationLocated",
    )
  })
})

describe("Geolocation round-trips through its wire form:", () => {
  let encode = (value: Geolocation.t) => value->Util_Sury.toJson(Geolocation.schema)
  let roundTrip = (value: Geolocation.t) =>
    value->encode->S.parseOrThrow(~to=Geolocation.schema)

  testSync("a located point survives", () => {
    let value: Geolocation.t = Located({point: {lat: 48.2082, lng: 16.3738}})
    expect(roundTrip(value))->toEqual(value)
  })

  testSync("a pending address survives", () => {
    let value: Geolocation.t = Pending({requestedFor: "Stephansplatz 1"})
    expect(roundTrip(value))->toEqual(value)
  })

  testSync("an unresolvable reason survives", () => {
    let value: Geolocation.t = Unresolvable({reason: "ambiguous"})
    expect(roundTrip(value))->toEqual(value)
  })

  // What every backend persists, and what the `__typename` stamp lands on.
  testSync("the stored shape is TAG-discriminated", () => {
    let tag =
      encode(Located({point: {lat: 1.0, lng: 2.0}}))
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("TAG"))
      ->Option.flatMap(JSON.Decode.string)
    expect(tag)->toEqual(Some("Located"))
  })
})
