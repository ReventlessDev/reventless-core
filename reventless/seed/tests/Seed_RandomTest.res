open JestGlobals

// `Seed_Random` exists so that two seed runs against a fresh store produce the
// same data — that is what makes a seeded store usable as a screenshot baseline
// or a comparison target. Its correctness is therefore not "looks random" but
// "repeats exactly, and stays inside the bounds it advertises".
//
// The suite is written around that: every case below fails for a generator that
// is subtly non-reproducible or that walks out of its range, and none of them
// would notice a change of algorithm that kept both properties.

describe("Seed_Random:", () => {
  let take = (~seed, ~n) => {
    let r = Seed_Random.make(~seed)
    Array.make(~length=n, 0.0)->Array.map(_ => Seed_Random.float(r))
  }

  describe("reproducibility — the reason this module exists:", () => {
    testSync("the same seed replays the same sequence", () =>
      expect(take(~seed=42, ~n=25))->toEqual(take(~seed=42, ~n=25))
    )

    // Without this, a generator that returned a constant would satisfy the
    // case above and nothing else in the suite would catch it.
    testSync("different seeds diverge", () =>
      expect(take(~seed=42, ~n=25) == take(~seed=43, ~n=25))->toBe(false)
    )

    testSync("a fresh generator does not continue the previous one", () => {
      let r = Seed_Random.make(~seed=7)
      let first = Seed_Random.float(r)
      let _ = Seed_Random.float(r)
      expect(Seed_Random.float(Seed_Random.make(~seed=7)))->toEqual(first)
    })
  })

  describe("float stays a unit interval:", () => {
    // mulberry32's last step is a signed 32-bit value folded back to unsigned.
    // Get that fold wrong and roughly half the draws come out negative, which
    // every consumer below (int, pick, sampleWeighted) silently mis-scales.
    testSync("every draw is in [0, 1)", () =>
      expect(take(~seed=99, ~n=500)->Array.every(f => f >= 0.0 && f < 1.0))->toBe(true)
    )

    testSync("and the draws are not all the same value", () => {
      let draws = take(~seed=99, ~n=100)
      expect(draws->Array.some(f => f != draws->Array.getUnsafe(0)))->toBe(true)
    })
  })

  describe("int is inclusive on both ends, as documented:", () => {
    let draws = (~min, ~max, ~n) => {
      let r = Seed_Random.make(~seed=5)
      Array.make(~length=n, 0)->Array.map(_ => Seed_Random.int(r, ~min, ~max))
    }

    testSync("never escapes the range", () =>
      expect(draws(~min=3, ~max=7, ~n=500)->Array.every(i => i >= 3 && i <= 7))->toBe(true)
    )

    // The documented contract is "inclusive on both ends"; an off-by-one in the
    // `max - min + 1` scaling shows up as a bound that is never drawn.
    testSync("reaches both bounds", () => {
      let d = draws(~min=3, ~max=7, ~n=500)
      expect((d->Array.includes(3), d->Array.includes(7)))->toEqual((true, true))
    })

    testSync("a single-value range is that value", () =>
      expect(draws(~min=4, ~max=4, ~n=10)->Array.every(i => i == 4))->toBe(true)
    )
  })

  describe("pick:", () => {
    testSync("returns None for an empty array", () =>
      expect(Seed_Random.make(~seed=1)->Seed_Random.pick([]))->toEqual(None)
    )

    testSync("always lands on a member", () => {
      let r = Seed_Random.make(~seed=2)
      let xs = ["a", "b", "c", "d"]
      let hits = Array.make(~length=200, "")->Array.map(_ =>
        r->Seed_Random.pickOr(~fallback="MISS", xs)
      )
      expect(hits->Array.every(h => xs->Array.includes(h)))->toBe(true)
    })

    testSync("pickOr falls back only when there is nothing to pick", () =>
      expect(Seed_Random.make(~seed=3)->Seed_Random.pickOr(~fallback="fallback", []))->toBe(
        "fallback",
      )
    )
  })

  describe("sampleWeighted is without replacement:", () => {
    let equal = xs => xs->Array.map(x => (x, 1.0))

    // The documented shuffle use: equal weights, count = length. If sampling
    // ever replaced instead of removing, duplicates would appear here.
    testSync("count = length yields a permutation, not a multiset", () => {
      let xs = ["a", "b", "c", "d", "e"]
      let out = Seed_Random.make(~seed=11)->Seed_Random.sampleWeighted(equal(xs), ~count=5)
      let sorted = out->Array.toSorted(String.compare)
      expect((out->Array.length, sorted))->toEqual((5, ["a", "b", "c", "d", "e"]))
    })

    testSync("count < length returns exactly count distinct items", () => {
      let xs = ["a", "b", "c", "d", "e"]
      let out = Seed_Random.make(~seed=12)->Seed_Random.sampleWeighted(equal(xs), ~count=3)
      let distinct = Set.fromArray(out)->Set.size
      expect((out->Array.length, distinct))->toEqual((3, 3))
    })

    testSync("count > length clamps to the pool", () =>
      expect(
        Seed_Random.make(~seed=13)
        ->Seed_Random.sampleWeighted(equal(["a", "b"]), ~count=99)
        ->Array.length,
      )->toBe(2)
    )

    testSync("a zero-weight entry is never chosen while others remain", () => {
      let out =
        Seed_Random.make(~seed=14)->Seed_Random.sampleWeighted(
          [("never", 0.0), ("a", 1.0), ("b", 1.0)],
          ~count=2,
        )
      expect(out->Array.includes("never"))->toBe(false)
    })

    testSync("is reproducible for a given seed", () => {
      let run = () =>
        Seed_Random.make(~seed=15)->Seed_Random.sampleWeighted(
          equal(["a", "b", "c", "d", "e", "f"]),
          ~count=4,
        )
      expect(run())->toEqual(run())
    })
  })

  describe("zipfWeights skews toward the head:", () => {
    let weights = Seed_Random.zipfWeights(["a", "b", "c", "d", "e"], ~exponent=1.1)

    testSync("keeps every item, in order", () =>
      expect(weights->Array.map(((item, _)) => item))->toEqual(["a", "b", "c", "d", "e"])
    )

    testSync("weight decreases monotonically with rank", () => {
      let ws = weights->Array.map(((_, w)) => w)
      let decreasing =
        ws->Array.everyWithIndex((w, i) => i == 0 || w < ws->Array.getUnsafe(i - 1))
      expect(decreasing)->toBe(true)
    })

    testSync("the leader is clear — first outweighs last several times over", () => {
      let first = weights->Array.get(0)->Option.mapOr(0.0, ((_, w)) => w)
      let last = weights->Array.get(4)->Option.mapOr(0.0, ((_, w)) => w)
      expect(first > last *. 3.0)->toBe(true)
    })
  })
})
