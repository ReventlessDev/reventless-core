open JestGlobals

// A pace is what lets one run play faster or slower unedited, so what matters is
// that it reads the forms it advertises, refuses the rest before a run starts,
// and that a random pace repeats exactly.

let gaps = (pace: Seed_Pace.t, ~n) => Array.fromInitializer(~length=n, i => pace.gapMs(i))

let parsed = text =>
  switch Seed_Pace.parse(text) {
  | Ok(pace) => pace
  | Error(message) => failwith(message)
  }

describe("Seed_Pace.parse:", () => {
  testSync("a gap waits that long between sends, and not before the first", () => {
    expect(gaps(parsed("2s"), ~n=3))->toEqual([0, 2000, 2000])
    expect(gaps(parsed("500ms"), ~n=2))->toEqual([0, 500])
    expect(gaps(parsed("1.5min"), ~n=2))->toEqual([0, 90000])
  })

  testSync("a rate spaces sends evenly", () => {
    expect(gaps(parsed("30/min"), ~n=2))->toEqual([0, 2000])
    expect(gaps(parsed("4/s"), ~n=2))->toEqual([0, 250])
  })

  testSync("a random pace repeats itself, varies, and keeps its mean", () => {
    let a = gaps(parsed("1/s~"), ~n=400)
    expect(a)->toEqual(gaps(parsed("1/s~"), ~n=400))
    expect(a->Array.some(g => g != 1000))->toBe(true)
    let mean = Int.toFloat(a->Array.reduce(0, (x, y) => x + y)) /. 399.
    expect(mean > 800. && mean < 1200.)->toBe(true)
    expect(a->Array.every(g => g <= 10000))->toBe(true)
  })

  testSync("refuses what it cannot read", () =>
    ["", "fast", "2", "0s", "-1s", "3/fortnight", "2s/min"]->Array.forEach(
      text => expect(Seed_Pace.parse(text)->Result.isError)->toBe(true),
    )
  )

  testSync("the total of a fixed pace is its gaps", () =>
    expect(parsed("2s")->Seed_Pace.totalMs(~count=4))->toBe(6000)
  )
})
