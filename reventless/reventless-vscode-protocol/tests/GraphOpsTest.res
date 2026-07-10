// Unit tests for the pure domain-graph operations (GraphOps): slice-membership math,
// chapter propagation, DCB read-edge filtering, component→node resolution. No IO.
// NOTE (rescript-jest): only the RETURNED assertion runs — multi-assert cases are
// expressed as single tuple comparisons, never `->ignore`d expects.

open JestGlobals
open Protocol

let n = (~id, ~kind, ~label=?): GraphOps.graphNode => {
  id,
  kind,
  label: label->Option.getOr(id),
  plugin: "P",
}
let e = (~from, ~to_, ~kind): GraphOps.graphEdge => {from, to_, kind}

describe("slicesForNodes", () => {
  testSync("boxes a write-side with the command it handles + event it emits", () => {
    let nodes = [n(~id="Agg", ~kind=Aggregate), n(~id="Cmd", ~kind=Command), n(~id="Evt", ~kind=Event)]
    let edges = [e(~from="Cmd", ~to_="Agg", ~kind=Handles), e(~from="Agg", ~to_="Evt", ~kind=Emits)]
    expect(GraphOps.slicesForNodes(nodes, edges))->toEqual([
      ("Agg", "Agg::slice"),
      ("Cmd", "Agg::slice"),
      ("Evt", "Agg::slice"),
    ])
  })

  testSync("a leaf owned by two write-sides is left unboxed", () => {
    let nodes = [
      n(~id="Agg1", ~kind=Aggregate),
      n(~id="Agg2", ~kind=Aggregate),
      n(~id="Evt", ~kind=Event),
    ]
    let edges = [e(~from="Agg1", ~to_="Evt", ~kind=Emits), e(~from="Agg2", ~to_="Evt", ~kind=Emits)]
    // Both anchors appear; the shared Evt is in neither box (a D2 node lives in one only).
    expect(GraphOps.slicesForNodes(nodes, edges))->toEqual([
      ("Agg1", "Agg1::slice"),
      ("Agg2", "Agg2::slice"),
    ])
  })

  testSync("only ownership edges (handles/emits) box a leaf — a DCB `reads` edge does not", () => {
    let nodes = [n(~id="Agg", ~kind=Aggregate), n(~id="Evt", ~kind=Event)]
    let edges = [e(~from="Evt", ~to_="Agg", ~kind=Reads)]
    expect(GraphOps.slicesForNodes(nodes, edges))->toEqual([("Agg", "Agg::slice")])
  })

  testSync("tolerates a pre-v11 emitter's lowercase handles/emits wire kinds", () => {
    // A pre-v11 core streams `"handles"`/`"emits"`, which the @unboxed decode surfaces
    // as OtherEdgeKind. The box must still pull in the command/event leaf (version skew).
    let nodes = [n(~id="Agg", ~kind=Aggregate), n(~id="Cmd", ~kind=Command), n(~id="Evt", ~kind=Event)]
    let edges = [
      e(~from="Cmd", ~to_="Agg", ~kind=OtherEdgeKind("handles")),
      e(~from="Agg", ~to_="Evt", ~kind=OtherEdgeKind("emits")),
    ]
    expect(GraphOps.slicesForNodes(nodes, edges))->toEqual([
      ("Agg", "Agg::slice"),
      ("Cmd", "Agg::slice"),
      ("Evt", "Agg::slice"),
    ])
  })
})

describe("readSlicesForNodes", () => {
  testSync("anchors each read-side kind (incl. Stream variants), ignores others", () => {
    let nodes = [
      n(~id="RM", ~kind=ReadModel),
      n(~id="SV", ~kind=StateViewSliceStream),
      n(~id="Cmd", ~kind=Command),
    ]
    expect(GraphOps.readSlicesForNodes(nodes))->toEqual([
      ("RM", "RM::read-slice"),
      ("SV", "SV::read-slice"),
    ])
  })
})

