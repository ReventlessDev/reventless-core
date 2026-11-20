open JestGlobals

// A twin's values come from its own generator, seeded by the run's seed, its
// kind and its id: one seed sends the same values, whatever order twins fire in.

let rows = ids =>
  ids->Array.map(id => (
    id,
    JSON.parseOrThrow(`{"chargerId": "${id}", "name": "${id}", "maxPowerKw": 22}`),
  ))

let at = Date.fromString("2026-11-20T10:00:00.000Z")

/** The bodies one meter tick sends, per twin, from a fresh kind seeded `seed`. */
let tick = async (~seed, ~rates=Standin.Kind.exact, ids) => {
  let kind = ChargerStandin.kind
  kind.setRates(rates)
  let _ = kind.sync(~seed, [])
  let _ = kind.sync(~seed, rows(ids))
  let sent = []
  await kind.fire(~timer="meter", ~now=at, async (~kind as _, ~id, send) =>
    sent->Array.push((id, send.body))
  )
  sent->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
}

describe("Standin.Kind:", () => {
  test("one seed sends the same values; another seed others", async () => {
    let first = await tick(~seed=7, ["bay-1", "bay-2"])
    expect(first->Array.length)->toBe(2)
    expect(first)->toEqual(await tick(~seed=7, ["bay-2", "bay-1"]))
    expect(first == (await tick(~seed=8, ["bay-1", "bay-2"])))->toBe(false)
  })

  testSync("a row that appears gets a twin, a row that leaves loses it", () => {
    let kind = ChargerStandin.kind
    let _ = kind.sync(~seed=1, [])
    expect(kind.sync(~seed=1, rows(["a", "b"])))->toEqual((["a", "b"], []))
    expect(kind.sync(~seed=1, rows(["b", "c"])))->toEqual((["c"], ["a"]))
    expect(kind.twins()->Array.map(((id, _)) => id))->toEqual(["b", "c"])
  })

  test("a message by hand is built from the twin's state, or refused by name", async () => {
    let kind = ChargerStandin.kind
    let _ = kind.sync(~seed=1, [])
    let _ = kind.sync(~seed=1, rows(["a"]))
    let sent = []
    let to = async (~kind as _, ~id as _, send: Standin.send) => sent->Array.push(send)
    let fields = Dict.fromArray([("energyWh", JSON.Encode.float(5.))])
    expect(await kind.byHand(~id="a", ~message="reading", ~fields, ~now=at, to))->toEqual(Ok())
    expect(sent->Array.map(s => s.slice))->toEqual(["MeterCharger"])
    expect(
      (await kind.byHand(~id="z", ~message="reading", ~fields, ~now=at, to))->Result.isError,
    )->toBe(true)
    expect(
      (await kind.byHand(~id="a", ~message="nope", ~fields, ~now=at, to))->Result.isError,
    )->toBe(true)
  })

  test(
    "misbehaviour repeats itself under one seed, apart from the values the kind draws",
    async () => {
      let calm = await tick(
        ~seed=7,
        ~rates={...Standin.Kind.exact, repeats: 0.5},
        ["bay-1", "bay-2"],
      )
      expect(calm)->toEqual(
        await tick(~seed=7, ~rates={...Standin.Kind.exact, repeats: 0.5}, ["bay-1", "bay-2"]),
      )
      let once = await tick(~seed=7, ["bay-1", "bay-2"])
      expect(once->Array.every(sent => calm->Array.some(other => other == sent)))->toBe(true)
    },
  )

  test("repeats send twice; late sends arrive a tick later", async () => {
    let kind = ChargerStandin.kind
    let run = async (rates, ticks) => {
      kind.setRates(rates)
      let _ = kind.sync(~seed=1, [])
      let _ = kind.sync(~seed=1, rows(["a"]))
      let sent = []
      for i in 1 to ticks {
        await kind.fire(
          ~timer="meter",
          ~now=at,
          async (~kind as _, ~id as _, send) =>
            sent->Array.push((i, send.body->ReventlessSeed.Seed.Commands.str("readingId"))),
        )
      }
      sent
    }
    let twice = await run({...Standin.Kind.exact, repeats: 1.}, 1)
    expect(twice->Array.length)->toBe(2)
    expect(twice[0] == twice[1])->toBe(true)
    let late = await run({...Standin.Kind.exact, late: 1.}, 2)
    switch late {
    | [(2, first)] => expect(first->Option.getOr("")->String.endsWith("-1"))->toBe(true)
    | other =>
      failwith(
        `expected the first reading in the second tick, got ${other->Array.length->Int.toString}`,
      )
    }
  })

  test("a silence on purpose shows in the twin, and ends", async () => {
    let kind = ChargerStandin.kind
    kind.setRates(Standin.Kind.exact)
    let _ = kind.sync(~seed=1, [])
    let _ = kind.sync(~seed=1, rows(["a"]))
    expect(kind.silence(~id="a", ~ticks=2))->toEqual(Ok())
    let silent = () =>
      kind.twins()
      ->Array.get(0)
      ->Option.flatMap(((_, t)) => t->ReventlessSeed.Seed.Commands.get("silent"))
    expect(silent())->toEqual(Some(JSON.parseOrThrow(`{"ticks": 2, "onPurpose": true}`)))
    let sent = ref(0)
    let to = async (~kind as _, ~id as _, _) => sent := sent.contents + 1
    await kind.fire(~timer="meter", ~now=at, to)
    expect(sent.contents)->toBe(0)
    await kind.fire(~timer="meter", ~now=at, to)
    expect(silent())->toEqual(None)
    expect(kind.silence(~id="z", ~ticks=1)->Result.isError)->toBe(true)
  })

  test("a drifting twin writes its own time, off by whole seconds", async () => {
    let kind = ChargerStandin.kind
    kind.setRates({...Standin.Kind.exact, drift: 1.})
    let _ = kind.sync(~seed=1, [])
    let _ = kind.sync(~seed=1, rows(["a"]))
    let drift = switch kind.twins()->Array.get(0) {
    | Some((_, t)) =>
      switch t->ReventlessSeed.Seed.Commands.get("driftSeconds") {
      | Some(Number(s)) => s
      | _ => 0.
      }
    | None => 0.
    }
    expect(drift != 0. && Math.abs(drift) <= 30.)->toBe(true)
    let written = ref("")
    await kind.fire(
      ~timer="meter",
      ~now=at,
      async (~kind as _, ~id as _, send) =>
        written := send.body->ReventlessSeed.Seed.Commands.str("at")->Option.getOr(""),
    )
    expect(Date.fromString(written.contents)->Date.getTime -. at->Date.getTime)->toBe(
      drift *. 1000.,
    )
  })
})
