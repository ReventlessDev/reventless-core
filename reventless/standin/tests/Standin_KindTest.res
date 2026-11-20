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
let tick = async (~seed, ids) => {
  let kind = ChargerStandin.kind
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
})
