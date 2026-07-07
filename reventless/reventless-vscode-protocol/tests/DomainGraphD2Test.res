// Headless unit tests for the D2-source generator — pure functions, no IO except the
// final d2-binary smoke test (skipped gracefully when d2 isn't installed).
// NOTE (rescript-jest): only the RETURNED assertion runs — multi-assert cases are
// expressed as single tuple comparisons or a missing-substrings filter, never
// `->ignore`d expects.

open JestGlobals

type execOpts = {input: string, encoding: string}
@module("node:child_process")
external execFileSync: (string, array<string>, execOpts) => string = "execFileSync"
let errCode: JsExn.t => option<string> = %raw(`e => (e && typeof e.code === 'string') ? e.code : undefined`)

open DomainGraphD2

let nodes: array<gNode> = [
  {id: "Catalog_Category_Add", kind: Command, label: "Add", plugin: "Catalog"},
  {id: "Catalog:Category", kind: Aggregate, label: "Category", plugin: "Catalog"},
  {id: "Catalog.Added", kind: Event, label: "Added", plugin: "Catalog"},
  {id: "Catalog:Categories", kind: ReadModel, label: "Categories", plugin: "Catalog"},
]
let edges: array<gEdge> = [
  {from: "Catalog_Category_Add", to_: "Catalog:Category", kind: Handles},
  {from: "Catalog:Category", to_: "Catalog.Added", kind: Emits},
  {from: "Catalog.Added", to_: "Catalog:Categories", kind: Projects},
]

// Every needle must be a substring of the haystack — the failure output lists the
// missing ones.
let missingFrom = (hay: string, needles: array<string>): array<string> =>
  needles->Array.filter(s => !(hay->String.includes(s)))

describe("class mapping", () => {
  testSync("node kinds map to D2 colour classes; unknown falls back to box", () =>
    expect((
      nodeClassOf(Aggregate),
      nodeClassOf(Event),
      nodeClassOf(ReadModel),
      nodeClassOf(ExternalSystem),
      nodeClassOf(OtherKind("Whatever")),
    ))->toEqual(("aggregate", "msg-event", "read-model", "external-system", "box"))
  )

  testSync("edge relations map to connection classes; cross-plugin mechanisms fall through", () =>
    expect((
      edgeClassOf(Handles),
      edgeClassOf(Emits),
      edgeClassOf(Projects),
      edgeClassOf(Feeds),
      edgeClassOf(Reads),
      edgeClassOf(TranslatesIn),
      edgeClassOf(TranslatesOut),
      edgeClassOf(OtherEdgeKind("Extension")),
    ))->toEqual((
      "command-flow",
      "event-flow",
      "projection-flow",
      "event-flow",
      "dcb-read",
      "cross-plugin",
      "cross-plugin",
      "cross-plugin",
    ))
  )
})

describe("legend", () => {
  testSync("covers node kinds + edge classes with swatches; box fallback is reference-only", () => {
    let entries = legend()
    let keys = entries->Array.map(e => e.key)
    expect((
      keys->Array.includes("Event"),
      keys->Array.includes("dcb-read"),
      keys->Array.includes("cross-plugin"),
      entries->Array.every(e => e.swatch->String.startsWith("#") && e.description != ""),
      entries->Array.some(e => e.key == "box" && !e.toggleable),
    ))->toEqual((true, true, true, true, true))
  })

  testSync("presentKeys = node kinds ∪ edge classes in the view (deduped)", () => {
    let keys = presentKeys(nodes, edges)
    expect((
      keys->Array.includes("Aggregate"),
      keys->Array.includes("event-flow"),
      keys->Array.includes("projection-flow"),
      keys->Array.includes("dcb-read"),
    ))->toEqual((true, true, true, false))
  })

  testSync("applyLegendFilter drops hidden node kinds and dangling edges", () => {
    // hide Event → the emits + projects edges (both touch Catalog.Added) drop too
    let v = applyLegendFilter(nodes, edges, ["Event"])
    expect((
      v.nodes->Array.some(n => n.kind == Event),
      v.edges->Array.every(e => e.to_ != "Catalog.Added" && e.from != "Catalog.Added"),
      v.edges->Array.some(e => e.kind == Handles), // Command → Aggregate survives
    ))->toEqual((false, true, true))
  })

  testSync("applyLegendFilter drops a hidden edge class but keeps its endpoints", () => {
    let v = applyLegendFilter(nodes, edges, ["projection-flow"])
    expect((
      v.edges->Array.every(e => e.kind != Projects),
      v.nodes->Array.some(n => n.id == "Catalog:Categories"), // ReadModel node stays
    ))->toEqual((true, true))
  })
})

