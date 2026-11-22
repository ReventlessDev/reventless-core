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
    | Some(WaitFor({field, ids})) =>
      expect((field, ids))->toEqual(("Shop_CategoriesByIds", ["cat-{rep}"]))
    | _ => failwith("expected a wait")
    }
  })

  testSync("reads whom a step acts as, and refuses an empty one", () => {
    let file = parsed(`
steps:
  - send: Shop_PlaceOrder
    as: ada
  - waitFor: {field: Shop_OrdersByIds, ids: ["o-1"]}
    as: ada
  - send: Shop_Ping
`)
    expect((
      file.steps->Array.map(
        step =>
          switch step {
          | Send({?as_}) | WaitFor({?as_}) | Read({?as_}) => as_
          },
      ),
      Seed_Play.people(file),
      Seed_Play.parse(`steps: [{send: A, as: ""}]`)->Result.isError,
    ))->toEqual(([Some("ada"), Some("ada"), None], ["ada"], true))
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

// A step that says what it expects turns the file into a play that can fail: it is refused
// where it would write into production, it names the step that went otherwise, and the same
// file names a person's id wherever it is played.
describe("Seed_Play expectations:", () => {
  let file = parsed(`
steps:
  - id: order
    send: Shop_PlaceOrder
    as: ada
    args: {orderId: "o-{run}", ownerId: "{id:ada}"}
    expect: accepted
    row: {view: Shop_OrdersByIds, key: "o-{run}", has: {state: Placed, placedAt: "{any}"}}
  - id: order-again
    send: Shop_PlaceOrder
    as: ada
    args: {orderId: "o-{run}"}
    expect: {refused: OrderAlreadyPlaced}
  - send: Shop_Ping
    args: {by: "{id:ben}"}
`)

  testSync("reads what a step expects, the row it reads and its name", () =>
    switch (file.steps[0], file.steps[1], file.steps[2]) {
    | (
        Some(Send({id: ?first, expect: ?accepted, row: ?Some(r)})),
        Some(Send({expect: ?refused})),
        Some(Send({?id, expect: ?third})),
      ) =>
      expect((
        first,
        accepted,
        (r.view, r.key, r.has->Dict.keysToArray),
        refused,
        (id, third),
        Seed_Play.stepName(file, 2),
      ))->toEqual((
        Some("order"),
        Some(Seed_Client.Accepted),
        ("Shop_OrdersByIds", "o-{run}", ["state", "placedAt"]),
        Some(Seed_Client.Refused("OrderAlreadyPlaced")),
        (None, None),
        "step 3",
      ))
    | _ => failwith("expected three sends")
    }
  )

  testSync("reads a step that only reads a row, as its person", () => {
    let read = parsed(`
steps:
  - {id: ada-looks, as: ada, row: {view: Shop_OrdersByIds, key: "o-{run}", has: {ownerId: "{id:ada}"}}}
`)
    switch read.steps[0] {
    | Some(Read({row, ?as_, ?id})) =>
      expect((
        (row.view, row.key, as_, id),
        Seed_Play.expects(read),
        Seed_Play.people(read),
        Seed_Play.marked(read),
        Seed_Play.stepName(read, 0),
      ))->toEqual((
        ("Shop_OrdersByIds", "o-{run}", Some("ada"), Some("ada-looks")),
        true,
        ["ada"],
        true,
        "ada-looks",
      ))
    | _ => failwith("expected a step that reads a row")
    }
  })

  testSync("reads a step that may meet what an earlier play made", () =>
    switch parsed(`steps: [{send: A, expect: {acceptedOr: AlreadyThere}}]`).steps[0] {
    | Some(Send({expect: ?e})) => expect(e)->toEqual(Some(Seed_Client.AcceptedOr("AlreadyThere")))
    | _ => failwith("expected a send")
    }
  )

  testSync("names what it cannot read", () =>
    expect(
      [
        `steps: [{send: A, expect: maybe}]`,
        `steps: [{send: A, expect: {refused: ""}}]`,
        `steps: [{send: A, row: {view: V}}]`,
        `steps: [{send: A, row: {view: V, key: k, has: [1]}}]`,
        `steps: [{as: ada, row: {view: V}}]`,
        `steps: [{send: A, expect: {refused: X, acceptedOr: X}}]`,
      ]->Array.map(text => Seed_Play.parse(text)->Result.isError),
    )->toEqual([true, true, true, true, true, true])
  )

  testSync("knows a play that expects, the people whose ids it names, and its mark", () =>
    expect((
      Seed_Play.expects(file),
      Seed_Play.expects(parsed(`steps: [{send: A}]`)),
      Seed_Play.idNames(file),
      Seed_Play.people(file),
      Seed_Play.marked(file),
      Seed_Play.marked(parsed(`steps: [{send: A, args: {id: "o-1"}, expect: accepted}]`)),
    ))->toEqual((true, false, ["ada", "ben"], ["ada", "ben"], true, false))
  )

  testSync("is played only where the platform says it is not production", () =>
    expect([
      Seed_Play.refusePurpose(~purpose=Some("dev"), ~label="alpha")->Option.map(_ => true),
      Seed_Play.refusePurpose(~purpose=Some("local"), ~label="local")->Option.map(_ => true),
      Seed_Play.refusePurpose(~purpose=Some("production"), ~label="main")->Option.map(
        m => m->String.includes("production"),
      ),
      Seed_Play.refusePurpose(~purpose=None, ~label="beta")->Option.map(
        m => m->String.includes("environmentPurpose"),
      ),
    ])->toEqual([None, None, Some(true), Some(true)])
  )

  testSync("says an id that carries neither the run's mark nor a person's id", () =>
    expect(
      Seed_Play.unmarkedIds(
        Seed_Types.mutation(
          "Shop_PlaceOrder",
          [
            ("orderId", Id("o-{run}")),
            ("ownerId", Id("{id:ada}")),
            ("productId", Id("p-1")),
            ("lines", List([Object([("productId", Id("p-2"))])])),
            ("note", String("plain")),
          ],
        ),
      ),
    )->toEqual(["Shop_PlaceOrder.productId \"p-1\"", "Shop_PlaceOrder.lines[0].productId \"p-2\""])
  )
})

// The player against a fake API: it answers each document by what the document asks, as the
// platform would, so what the player sends and how it reads the answers is what is tested.
let realFetch: unknown = %raw(`globalThis.fetch`)
let restoreFetch: unknown => unit = %raw(`function (f) { globalThis.fetch = f }`)
let fakeApi: (string => JSON.t) => unit = %raw(`function (answer) {
  globalThis.fetch = async (_url, init) => {
    const body = answer(JSON.parse(init.body).query);
    return { ok: true, status: 200, json: async () => body };
  };
}`)

let commands: Seed_Commands.t = {
  mutations: Dict.fromArray([
    (
      "Shop_PlaceOrder",
      [{Seed_Commands.name: "orderId", typ: NonNull(Named("ID")), hasDefault: false}],
    ),
  ]),
  kinds: Dict.fromArray([("ID", Seed_Commands.Scalar)]),
}

/** A shop that places an order once and refuses it again; its view shows an order only from
    the second time it is read, as a view lags its command. */
let shop = () => {
  let placed = []
  let reads = ref(0)
  let sent = []
  fakeApi(query => {
    if query->String.startsWith("mutation") {
      sent->Array.push(query)
      let id = switch query->String.match(/orderId: "([^"]*)"/) {
      | Some([_, Some(id)]) => id
      | _ => ""
      }
      let r = if placed->Array.includes(id) {
        `{"__typename": "CommandRejected", "errorCode": "OrderAlreadyPlaced", "errorDetail": "${id}"}`
      } else {
        placed->Array.push(id)
        `{"__typename": "CommandAccepted", "eventCount": 1}`
      }
      JSON.parseOrThrow(`{"data": {"r": ${r}}}`)
    } else {
      reads := reads.contents + 1
      let rows =
        reads.contents > 1 && placed != []
          ? `[{"state": "Placed", "placedAt": "2026-11-22T10:00:00Z"}]`
          : `[]`
      JSON.parseOrThrow(`{"data": {"Shop_OrdersByIds": ${rows}}}`)
    }
  })
  sent
}

