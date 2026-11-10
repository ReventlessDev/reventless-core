open JestGlobals

// How far an app's catalogues are translated, and what stops a language's release.

let hash = (s: string) => `#${s}`

let layer = (name, ~catalogues, ~marks=dict{}): CatalogueStatus.layer => {
  name,
  catalogues,
  marks,
}

let ordering = layer(
  "ordering",
  ~catalogues=dict{
    "en": dict{
      "Ordering.Orders.plural": "Orders",
      "Ordering.Orders.count": "{count, plural, one {# order} other {# orders}}",
      "Ordering.PlaceOrder.name": "Place Order",
      "Ordering.CancelOrder.error.OrderAlreadyShipped": "Order already shipped",
    },
    "de": dict{
      "Ordering.Orders.plural": "Bestellungen",
      "Ordering.Orders.count": "{count, plural, one {# Bestellung} other {# Bestellungen}}",
      "Ordering.PlaceOrder.name": "Bestellung aufgeben",
      "Ordering.Gone.name": "Weg",
    },
  },
  ~marks=dict{
    "de": dict{
      "Ordering.Orders.plural": {CatalogueStatus.source: "#Orders", confirmed: true},
      "Ordering.PlaceOrder.name": {source: "#Place an Order", confirmed: false},
    },
  },
)

// The app overrides one English text and adds a key of its own.
let app = layer(
  "app",
  ~catalogues=dict{
    "en": dict{"Ordering.Orders.plural": "Orders", "App.title.name": "Shop"},
    "de-x-du": dict{"App.title.name": "Dein Laden"},
  },
)

let layers = [ordering, app]

let statusOf = (~releases=dict{}, language) =>
  CatalogueStatus.status(layers, ~releases, ~hash)->Array.find(s => s.language == language)

let stateOf = (language, key): option<(CatalogueStatus.state, bool)> =>
  statusOf(language)
  ->Option.flatMap(s => s.keys->Array.find(k => k.key == key))
  ->Option.map(k => (k.state, k.unmarked))

describe("CatalogueStatus.placeholders", () => {
  testSync("names a message's arguments once each, sorted", () =>
    expect(
      CatalogueStatus.placeholders(
        "{name} ordered {count, plural, offset:1 =0 {nothing} one {# {item}} other {# items}} on {day, date, short}",
      ),
    )->toEqual(Ok(["count", "day", "item", "name"]))
  )

  testSync("reads quoted braces as text", () =>
    expect(CatalogueStatus.placeholders("Use '{name}' literally, it''s {real}"))->toEqual(
      Ok(["real"]),
    )
  )

  testSync(
    "refuses an unclosed brace, a stray one, a plural without other and an unknown type",
    () =>
      expect(
        [
          "Hello {name",
          "Hello name}",
          "{count, plural, one {# order}}",
          "{when, weekday}",
        ]->Array.map(t => CatalogueStatus.placeholders(t)->Result.isError),
      )->toEqual([true, true, true, true]),
  )
})

describe("CatalogueStatus.status", () => {
  testSync("lists the source first, then every language a layer or languages.json names", () =>
    expect(
      CatalogueStatus.status(layers, ~releases=dict{"fr": CatalogueStatus.Draft}, ~hash)->Array.map(
        s => s.language,
      ),
    )->toEqual(["en", "de", "de-x-du", "fr"])
  )

  testSync("a key reviewed against today's English is confirmed", () =>
    expect(stateOf("de", "Ordering.Orders.plural"))->toEqual(
      Some((CatalogueStatus.Confirmed, false)),
    )
  )

  testSync("a key marked against an English that has changed is stale", () =>
    expect(stateOf("de", "Ordering.PlaceOrder.name"))->toEqual(Some((CatalogueStatus.Stale, false)))
  )

  testSync("a translated key never marked is proposed, and says it is unmarked", () =>
    expect(stateOf("de", "Ordering.Orders.count"))->toEqual(Some((CatalogueStatus.Proposed, true)))
  )

  testSync("a key no layer translates is missing", () =>
    expect(stateOf("de", "Ordering.CancelOrder.error.OrderAlreadyShipped"))->toEqual(
      Some((CatalogueStatus.Missing, false)),
    )
  )

  testSync("a register variant falls back to its base language", () =>
    expect((
      stateOf("de-x-du", "App.title.name"),
      stateOf("de-x-du", "Ordering.Orders.plural"),
      stateOf("de-x-du", "Ordering.CancelOrder.error.OrderAlreadyShipped"),
    ))->toEqual((
      Some((CatalogueStatus.Proposed, true)),
      Some((CatalogueStatus.Confirmed, false)),
      Some((CatalogueStatus.Missing, false)),
    ))
  )

  testSync("counts per layer, a key belonging to the first layer whose English has it", () =>
    expect(statusOf("de")->Option.map(s => s.layers))->toEqual(
      Some([
        (
          "ordering",
          {CatalogueStatus.total: 4, confirmed: 1, proposed: 1, missing: 1, stale: 1, unmarked: 1},
        ),
        (
          "app",
          {CatalogueStatus.total: 1, confirmed: 0, proposed: 0, missing: 1, stale: 0, unmarked: 0},
        ),
      ]),
    )
  )

  testSync("reports a translated key no English has", () =>
    expect(statusOf("de")->Option.map(s => s.unknown))->toEqual(Some(["Ordering.Gone.name"]))
  )

  testSync("ready is confirmed and proposed; the percentage rounds down", () =>
    expect(
      statusOf("de")->Option.map(
        s => (CatalogueStatus.ready(s.all), CatalogueStatus.percent(s.all)),
      ),
    )->toEqual(Some((2, 40)))
  )
})

