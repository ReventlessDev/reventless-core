// Parity of the live-update change descriptor across its three implementations:
//
//   - LocalStateChangeDescriptor      (reventless-local, both backends)
//   - StateTopic_AppSync_Ops          (DynamoDB stream relay)
//   - StateTopicPublish.mjs           (Postgres projection-side publisher)
//
// They share only spec's `Lifecycle.Trail.toRead` — the relay module stays
// Pulumi-free so a core import can't pull deploy-time code into its Lambda graph —
// which makes drift the standing risk: three sites, one wire format, and a browser
// that cannot tell which one produced a frame. This test is the guard.
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
    expect(cases->Array.length)->toBe(12)
    cases->Array.forEach(
      c => {
        expect((c.name, c.relay))->toEqual((c.name, c.local))
        expect((c.name, c.postgres))->toEqual((c.name, c.local))
      },
    )
  })

  testAsync("a save carries the row, a delete carries none", async () => {
    let cases = await buildAll()
    let stateOf = (d: JSON.t) => d->JSON.Decode.object->Option.flatMap(o => o->Dict.get("state"))
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

  // The state form, where the predicate is membership rather than equality. Both
  // states are asserted, so an implementation comparing against only the first
  // member of the set fails on the second — which is the shape of mistake a set
  // invites and a single value could not.
  testAsync("a row in any retired state publishes as metadata only", async () => {
    let cases = await buildAll()
    let keyOf = (d: JSON.t, k) => d->JSON.Decode.object->Option.flatMap(o => o->Dict.get(k))
    let byName = name => cases->Array.find(c => c.name == name)

    [
      "row in the first retired state degrades to metadata only",
      "row in the second retired state degrades to metadata only",
    ]->Array.forEach(
      name =>
        switch byName(name) {
        | Some(c) =>
          expect((name, keyOf(c.local, "state"), keyOf(c.local, "sortKeyValue")))->toEqual((
            name,
            None,
            None,
          ))
          expect((name, keyOf(c.relay, "state"), keyOf(c.relay, "sortKeyValue")))->toEqual((
            name,
            None,
            None,
          ))
          expect((name, keyOf(c.postgres, "state"), keyOf(c.postgres, "sortKeyValue")))->toEqual((
            name,
            None,
            None,
          ))
        | None => expect(name ++ " missing")->toBe("present")
        },
    )

    // The control for the state form: a live state on the same lifecycle, so an
    // implementation dropping every row of a view that declares states fails.
    switch byName("row in a live state carries the row") {
    | Some(c) =>
      expect((
        keyOf(c.local, "state")->Option.isSome,
        keyOf(c.relay, "state")->Option.isSome,
        keyOf(c.postgres, "state")->Option.isSome,
      ))->toEqual((true, true, true))
    | None => expect("live-state case missing")->toBe("present")
    }
  })

  // A trail's dates travel as a GraphQL read returns them, so a row updated live
  // replaces the dates it was fetched with; the stored attributes stay behind.
  testAsync("a row with a trail carries its dates as a read does, everywhere", async () => {
    let cases = await buildAll()
    let stateOf = (d: JSON.t) =>
      d
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("state"))
      ->Option.flatMap(JSON.Decode.object)
    switch cases->Array.find(c => c.name == "row with a trail carries its dates as a read does") {
    | Some(c) =>
      [c.local, c.relay, c.postgres]->Array.forEach(
        d =>
          switch stateOf(d) {
          | Some(state) =>
            expect(
              state
              ->Dict.keysToArray
              ->Array.filter(
                k =>
                  k->String.startsWith("_entered_") ||
                  k->String.startsWith("_visits_") ||
                  k == "_trail",
              ),
            )->toEqual([])
            expect(state->Dict.get("trailEntered"))->toEqual(
              Some(
                JSON.parseOrThrow(`{"placed":{"latest":"2026-03-02T11:00:00Z","first":"2026-03-02T09:00:00Z","visits":2},"shipped":null,"cancelled":{"latest":"2026-03-02T10:00:00Z","first":"2026-03-02T10:00:00Z","visits":1},"current":"2026-03-02T11:00:00Z"}`),
              ),
            )
          | None => expect("trail row's state missing")->toBe("present")
          },
      )
    | None => expect("trail case missing")->toBe("present")
    }
  })

  // The relay has no registry: it reads each table's trail from the map the deploy writes.
  testSync("the relay reads the trail map the deploy writes", () => {
    let reading: Reventless.Lifecycle.Trail.reading = {
      field: "trail",
      states: ["Placed", "Shipped"],
    }
    let written =
      Dict.fromArray([("Orders-1", reading->Reventless.Lifecycle.Trail.readingToJson)])
      ->JSON.Encode.object
      ->JSON.stringify
    expect(StateTopic_AppSync_Ops.parseTrailMap(written))->toEqual(
      Dict.fromArray([("Orders-1", reading)]),
    )
  })
})