let client = () => Seed_Client.make(~config={endpoint: "http://shop.test/graphql"})

let play = (text, ~vars=[("run", "R")], ~results=[], ~rowTimeoutMs=2000) =>
  Seed_Play.playOnce(parsed(text), ~commands, ~client=client(), ~vars, ~results, ~rowTimeoutMs)

describe("Seed_Play.playOnce, expecting:", () => {
  afterEach(() => restoreFetch(realFetch))

  testPromise("plays a refusal it expects, and reads the row once it comes", async () => {
    let _ = shop()
    let results = []
    await play(
      `
steps:
  - id: order
    send: Shop_PlaceOrder
    args: {orderId: "o-{run}"}
    expect: accepted
    row: {view: Shop_OrdersByIds, key: "o-{run}", has: {state: Placed, placedAt: "{any}"}}
  - id: order-again
    send: Shop_PlaceOrder
    args: {orderId: "o-{run}"}
    expect: {refused: OrderAlreadyPlaced}
`,
      ~results,
    )
    let field = (j: JSON.t, k) =>
      switch j {
      | Object(d) => d->Dict.get(k)
      | _ => None
      }
    expect((
      results->Array.map(r => field(r, "step")),
      results
      ->Array.get(0)
      ->Option.flatMap(r => field(r, "row"))
      ->Option.flatMap(r => field(r, "matches")),
      results->Array.get(1)->Option.flatMap(r => field(r, "came")),
    ))->toEqual((
      [Some(JSON.String("order")), Some(JSON.String("order-again"))],
      Some(JSON.Boolean(true)),
      Some(JSON.parseOrThrow(`{"accepted": false, "code": "OrderAlreadyPlaced", "detail": "o-R"}`)),
    ))
  })

  testPromise("stops at the step whose answer differs, and says what came", async () => {
    let _ = shop()
    let results = []
    let stopped = try {
      await play(
        `
steps:
  - {id: order, send: Shop_PlaceOrder, args: {orderId: "o-{run}"}, expect: accepted}
  - {id: order-again, send: Shop_PlaceOrder, args: {orderId: "o-{run}"}, expect: accepted}
  - {id: never, send: Shop_PlaceOrder, args: {orderId: "o-other"}, expect: accepted}
`,
        ~results,
      )
      None
    } catch {
    | Seed_Types.Failed(message) => Some(message)
    }
    expect((stopped, results->Array.length))->toEqual((
      Some(
        "order-again: Shop_PlaceOrder was expected to be accepted, and was refused with OrderAlreadyPlaced (o-R)",
      ),
      2,
    ))
  })

  testPromise("says a row that never comes", async () => {
    fakeApi(
      query =>
        query->String.startsWith("mutation")
          ? JSON.parseOrThrow(`{"data": {"r": {"__typename": "CommandAccepted"}}}`)
          : JSON.parseOrThrow(`{"data": {"Shop_OrdersByIds": []}}`),
    )
    let stopped = try {
      await play(
        `steps: [{id: order, send: Shop_PlaceOrder, args: {orderId: "o-{run}"}, row: {view: Shop_OrdersByIds, key: "o-{run}"}}]`,
        ~rowTimeoutMs=300,
      )
      None
    } catch {
    | Seed_Types.Failed(message) => Some(message)
    }
    expect(
      stopped->Option.map(m => m->String.startsWith("order: Shop_OrdersByIds shows no row o-R")),
    )->toEqual(Some(true))
  })

  testPromise("reads a row on a step that sends nothing, as the step's person", async () => {
    let _ = shop()
    let results = []
    let readers = []
    let _ = await Seed_Play.playOnce(
      parsed(`
steps:
  - {id: order, send: Shop_PlaceOrder, args: {orderId: "o-{run}"}, expect: accepted}
  - {id: ada-looks, as: ada, row: {view: Shop_OrdersByIds, key: "o-{run}", has: {state: Placed}}}
`),
      ~commands,
      ~client=client(),
      ~clientOf=async name => {
        readers->Array.push(name)
        client()
      },
      ~vars=[("run", "R")],
      ~results,
      ~rowTimeoutMs=2000,
    )
    let field = (j: JSON.t, k) =>
      switch j {
      | Object(d) => d->Dict.get(k)
      | _ => None
      }
    expect((
      readers,
      results->Array.get(1)->Option.flatMap(r => field(r, "as")),
      results
      ->Array.get(1)
      ->Option.flatMap(r => field(r, "row"))
      ->Option.flatMap(r => field(r, "matches")),
    ))->toEqual((["ada"], Some(JSON.String("ada")), Some(JSON.Boolean(true))))
  })

  testPromise("sends a person's id as the one their account carries", async () => {
    let sent = shop()
    await play(
      `steps: [{send: Shop_PlaceOrder, args: {orderId: "o-{id:ada}"}, expect: accepted}]`,
      ~vars=[("run", "R"), ("id:ada", "sub-123")],
    )
    expect(sent->Array.map(q => q->String.includes(`orderId: "o-sub-123"`)))->toEqual([true])
  })
})
