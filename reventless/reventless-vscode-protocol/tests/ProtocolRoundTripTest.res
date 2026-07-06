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
  // The graceful-degrade guarantee the protocolVersion notes rely on: a NEWER
  // emitter's extra keys on a KNOWN event must be tolerated and dropped, not
  // rejected (sury's object parse is non-strict). If this test ever fails after a
  // sury upgrade, additive version bumps become hard wire breaks for old decoders.
  testSync("unknown extra keys on a known event are dropped (non-strict decode)", () =>
    expect(
      P.parseStreamEvent(
        `{"event":"graph","nodes":[],"edges":[{"from":"a","to":"b","kind":"triggers","via":["X"],"implicit":true,"futureEdgeKey":0.5}],"futureTopKey":true}`,
      ),
    )->toEqual(
      Some(
        P.Graph({
          nodes: [],
          edges: [{from: "a", to_: "b", kind: "triggers", via: ["X"], implicit: true}],
        }),
      ),
    )
  )
})