describe("toD2", () => {
  testSync("emits the class block + nodes grouped in per-plugin containers, classed edges", () =>
    expect(
      missingFrom(
        toD2(nodes, edges),
        [
          "classes: {",
          `"Catalog"."Catalog:Category": "Category" { class: aggregate }`,
          `"Catalog"."Catalog.Added": "Added" { class: msg-event }`,
          `"Catalog"."Catalog_Category_Add" -> "Catalog"."Catalog:Category" { class: command-flow }`,
        ],
      ),
    )->toEqual([])
  )

  testSync("an empty graph still produces valid D2 (class block + placeholder)", () =>
    expect(missingFrom(toD2([], []), ["classes: {", `empty: "No plugins loaded"`]))->toEqual([])
  )

  testSync("ids/labels with quotes are escaped", () =>
    expect(
      toD2([{id: `a"b`, kind: Event, label: `l"l`, plugin: "p"}], [])->String.includes(
        "\"a\\\"b\": \"l\\\"l\"",
      ),
    )->toBe(true)
  )

  testSync("an external-system node renders outside the plugin; its boundary edge carries a label", () => {
    let nodes: array<gNode> = [
      {id: "Ordering:SendEmail", kind: OutboundTranslationSlice, label: "SendEmail", plugin: "Ordering"},
      {id: "ext:EmailService", kind: ExternalSystem, label: "EmailService", plugin: ""},
    ]
    let edges: array<gEdge> = [
      {from: "Ordering:SendEmail", to_: "ext:EmailService", kind: TranslatesOut, label: "Placed"},
    ]
    expect(
      missingFrom(
        toD2(nodes, edges),
        [
          // The external box is declared bare (no plugin container) with its rose class.
          `"ext:EmailService": "EmailService" { class: external-system`,
          // The boundary edge carries the payload label and renders cross-plugin (plugin "" ≠ Ordering).
          `-> "ext:EmailService": "Placed" { class: cross-plugin`,
        ],
      ),
    )->toEqual([])
  })

  testSync("a `reads` edge renders the dcb-read class", () =>
    expect(
      toD2(
        [
          {id: "Catalog.Added", kind: Event, label: "Added", plugin: "Catalog"},
          {id: "Catalog:Reserve", kind: StateChangeSlice, label: "Reserve", plugin: "Catalog"},
        ],
        [{from: "Catalog.Added", to_: "Catalog:Reserve", kind: Reads}],
      )->String.includes(`"Catalog"."Catalog.Added" -> "Catalog"."Catalog:Reserve" { class: dcb-read }`),
    )->toBe(true)
  )

  testSync("allPlugins declares an empty container for an element-less plugin", () =>
    expect(
      missingFrom(
        toD2(nodes, edges, ~allPlugins=["Catalog", "Billing"]),
        [
          `"Billing": { }`,
          // a populated plugin's container isn't duplicated — its node still nests under it
          `"Catalog"."Catalog:Category"`,
        ],
      ),
    )->toEqual([])
  )

  testSync("allPlugins lets an otherwise-empty graph still show plugin boxes", () => {
    let d2 = toD2([], [], ~allPlugins=["Catalog", "Ordering"])
    expect((
      missingFrom(d2, [`"Catalog": { }`, `"Ordering": { }`]),
      d2->String.includes("No plugins loaded"),
    ))->toEqual(([], false))
  })
})

