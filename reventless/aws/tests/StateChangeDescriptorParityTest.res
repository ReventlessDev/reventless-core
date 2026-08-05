// Parity of the live-update change descriptor across its three implementations:
//
//   - LocalStateChangeDescriptor      (reventless-local, both backends)
//   - StateTopic_AppSync_Ops          (DynamoDB stream relay)
//   - StateTopicPublish.mjs           (Postgres projection-side publisher)
//
// They share no code on purpose — the relay module stays Pulumi-free so a core
// import can't pull deploy-time code into its Lambda graph — which makes drift
// the standing risk: three sites, one wire format, and a browser that cannot tell
// which one produced a frame. This test is the guard.
//
// `seq` is normalised away by the harness because the three take it from different
// monotonic sources by design (a DynamoDB stream SequenceNumber vs a wall-clock
// counter); the harness still asserts each produced a non-empty string.

open JestGlobals

type case = {
  name: string,
  local: JSON.t,
  relay: JSON.t,
  postgres: JSON.t,
}

@module("./stateChangeDescriptorParity.mjs")
external buildAll: unit => promise<array<case>> = "buildAll"

describe("state-change descriptor parity", () => {
  testAsync("every implementation builds the same descriptor", async () => {
    let cases = await buildAll()
    // A silent zero-case run would pass while asserting nothing.
    expect(cases->Array.length)->toBe(6)
    cases->Array.forEach(c => {
      expect((c.name, c.relay))->toEqual((c.name, c.local))
      expect((c.name, c.postgres))->toEqual((c.name, c.local))
    })
  })

  testAsync("a save carries the row, a delete carries none", async () => {
    let cases = await buildAll()
    let stateOf = (d: JSON.t) =>
      d->JSON.Decode.object->Option.flatMap(o => o->Dict.get("state"))
    let byName = name => cases->Array.find(c => c.name == name)

    switch byName("single-key save with updatedAt") {
    | Some(c) => expect(stateOf(c.local)->Option.isSome)->toBe(true)
    | None => expect("save case missing")->toBe("present")
    }
    switch byName("delete carries no row") {
    | Some(c) => expect(stateOf(c.local))->toEqual(None)
    | None => expect("delete case missing")->toBe("present")
    }
    switch byName("oversized row degrades to metadata only") {
    | Some(c) => expect(stateOf(c.local))->toEqual(None)
    | None => expect("oversized case missing")->toBe("present")
    }
  })
})
