// Round-trips every `streamEvent` variant through the wire: `toJsonLine`
// (the CLI emit path) → `parseStreamEvent` (the extension decode path) must
// reproduce the original value exactly. This pins the NDJSON contract IN this
// package — previously it was only exercised indirectly by a consumer. The
// per-variant sample values are single-sourced in `ProtocolSamples` (shared with
// the emit-golden byte-pinning test).

open JestGlobals

module P = Protocol

let roundTrips = (e: P.streamEvent) =>
  expect(P.parseStreamEvent(P.toJsonLine(e)))->toEqual(Some(e))

describe("Protocol round-trip (toJsonLine -> parseStreamEvent)", () => {
  ProtocolSamples.cases->Array.forEach(((name, e)) => testSync(name, () => roundTrips(e)))

  testSync("a malformed line decodes to None", () =>
    expect(P.parseStreamEvent("{not json"))->toEqual(None)
  )
  testSync("an unknown event decodes to None (version-skew tolerance)", () =>
    expect(P.parseStreamEvent(`{"event":"somethingNewer","x":1}`))->toEqual(None)
  )
})
