open JestGlobals

// `confidentMatch` is the gate between "the geocoder said something" and "a
// coordinate is written into an event log". Every case it declines is a
// plausible-looking pin it refused to draw, so the declines are the assertions
// that matter here.
//
// It is provider-neutral policy (`Reventless.Geocoding`), shared by the SDK-backed
// transport in this package and by any plugin reaching a geocoder over HTTP.

module Geocoding = Reventless.Geocoding

let point = (~lat, ~lng) =>
  switch Reventless.GeoPoint.make(~lat, ~lng) {
  | Ok(p) => p
  | Error(why) => fail(why)
  }

let candidate = (~label, ~relevance=?): Geocoding.candidate => {
  label,
  point: point(~lat=48.2082, ~lng=16.3738),
  relevance,
}

describe("Geocoder_AwsLocation_Geocoding.confidentMatch", () => {
  testSync("a clear winner is the answer", () => {
    let top = candidate(~label="Stephansplatz 1, Vienna", ~relevance=0.97)
    let result = Geocoding.confidentMatch([top, candidate(~label="Elsewhere", ~relevance=0.4)])
    expect(result->Option.map(c => c.Geocoding.label))->toEqual(Some("Stephansplatz 1, Vienna"))
  })

  testSync("a loose top match is declined", () => {
    let result = Geocoding.confidentMatch([candidate(~label="Somewhere-ish", ~relevance=0.55)])
    expect(result->Option.isNone)->toBe(true)
  })

  testSync("two near-equal candidates are ambiguous, not a winner", () => {
    // The bare-town-name case: the service matched several places about equally
    // well, and picking the first would pin a confident marker in the wrong one.
    let result = Geocoding.confidentMatch([
      candidate(~label="Springfield, IL", ~relevance=0.91),
      candidate(~label="Springfield, MA", ~relevance=0.89),
    ])
    expect(result->Option.isNone)->toBe(true)
  })

  testSync("an unscored candidate is not confident", () => {
    // An index that reports no relevance cannot support an unattended decision;
    // accepting it would make the threshold meaningless where it matters most.
    let result = Geocoding.confidentMatch([candidate(~label="Unscored")])
    expect(result->Option.isNone)->toBe(true)
  })

  testSync("no candidates, no match", () => {
    expect(Geocoding.confidentMatch([])->Option.isNone)->toBe(true)
  })

  testSync("the thresholds are callable, not baked in", () => {
    let loose = [candidate(~label="Loose", ~relevance=0.62)]
    expect(Geocoding.confidentMatch(loose)->Option.isNone)->toBe(true)
    expect(
      Geocoding.confidentMatch(loose, ~minRelevance=0.5)->Option.map(c => c.Geocoding.label),
    )->toEqual(Some("Loose"))
  })
})
