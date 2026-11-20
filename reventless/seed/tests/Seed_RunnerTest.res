open JestGlobals

// Playing a set more than once is safe only for a set that names new ids each
// time and does not refuse a store that holds data; the runner refuses the rest
// before anything is sent.

let set = (~repeatable=?, ~probeViews=?, ()): Seed_Runner.dataSet => {
  name: "s",
  label: "s",
  seed: async _ => (),
  ?repeatable,
  ?probeViews,
}

describe("Seed_Runner.refuseRepeat:", () => {
  testSync("any set may run once", () =>
    expect(Seed_Runner.refuseRepeat(set(), Times(1)))->toBe(None)
  )

  testSync("a repeatable set may run again", () => {
    expect(Seed_Runner.refuseRepeat(set(~repeatable=true, ()), Forever))->toBe(None)
    expect(Seed_Runner.refuseRepeat(set(~repeatable=true, ~probeViews=[], ()), Times(3)))->toBe(
      None,
    )
  })

  testSync("a set that is not repeatable, or wants an empty store, may not", () => {
    expect(Seed_Runner.refuseRepeat(set(), Times(2))->Option.isSome)->toBe(true)
    expect(
      Seed_Runner.refuseRepeat(
        set(~repeatable=true, ~probeViews=["V"], ()),
        Forever,
      )->Option.isSome,
    )->toBe(true)
  })
})