describe("kind/label helpers", () => {
  testSync("baseKind drops a trailing Stream suffix only", () =>
    expect((
      GraphOps.baseKind(ReadModelStream),
      GraphOps.baseKind(StateViewSliceStream),
      GraphOps.baseKind(Command),
      GraphOps.baseKind(OtherKind("StreamThing")), // not a suffix
      GraphOps.baseKind(OtherKind("FutureKindStream")), // unknown kinds keep the strip
    ))->toEqual((ReadModel, StateViewSlice, Command, OtherKind("StreamThing"), OtherKind("FutureKind")))
  )

  testSync("isDottedSegment matches a whole dotted segment, not a substring", () =>
    expect((
      GraphOps.isDottedSegment("Catalog.Products", "Products"),
      GraphOps.isDottedSegment("Catalog.Products.Ordering", "Products"),
      GraphOps.isDottedSegment("Catalog.Products", "Product"), // partial segment
      GraphOps.isDottedSegment("Catalog.Products", "Orders"),
    ))->toEqual((true, true, false, false))
  )
})

// A bare-name node (a StateViewSliceStream component surfaces as a StateViewSlice node)
// resolves Stream-insensitively; an EP node resolves by dotted segment.
let graph = [
  n(~id="P:Orders", ~kind=StateViewSlice, ~label="Orders"),
  n(~id="P.Catalog.Products", ~kind=ExtensionPoint, ~label="Catalog.Products"),
]

describe("component→node resolution", () => {
  testSync("graphNodeForComponent matches bare name Stream-insensitively", () => {
    let hit = GraphOps.graphNodeForComponent(graph, StateViewSliceStream, "Orders")
    expect(hit->Option.map((n: GraphOps.graphNode) => n.id))->toEqual(Some("P:Orders"))
  })

  testSync("graphNodeForComponent matches an EP by dotted segment", () => {
    let hit = GraphOps.graphNodeForComponent(graph, ExtensionPoint, "Products")
    expect(hit->Option.map((n: GraphOps.graphNode) => n.id))->toEqual(Some("P.Catalog.Products"))
  })

  testSync("resolveComponentNodeId prefers exact fq, else same-kind name, kind-restricted", () =>
    expect((
      // fq exact wins.
      GraphOps.resolveComponentNodeId(graph, StateViewSlice, "x", Some("Orders")),
      // no fq → same-kind bare name.
      GraphOps.resolveComponentNodeId(graph, StateViewSliceStream, "Orders", None),
      // wrong kind for the name → no match (kind-restricted).
      GraphOps.resolveComponentNodeId(graph, Command, "Orders", None),
      // EP by dotted segment.
      GraphOps.resolveComponentNodeId(graph, ExtensionPoint, "Products", None),
    ))->toEqual((Some("P:Orders"), Some("P:Orders"), None, Some("P.Catalog.Products")))
  )
})

describe("cmdEvtForNode", () => {
  testSync("groups adjacent commands/events, deduped + label-sorted", () => {
    let nodes = [
      n(~id="Agg", ~kind=Aggregate),
      n(~id="c1", ~kind=Command, ~label="Ship"),
      n(~id="c2", ~kind=Command, ~label="Add"),
      n(~id="e1", ~kind=Event, ~label="Shipped"),
      n(~id="other", ~kind=Command, ~label="Unrelated"),
    ]
    let edges = [
      e(~from="c1", ~to_="Agg", ~kind=Handles),
      e(~from="Agg", ~to_="c2", ~kind=Handles),
      e(~from="Agg", ~to_="e1", ~kind=Emits),
    ]
    let g = GraphOps.cmdEvtForNode(nodes, edges, "Agg")
    // Commands sorted by label (Add before Ship); the unrelated command is excluded.
    expect((
      g.commands->Array.map(l => l.label),
      g.events->Array.map(l => l.label),
    ))->toEqual((["Add", "Ship"], ["Shipped"]))
  })
})

