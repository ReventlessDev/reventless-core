open JestGlobals

// A file is played by someone who cannot read the ReScript that plays it, so a
// mistake in it must be named before the run, and its placeholders must give
// ids that differ between repetitions.

let parsed = text =>
  switch Seed_Play.parse(text) {
  | Ok(file) => file
  | Error(message) => failwith(message)
  }

describe("Seed_Play.parse:", () => {
  testSync("reads sends, waits, a pace and whether it repeats", () => {
    let file = parsed(`
pace: 2s
repeatable: true
steps:
  - send: Shop_AddCategory
    args: {categoryId: "cat-{rep}"}
  - waitFor: {field: Shop_CategoriesByIds, ids: ["cat-{rep}"]}
  - send: Shop_Ping
`)
    expect(file.pace)->toEqual(Some("2s"))
    expect(file.repeatable)->toBe(true)
    expect(file.steps->Array.length)->toBe(3)
    switch file.steps[1] {
    | Some(WaitFor(field, ids)) =>
      expect((field, ids))->toEqual(("Shop_CategoriesByIds", ["cat-{rep}"]))
    | _ => failwith("expected a wait")
    }
  })

  testSync("is not repeatable unless it says so", () =>
    expect(parsed(`steps: [{send: A}]`).repeatable)->toBe(false)
  )

  testSync("names the step it cannot read", () => {
    let refused = (text, fragment) =>
      switch Seed_Play.parse(text) {
      | Error(message) => expect(message->String.includes(fragment))->toBe(true)
      | Ok(_) => failwith("expected a refusal")
      }
    refused(`steps: []`, "no steps")
    refused(`steps: [{send: A}, {waitFor: {field: B}}]`, "step 2")
    refused(`steps: [{send: A, args: [1]}]`, "step 1")
  })
})

describe("Seed_Play.fill:", () => {
  testSync("replaces placeholders in every string, nested ones too", () =>
    expect(
      Seed_Play.fill(
        JSON.parseOrThrow(`{"id": "o-{run}-{rep}", "lines": [{"p": "p-{rep}"}], "n": 2}`),
        ~vars=[("run", "R"), ("rep", "3")],
      ),
    )->toEqual(JSON.parseOrThrow(`{"id": "o-R-3", "lines": [{"p": "p-3"}], "n": 2}`))
  )
})
