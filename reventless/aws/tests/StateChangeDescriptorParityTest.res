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
    expect(cases->Array.length)->toBe(8)
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

  // The live channel is the third place a retired row could reach a caller the
  // resolvers refuse it to, and the only one that cannot be scoped per
  // subscriber — the channel is keyed by view and entity, and everyone watching
  // receives the frame. So the payload has to go, in all three implementations.
  testAsync("a retired row publishes as metadata only, everywhere", async () => {
    let cases = await buildAll()
    let keyOf = (d: JSON.t, k) => d->JSON.Decode.object->Option.flatMap(o => o->Dict.get(k))
    let byName = name => cases->Array.find(c => c.name == name)

    switch byName("retired row degrades to metadata only") {
    | Some(c) =>
      // Not just the payload: the sort value is a timestamp off a row the
      // subscriber may not read, and this row carries one.
      expect((keyOf(c.local, "state"), keyOf(c.local, "sortKeyValue")))->toEqual((None, None))
      expect((keyOf(c.relay, "state"), keyOf(c.relay, "sortKeyValue")))->toEqual((None, None))
      expect((keyOf(c.postgres, "state"), keyOf(c.postgres, "sortKeyValue")))->toEqual((None, None))
      // `Updated`, never `Removed`: the row is not gone. Saying so would be
      // false for an elevated subscriber reading with `includeRetired`, and
      // false again the moment the row is restored.
      expect(keyOf(c.local, "changeKind"))->toEqual(Some(JSON.Encode.string("Updated")))
    | None => expect("retired case missing")->toBe("present")
    }

    // The control that separates "drops a retired row" from "drops any row on a
    // view that declares the flag".
    switch byName("live row with a retirement flag carries the row") {
    | Some(c) =>
      expect(keyOf(c.local, "state")->Option.isSome)->toBe(true)
      expect(keyOf(c.relay, "state")->Option.isSome)->toBe(true)
      expect(keyOf(c.postgres, "state")->Option.isSome)->toBe(true)
    | None => expect("live-with-flag case missing")->toBe("present")
    }
  })
})