describe("CatalogueStatus.problems", () => {
  let reasons = (~releases) =>
    CatalogueStatus.problems(layers, ~releases, ~hash)->Array.map(p => (
      p.language,
      p.key,
      p.reason,
    ))

  testSync("a draft language passes while incomplete", () =>
    expect(reasons(~releases=dict{"de": CatalogueStatus.Draft}))->toEqual([])
  )

  testSync("a released language fails on each missing and stale key", () =>
    expect(reasons(~releases=dict{"de": CatalogueStatus.Released}))->toEqual([
      ("de", "App.title.name", "missing"),
      ("de", "Ordering.CancelOrder.error.OrderAlreadyShipped", "missing"),
      ("de", "Ordering.PlaceOrder.name", "stale: the English changed after it was translated"),
    ])
  )

  testSync("any language fails on a text that does not parse or loses a placeholder", () => {
    let broken = layer(
      "ordering",
      ~catalogues=dict{
        "en": dict{"A.b.count": "{count, plural, one {# a} other {# as}}", "A.c.name": "C"},
        "de": dict{"A.b.count": "{n, plural, one {# a} other {# as}}", "A.c.name": "C {"},
      },
    )
    expect(
      CatalogueStatus.problems([broken], ~releases=dict{}, ~hash)->Array.map(p => p.key),
    )->toEqual(["A.b.count", "A.c.name"])
  })
})

describe("CatalogueStatus.mark", () => {
  let marksOf = (result, name) =>
    result->Array.find(((n, _)) => n == name)->Option.map(Pair.second)->Option.getOr(dict{})

  testSync("without keys, marks only what is unmarked or stale, and keeps a review", () => {
    let next = CatalogueStatus.mark(layers, ~language="de", ~patterns=[], ~confirmed=false, ~hash)
    expect(marksOf(next, "ordering"))->toEqual(
      dict{
        "Ordering.Orders.plural": {CatalogueStatus.source: "#Orders", confirmed: true},
        "Ordering.Orders.count": {
          source: "#{count, plural, one {# order} other {# orders}}",
          confirmed: false,
        },
        "Ordering.PlaceOrder.name": {source: "#Place Order", confirmed: false},
      },
    )
  })

  testSync("confirming a prefix marks the keys it names in the layer that supplies them", () => {
    let next = CatalogueStatus.mark(
      layers,
      ~language="de-x-du",
      ~patterns=["App.*"],
      ~confirmed=true,
      ~hash,
    )
    expect((marksOf(next, "app"), marksOf(next, "ordering")))->toEqual((
      dict{"App.title.name": {CatalogueStatus.source: "#Shop", confirmed: true}},
      dict{},
    ))
  })
})

describe("CatalogueStatus.readReleases", () => {
  testSync("reads draft and released, and refuses anything else", () =>
    expect((
      CatalogueStatus.readReleases(`{"de": "released", "en": "draft"}`),
      CatalogueStatus.readReleases(`{"de": "done"}`)->Result.isError,
    ))->toEqual((Ok(dict{"de": CatalogueStatus.Released, "en": Draft}), true))
  )
})

describe("CatalogueStatus.layerOf", () => {
  testSync("reads catalogues and marks; a lock or a proposal file is not a language", () => {
    let l =
      CatalogueStatus.layerOf(
        ~name="ordering",
        [
          ("de.json", `{"Ordering.Orders.plural": "Bestellungen"}`),
          ("de.lock.json", `{"Ordering.Orders.plural": {"source": "#Orders", "confirmed": true}}`),
          ("de.proposed.json", `{"Ordering.PlaceOrder.name": "Bestellung aufgeben"}`),
          ("en.json", `{"Ordering.Orders.plural": "Orders"}`),
          ("languages.json", `{"de": "released"}`),
        ],
      )->Result.getOrThrow
    expect((
      l.catalogues->Dict.keysToArray->Array.toSorted(String.compare),
      l.marks->Dict.get("de")->Option.flatMap(m => m->Dict.get("Ordering.Orders.plural")),
    ))->toEqual((["de", "en"], Some({CatalogueStatus.source: "#Orders", confirmed: true})))
  })

  testSync("a catalogue that is not JSON is named", () =>
    expect(CatalogueStatus.layerOf(~name="app", [("de.json", "{")]))->toEqual(
      Error("app/de.json is not JSON"),
    )
  )
})

describe("CatalogueStatus.mark and the glossary's terms", () => {
  testSync("marking a key again keeps the terms a glossary recorded for it", () => {
    let withTerms = {
      ...ordering,
      marks: dict{
        "de": dict{
          "Ordering.Orders.plural": {
            CatalogueStatus.source: "#Old",
            confirmed: true,
            terms: dict{"order": "h1"},
          },
        },
      },
    }
    let next = CatalogueStatus.mark(
      [withTerms],
      ~language="de",
      ~patterns=["Ordering.Orders.plural"],
      ~confirmed=true,
      ~hash,
    )
    let marks = next->Array.getUnsafe(0)->Pair.second
    expect((
      marks->Dict.get("Ordering.Orders.plural"),
      CatalogueStatus.marksText(marks)
      ->CatalogueStatus.readMarks
      ->Dict.get("Ordering.Orders.plural"),
    ))->toEqual((
      Some({CatalogueStatus.source: "#Orders", confirmed: true, terms: dict{"order": "h1"}}),
      Some({CatalogueStatus.source: "#Orders", confirmed: true, terms: dict{"order": "h1"}}),
    ))
  })
})