describe("propagateChapters", () => {
  testSync("a command/event inherits its adjacent seeded node's chapter", () => {
    let nodes = [
      n(~id="Slice", ~kind=StateChangeSlice),
      n(~id="Cmd", ~kind=Command),
      n(~id="Evt", ~kind=Event),
    ]
    let edges = [e(~from="Cmd", ~to_="Slice", ~kind=Handles), e(~from="Slice", ~to_="Evt", ~kind=Emits)]
    // Slice is seeded with "Checkout"; Cmd + Evt inherit it via their adjacency.
    expect(GraphOps.propagateChapters(nodes, edges, [("Slice", "Checkout")]))->toEqual([
      ("Slice", "Checkout"),
      ("Cmd", "Checkout"),
      ("Evt", "Checkout"),
    ])
  })

  testSync("only command/event leaves inherit; other unseeded kinds stay out", () => {
    let nodes = [n(~id="Slice", ~kind=StateChangeSlice), n(~id="RM", ~kind=ReadModel)]
    let edges = [e(~from="Slice", ~to_="RM", ~kind=Projects)]
    // RM is not a leaf (Command/Event), so it gets no chapter even though adjacent.
    expect(GraphOps.propagateChapters(nodes, edges, [("Slice", "Checkout")]))->toEqual([
      ("Slice", "Checkout"),
    ])
  })

  testSync("first adjacent seeded node wins (edge order)", () => {
    let nodes = [
      n(~id="A", ~kind=Aggregate),
      n(~id="B", ~kind=Aggregate),
      n(~id="Evt", ~kind=Event),
    ]
    // Evt touches A (chapter "First") then B (chapter "Second"); the first edge wins.
    let edges = [e(~from="A", ~to_="Evt", ~kind=Emits), e(~from="B", ~to_="Evt", ~kind=Emits)]
    expect(GraphOps.propagateChapters(nodes, edges, [("A", "First"), ("B", "Second")]))->toEqual([
      ("A", "First"),
      ("B", "Second"),
      ("Evt", "First"),
    ])
  })

  testSync("a leaf with no chaptered neighbour is left unchaptered", () => {
    let nodes = [n(~id="Slice", ~kind=StateChangeSlice), n(~id="Evt", ~kind=Event)]
    let edges = [e(~from="Slice", ~to_="Evt", ~kind=Emits)]
    // Slice itself isn't seeded, so Evt has no chapter to inherit.
    expect(GraphOps.propagateChapters(nodes, edges, []))->toEqual([])
  })
})

// Sorted node ids of a scoped subgraph — order-insensitive membership pinning.
let ids = (sg: GraphOps.subgraph) =>
  sg.nodes->Array.map((n: GraphOps.graphNode) => n.id)->Array.toSorted(String.compare)
let has = (sg: GraphOps.subgraph, id) => sg.nodes->Array.some(n => n.id == id)

describe("neighbourhood", () => {
  testSync("follows the full flow across plugin boundaries", () => {
    let ns = [
      n(~id="A", ~kind=Aggregate),
      n(~id="B", ~kind=Extension),
      n(~id="C", ~kind=ExtensionPoint),
    ]
    let es = [
      e(~from="A", ~to_="B", ~kind=DelegatesTo),
      e(~from="C", ~to_="B", ~kind=Consumes), // crosses into the neighbouring plugin
    ]
    expect(ids(GraphOps.neighbourhood(ns, es, "B")))->toEqual(["A", "B", "C"])
  })

  testSync("keeps the whole connected component, excludes disjoint nodes", () => {
    let ns = ["A", "B", "C", "X"]->Array.map(id => n(~id, ~kind=Event))
    let es = [e(~from="A", ~to_="B", ~kind=Emits), e(~from="B", ~to_="C", ~kind=Emits)]
    expect(ids(GraphOps.neighbourhood(ns, es, "A")))->toEqual(["A", "B", "C"]) // not X
  })
})

