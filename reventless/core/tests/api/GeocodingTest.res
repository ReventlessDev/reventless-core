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
    let top = candidate(~label="Stephansplatz 1, Vienna", ~relevance=1.0)
    let result = Geocoding.confidentMatch([top, candidate(~label="Elsewhere", ~relevance=0.4)])
    expect(result->Option.map(c => c.Geocoding.label))->toEqual(Some("Stephansplatz 1, Vienna"))
  })

  testSync("a loose top match is declined", () => {
    let result = Geocoding.confidentMatch([candidate(~label="Somewhere-ish", ~relevance=0.55)])
    expect(result->Option.isNone)->toBe(true)
  })

  testSync("two near-equal candidates are ambiguous, not a winner", () => {
    // The bare-town-name case, with the scores the live Esri index actually
    // returns for it: five states at exactly 1.0. Genuine ambiguity there is a
    // tie, not a near miss — which is why the margin is small and this case is
    // still caught.
    let result = Geocoding.confidentMatch([
      candidate(~label="Springfield, IL", ~relevance=1.0),
      candidate(~label="Springfield, MA", ~relevance=1.0),
    ])
    expect(result->Option.isNone)->toBe(true)
  })

  testSync("a correct match with a plausible runner-up is still a winner", () => {
    // Measured against the live index: "Baker Street 221B, London NW1 6XE"
    // returns the right building — matching postcode — at 0.991, with an
    // unrelated Baker Street at 0.962. The previous calibration (floor 0.8,
    // margin 0.1) read that 0.029 gap as ambiguity and declined, so a perfectly
    // good address was written off as unresolvable and, per the retry policy,
    // never tried again. Three of twelve realistic addresses failed this way.
    let result = Geocoding.confidentMatch([
      candidate(~label="221 Baker Street, Marylebone, London NW1 6XE", ~relevance=0.991),
      candidate(~label="Baker Street, elsewhere", ~relevance=0.962),
    ])
    expect(result->Option.map(c => c.Geocoding.label))->toEqual(
      Some("221 Baker Street, Marylebone, London NW1 6XE"),
    )
  })

  testSync("a wrong street in the right city is declined", () => {
    // The other half of the same measurement, and the reason the floor moved up
    // rather than the margin merely moving down: "Kaiserstrasse 12, 4020 Linz"
    // resolves to *Rainerstrasse* 12 in Linz at 0.958. Its gap to the runner-up
    // is 0.031 — wider than the correct match above — so no margin can separate
    // the two. Only the absolute score can.
    let result = Geocoding.confidentMatch([
      candidate(~label="Rainerstraße 12, 4020 Linz", ~relevance=0.958),
      candidate(~label="Somewhere else, Linz", ~relevance=0.927),
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