describe("toD2 focus", () => {
  testSync("thickens the focus node border, leaves others plain", () =>
    expect(
      missingFrom(
        toD2(nodes, edges, ~focusId="Catalog:Category"),
        [
          `"Catalog"."Catalog:Category": "Category" { class: aggregate; style.stroke-width: 4`,
          `"Catalog"."Catalog.Added": "Added" { class: msg-event }`, // non-focus, plain
        ],
      ),
    )->toEqual([])
  )

  testSync("highlights every edge touching the focus, leaves others plain", () =>
    expect(
      missingFrom(
        toD2(nodes, edges, ~focusId="Catalog:Category"),
        [
          `"Catalog"."Catalog_Category_Add" -> "Catalog"."Catalog:Category" { class: command-flow; style.stroke-width: 3; style.animated: true }`,
          `-> "Catalog"."Catalog.Added" { class: event-flow; style.stroke-width: 3`,
          `"Catalog"."Catalog.Added" -> "Catalog"."Catalog:Categories" { class: projection-flow }`,
        ],
      ),
    )->toEqual([])
  )
})

describe("toD2 chapters", () => {
  testSync("nests chaptered nodes in a chapter sub-container, leaves the rest in the plugin", () => {
    // Category is in chapter "Catalog Management"; the Add command inherits it; the read
    // model has no chapter and stays directly in the plugin.
    let chapters = [
      ("Catalog:Category", "Catalog Management"),
      ("Catalog_Category_Add", "Catalog Management"),
    ]
    expect(
      missingFrom(
        toD2(nodes, edges, ~chapters),
        [
          `"Catalog"."Catalog Management": "Catalog Management" { class: chapter }`,
          `"Catalog"."Catalog Management"."Catalog:Category": "Category" { class: aggregate }`,
          `"Catalog"."Catalog Management"."Catalog_Category_Add" -> "Catalog"."Catalog Management"."Catalog:Category" { class: command-flow }`,
          `"Catalog"."Catalog:Categories": "Categories" { class: read-model }`,
        ],
      ),
    )->toEqual([])
  })

  testSync("with no chapters is unchanged (the chapter level is opt-in)", () =>
    expect(toD2(nodes, edges, ~chapters=[]))->toEqual(toD2(nodes, edges))
  )
})

describe("toD2 slices", () => {
  testSync("wraps a write-side node + its command/event in a slice box", () => {
    // The Category aggregate, its Add command and Added event form one slice; the read
    // model (only `projects`-linked to the event) stays out of the box.
    let slices = [
      ("Catalog:Category", "Catalog:Category::slice"),
      ("Catalog_Category_Add", "Catalog:Category::slice"),
      ("Catalog.Added", "Catalog:Category::slice"),
    ]
    expect(
      missingFrom(
        toD2(nodes, edges, ~slices),
        [
          `"Catalog"."Catalog:Category::slice": "" { class: write-side }`,
          `"Catalog"."Catalog:Category::slice"."Catalog:Category": "Category" { class: aggregate }`,
          `"Catalog"."Catalog:Category::slice"."Catalog_Category_Add" -> "Catalog"."Catalog:Category::slice"."Catalog:Category" { class: command-flow }`,
          // … while the un-sliced read model stays directly in the plugin container.
          `"Catalog"."Catalog:Categories": "Categories" { class: read-model }`,
        ],
      ),
    )->toEqual([])
  })

  testSync("nests a slice box inside its write-side's chapter", () => {
    let chapters = [
      ("Catalog:Category", "Catalog Management"),
      ("Catalog_Category_Add", "Catalog Management"),
    ]
    let slices = [
      ("Catalog:Category", "Catalog:Category::slice"),
      ("Catalog_Category_Add", "Catalog:Category::slice"),
    ]
    expect(
      missingFrom(
        toD2(nodes, edges, ~chapters, ~slices),
        [
          `"Catalog"."Catalog Management"."Catalog:Category::slice": "" { class: write-side }`,
          `"Catalog"."Catalog Management"."Catalog:Category::slice"."Catalog:Category": "Category" { class: aggregate }`,
        ],
      ),
    )->toEqual([])
  })

  testSync("with no slices is unchanged (the slice level is opt-in)", () =>
    expect(toD2(nodes, edges, ~slices=[]))->toEqual(toD2(nodes, edges))
  )

  testSync("wraps a read-side node in a read-slice box (anchor only)", () => {
    // The Categories read model is its own read-side slice — the box wraps ONLY the anchor;
    // the projected event stays in its emitting write box / plugin container.
    let slices = [("Catalog:Categories", "Catalog:Categories::read-slice")]
    let sliceClass = [("Catalog:Categories::read-slice", "read-side")]
    expect(
      missingFrom(
        toD2(nodes, edges, ~slices, ~sliceClass),
        [
          `"Catalog"."Catalog:Categories::read-slice": "" { class: read-side }`,
          `"Catalog"."Catalog:Categories::read-slice"."Catalog:Categories": "Categories" { class: read-model }`,
        ],
      ),
    )->toEqual([])
  })

  testSync("recolours a slice box by its board-status class", () => {
    let slices = [("Catalog:Categories", "Catalog:Categories::read-slice")]
    let done = toD2(nodes, edges, ~slices, ~sliceClass=[("Catalog:Categories::read-slice", "slice-done")])
    let prog =
      toD2(nodes, edges, ~slices, ~sliceClass=[("Catalog:Categories::read-slice", "slice-inprogress")])
    expect((
      done->String.includes(`"Catalog"."Catalog:Categories::read-slice": "" { class: slice-done }`),
      prog->String.includes(`"Catalog"."Catalog:Categories::read-slice": "" { class: slice-inprogress }`),
    ))->toEqual((true, true))
  })

  testSync("defaults an un-classed slice box to write-side", () => {
    // A sliceId absent from sliceClass falls back to the write-side family class.
    let slices = [("Catalog:Category", "Catalog:Category::slice")]
    expect(
      toD2(nodes, edges, ~slices)->String.includes(
        `"Catalog"."Catalog:Category::slice": "" { class: write-side }`,
      ),
    )->toBe(true)
  })
})