// A producer→EP→extension→consumer chain spanning two plugins, pinning focusView.
let chainNodes = [
  n(~id="Catalog_AddProduct", ~kind=Command, ~label="AddProduct"),
  n(~id="Catalog:AddProduct", ~kind=StateChangeSlice, ~label="AddProduct"),
  n(~id="Catalog.ProductAdded", ~kind=Event, ~label="ProductAdded"),
  n(~id="Catalog:ep:Catalog.Products", ~kind=ExtensionPoint, ~label="Catalog.Products"),
  n(~id="Catalog.Products.ProductBecameAvailable", ~kind=Event, ~label="ProductBecameAvailable"),
  n(~id="Ordering:ext:Catalog.Products", ~kind=Extension, ~label="Catalog.Products.Ordering"),
  n(~id="Ordering:AvailableProducts", ~kind=StateViewSlice, ~label="AvailableProducts"),
  n(~id="Ordering.ProductCached", ~kind=Event, ~label="ProductCached"),
  n(~id="Ordering:Catalogue", ~kind=ReadModel, ~label="Catalogue"),
]
let chainEdges = [
  e(~from="Catalog_AddProduct", ~to_="Catalog:AddProduct", ~kind=Handles),
  e(~from="Catalog:AddProduct", ~to_="Catalog.ProductAdded", ~kind=Emits),
  e(~from="Catalog.ProductAdded", ~to_="Catalog:ep:Catalog.Products", ~kind=Feeds),
  e(~from="Catalog:ep:Catalog.Products", ~to_="Catalog.Products.ProductBecameAvailable", ~kind=Publishes),
  e(~from="Catalog.Products.ProductBecameAvailable", ~to_="Ordering:ext:Catalog.Products", ~kind=Consumes),
  e(~from="Ordering:ext:Catalog.Products", ~to_="Ordering:AvailableProducts", ~kind=DelegatesTo),
  e(~from="Ordering:AvailableProducts", ~to_="Ordering.ProductCached", ~kind=Emits),
  e(~from="Ordering.ProductCached", ~to_="Ordering:Catalogue", ~kind=Projects),
]

describe("focusView", () => {
  testSync("producer-side focus stops at the extension point", () => {
    let v = GraphOps.focusView(chainNodes, chainEdges, "Catalog:AddProduct")
    expect((
      v->has("Catalog_AddProduct"),
      v->has("Catalog.ProductAdded"),
      v->has("Catalog:ep:Catalog.Products"),
      v->has("Catalog.Products.ProductBecameAvailable"),
      v->has("Ordering:ext:Catalog.Products"),
      v->has("Ordering:Catalogue"),
    ))->toEqual((true, true, true, false, false, false))
  })

  testSync("extension-point focus shows its connected extensions + direct producers", () => {
    let v = GraphOps.focusView(chainNodes, chainEdges, "Catalog:ep:Catalog.Products")
    expect((
      v->has("Catalog:ep:Catalog.Products"),
      v->has("Catalog.Products.ProductBecameAvailable"),
      v->has("Ordering:ext:Catalog.Products"),
      v->has("Catalog.ProductAdded"),
      v->has("Catalog:AddProduct"),
      v->has("Catalog_AddProduct"),
      v->has("Ordering:AvailableProducts"),
      v->has("Ordering.ProductCached"),
      v->has("Ordering:Catalogue"),
    ))->toEqual((true, true, true, true, true, true, false, false, false))
  })

  testSync("extension focus shows the consuming parts + the connected extension point", () => {
    let v = GraphOps.focusView(chainNodes, chainEdges, "Ordering:ext:Catalog.Products")
    expect((
      v->has("Ordering:ext:Catalog.Products"),
      v->has("Ordering:AvailableProducts"),
      v->has("Ordering.ProductCached"),
      v->has("Ordering:Catalogue"),
      v->has("Catalog.Products.ProductBecameAvailable"),
      v->has("Catalog:ep:Catalog.Products"),
      v->has("Catalog.ProductAdded"),
      v->has("Catalog:AddProduct"),
      v->has("Catalog_AddProduct"),
    ))->toEqual((true, true, true, true, true, true, false, false, false))
  })

  testSync("producer focus does NOT bounce back through a shared read model", () => {
    let ns = [
      n(~id="p:Slice1", ~kind=StateChangeSlice, ~label="Slice1"),
      n(~id="p.Event1", ~kind=Event, ~label="Event1"),
      n(~id="p:View", ~kind=ReadModel, ~label="View"),
      n(~id="p:Slice2", ~kind=StateChangeSlice, ~label="Slice2"),
      n(~id="p.Event2", ~kind=Event, ~label="Event2"),
    ]
    let es = [
      e(~from="p:Slice1", ~to_="p.Event1", ~kind=Emits),
      e(~from="p.Event1", ~to_="p:View", ~kind=Projects),
      e(~from="p:Slice2", ~to_="p.Event2", ~kind=Emits),
      e(~from="p.Event2", ~to_="p:View", ~kind=Projects),
    ]
    // not Slice2 / Event2
    expect(ids(GraphOps.focusView(ns, es, "p:Slice1")))->toEqual(["p.Event1", "p:Slice1", "p:View"])
  })
})