describe("toD2 drift overrides", () => {
  testSync("nodeClass replaces the palette class; edgeClass overrides the connection", () =>
    expect(
      missingFrom(
        toD2(
          nodes,
          edges,
          ~nodeClass=[("Catalog:Categories", "drift-removed")],
          ~edgeClass=[("Catalog.Added", "Catalog:Categories", "drift-removed-flow")],
        ),
        [
          `"Catalog"."Catalog:Categories": "Categories" { class: drift-removed }`,
          `"Catalog"."Catalog.Added" -> "Catalog"."Catalog:Categories" { class: drift-removed-flow }`,
          // untouched elements keep their kind-derived classes
          `"Catalog"."Catalog:Category": "Category" { class: aggregate }`,
        ],
      ),
    )->toEqual([])
  )

  testSync("with no overrides is unchanged (the override level is opt-in)", () =>
    expect(toD2(nodes, edges, ~nodeClass=[], ~edgeClass=[]))->toEqual(toD2(nodes, edges))
  )

  testSync("the drift palette classes exist in the generated class block", () =>
    expect(
      missingFrom(
        D2Classes.classes,
        [`"drift-added"`, `"drift-removed"`, `"drift-added-flow"`, `"drift-removed-flow"`],
      ),
    )->toEqual([])
  )
})

describe("toD2 plugin highlight", () => {
  testSync("outlines the highlighted plugin's container; empty leaves it unchanged", () =>
    expect((
      toD2(nodes, edges, ~highlightPlugin="Catalog")->String.includes(
        `"Catalog": { style.stroke-width: 4; style.bold: true }`,
      ),
      toD2(nodes, edges, ~highlightPlugin="") == toD2(nodes, edges),
    ))->toEqual((true, true))
  )
})

describe("d2 binary smoke", () => {
  testSync("generated D2 (incl. focus highlight) compiles with the d2 binary (passes trivially when d2 absent)", () => {
    let svg = try Some(
      execFileSync(
        "d2",
        ["-", "-"],
        {input: toD2(nodes, edges, ~focusId="Catalog:Category"), encoding: "utf8"},
      ),
    ) catch {
    | exn =>
      switch exn->JsExn.fromException->Option.flatMap(errCode) {
      | Some("ENOENT") => None // d2 not installed — nothing to pin
      | _ => throw(exn)
      }
    }
    expect(svg->Option.mapOr(true, s => s->String.includes("<svg")))->toBe(true)
  })
})