let rc = (~eventId, ~sliceId, ~crossPartition=false): GraphOps.readCandidate => {
  eventId,
  sliceId,
  crossPartition,
}

describe("readEdgesToAdd", () => {
  testSync("emits a reads edge when both nodes exist and aren't connected", () => {
    let nodes = [n(~id="P.Evt", ~kind=Event), n(~id="P:Slice", ~kind=StateViewSlice)]
    let expected: array<GraphOps.graphEdge> = [{from: "P.Evt", to_: "P:Slice", kind: Reads}]
    expect(GraphOps.readEdgesToAdd(nodes, [], [rc(~eventId="P.Evt", ~sliceId="P:Slice")]))->toEqual(
      expected,
    )
  })

  testSync("tags a cross-partition read distinctly", () => {
    let nodes = [n(~id="P.Evt", ~kind=Event), n(~id="P:Slice", ~kind=StateViewSlice)]
    let expected: array<GraphOps.graphEdge> = [
      {from: "P.Evt", to_: "P:Slice", kind: ReadsCrossPartition},
    ]
    expect(
      GraphOps.readEdgesToAdd(nodes, [], [rc(~eventId="P.Evt", ~sliceId="P:Slice", ~crossPartition=true)]),
    )->toEqual(expected)
  })

  testSync("skips a candidate whose endpoint is not a node", () => {
    let nodes = [n(~id="P.Evt", ~kind=Event)] // no P:Slice node
    expect(GraphOps.readEdgesToAdd(nodes, [], [rc(~eventId="P.Evt", ~sliceId="P:Slice")]))->toEqual([])
  })

  testSync("skips a pair already connected in either direction", () => {
    let nodes = [n(~id="P.Evt", ~kind=Event), n(~id="P:Slice", ~kind=StateViewSlice)]
    // An existing edge slice→event (reverse direction) still counts as connected.
    let edges = [e(~from="P:Slice", ~to_="P.Evt", ~kind=Projects)]
    expect(GraphOps.readEdgesToAdd(nodes, edges, [rc(~eventId="P.Evt", ~sliceId="P:Slice")]))->toEqual([])
  })

  testSync("de-dupes duplicate candidates for the same pair", () => {
    let nodes = [n(~id="P.Evt", ~kind=Event), n(~id="P:Slice", ~kind=StateViewSlice)]
    let cands = [rc(~eventId="P.Evt", ~sliceId="P:Slice"), rc(~eventId="P.Evt", ~sliceId="P:Slice")]
    let expected: array<GraphOps.graphEdge> = [{from: "P.Evt", to_: "P:Slice", kind: Reads}]
    expect(GraphOps.readEdgesToAdd(nodes, [], cands))->toEqual(expected)
  })
})
