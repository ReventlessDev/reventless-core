// Pure D2-source generation for the Event-Modeling graph. Translates the protocol
// graph model's nodes/edges into D2 with the repo's semantic classes. The class
// block lives in the GENERATED `D2Classes.res` — derived from the canonical palette
// packages/doc/d2/reventless.d2 by `scripts/d2-classes-gen.mjs` (run
// `pnpm sync:d2-styles`; verified by tests/D2ClassesGenTest.res). It's inlined so no
// consumer bundle depends on the docs package. No host dependency and no Node-only
// globals, so it's headlessly unit-tested and browser-safe; hosts rasterize the
// result with the `d2` CLI or D2's WASM build. Exposed to TypeScript consumers via
// genType — see `DomainGraphD2.gen.ts` and the hand-written bridges.

// Single-sourced protocol records: the same `graphNode`/`graphEdge` every consumer
// passes down (`GraphOps` re-exports them). `graphEdge`'s optional `label` annotates
// the connection — e.g. the payload type at a translation slice's boundary to/from an
// external system. Rendered as the d2 edge label.
type gNode = Protocol.graphNode
type gEdge = Protocol.graphEdge

@genType
type subgraph = GraphOps.subgraph

// Node kind → D2 class (colour family). Exhaustive over the v11 vocabulary (a new
// kind is a compile error here — decide its colour); unknown kinds fall back to a
// neutral box via the OtherKind escape.
@genType
let nodeClassOf = (kind: Protocol.componentKind): string =>
  switch kind {
  | Command => "command" // blue
  | Event => "msg-event" // orange
  | Aggregate => "aggregate" // yellow
  | StateChangeSlice => "state-change-slice"
  | ReadModel | ReadModelStream => "read-model" // green
  | StateViewSlice | StateViewSliceStream => "state-view-slice"
  | AutomationSlice => "automation-slice" // purple
  | OutboundTranslationSlice | InboundTranslationSlice => "side-effect" // pink
  | ExtensionPoint => "extension-point" // teal hexagon (the publishing boundary)
  | Extension => "extension" // violet hexagon (the subscribing boundary)
  | ExternalSystem => "external-system" // rose dashed box (a foreign system, outside the plugin)
  | Task
  | OtherKind(_) => "box"
  }

// Edge relation → connection class (line/label colour). Exhaustive over the v11
// vocabulary; unknown kinds fall through to the teal dashed `cross-plugin`.
@genType
let edgeClassOf = (kind: Protocol.edgeKind): string =>
  switch kind {
  | Handles => "command-flow" // blue
  | Emits => "event-flow" // orange
  | Projects => "projection-flow" // green
  | Triggers => "event-flow"
  | Publishes => "event-flow" // extension point → its event
  | Consumes => "event-flow" // event → extension
  | DelegatesTo => "command-flow" // extension → its local handler
  | RoutesTo => "command-flow" // extension point → the delegate command it routes inward
  | Feeds => "event-flow" // owner-plugin source event → extension point it feeds
  | Reads => "dcb-read" // consumedEvent DCB read of a consistency boundary (Phase 6.6)
  | ReadsCrossPartition => "dcb-read-xp" // a cross-partition (M:N invariant) DCB read (Phase 6.8)
  | TranslatesIn // external system → inbound translation slice (boundary)
  | TranslatesOut // outbound translation slice → external system (boundary)
  | Extends
  | OtherEdgeKind(_) => "cross-plugin"
  }

// ── Legend (Event Graph) ─────────────────────────────────────────────────────
// One entry per node kind + edge class, with a short description and a swatch colour
// (single-sourced from D2Classes.swatchColor). `key` is the toggle key — a node
// `kind` or an edge class (what `applyLegendFilter` / `presentKeys` match on).
// Legend rows are built through the shared D2Legend constructors; a node's
// swatch comes from its `nodeClassOf` palette class.
let nodeEntry = (kind: Protocol.componentKind, label, description): D2Legend.legendEntry =>
  D2Legend.nodeEntry(~class_=nodeClassOf(kind), (kind :> string), label, description)
let edgeEntry = D2Legend.edgeEntry

@genType
let legend = (): array<D2Legend.legendEntry> => [
  nodeEntry(Aggregate, "Aggregate", "Write-side decision component — owns command handling + event emission."),
  nodeEntry(Command, "Command", "An intent to change state."),
  nodeEntry(Event, "Event", "A fact that happened, stored in the event log."),
  nodeEntry(StateChangeSlice, "StateChange", "A single command → event decision slice."),
  nodeEntry(ReadModel, "ReadModel", "A queryable projection of events."),
  nodeEntry(StateViewSlice, "StateView", "A read-side projection feeding a view."),
  nodeEntry(AutomationSlice, "Automation", "Reacts to events to drive further commands."),
  nodeEntry(InboundTranslationSlice, "InboundTranslation", "Maps a foreign plugin's events inbound."),
  nodeEntry(OutboundTranslationSlice, "OutboundTranslation", "Publishes this plugin's events to other plugins."),
  nodeEntry(ExtensionPoint, "ExtensionPoint", "A published cross-plugin contract."),
  nodeEntry(Extension, "Extension", "An implementation of another plugin's extension point."),
  nodeEntry(ExternalSystem, "ExternalSystem", "A foreign system a translation slice integrates with, drawn outside the plugin."),
  edgeEntry("command-flow", "Command flow", "Command handling: command → handler (and routing)."),
  edgeEntry("event-flow", "Event flow", "Emits / triggers / publishes / consumes."),
  edgeEntry("projection-flow", "Projection", "Event → read model / view."),
  edgeEntry("dcb-read", "DCB read", "A consumedEvent reads a consistency boundary (dashed)."),
  edgeEntry(
    "dcb-read-xp",
    "DCB cross-partition read",
    "A consumedEvent read that crosses partitions — an M:N invariant read (fuchsia, long-dash).",
  ),
  edgeEntry("cross-plugin", "Cross-plugin", "A link crossing plugin boundaries (dashed)."),
  D2Legend.nodeEntry(~class_="box", ~toggleable=false, "box", "Other", "An uncategorised node."),
]

let dedupKeys = (xs: array<string>): array<string> => {
  let seen = Set.make()
  xs->Array.forEach(x => seen->Set.add(x))
  Array.fromIterator(seen->Set.values)
}

// Node kinds ∪ edge classes present in a view — drives which legend toggles are active.
@genType
let presentKeys = (nodes: array<gNode>, edges: array<gEdge>): array<string> =>
  dedupKeys(Array.concat(nodes->Array.map(n => (n.kind :> string)), edges->Array.map(e => edgeClassOf(e.kind))))

// Drop hidden node kinds + hidden edge classes (and any edge left dangling).
@genType
let applyLegendFilter = (
  nodes: array<gNode>,
  edges: array<gEdge>,
  hidden: array<string>,
): subgraph => {
  let keptNodes = nodes->Array.filter(n => !(hidden->Array.includes((n.kind :> string))))
  let ids = Set.make()
  keptNodes->Array.forEach(n => ids->Set.add(n.id))
  let keptEdges =
    edges->Array.filter(e =>
      !(hidden->Array.includes(edgeClassOf(e.kind))) && ids->Set.has(e.from) && ids->Set.has(e.to_)
    )
  {nodes: keptNodes, edges: keptEdges}
}

// The semantic class block — generated from the canonical palette (see file header).
let classes = D2Classes.classes

// D2 double-quoted string escape — shared (see D2Emit.q).
let q = D2Emit.q

// Extension points / extensions are drawn as their custom `shape: image` icon (an
// interlocking socket + plug with the label baked inside the SVG) — d2 ignores `shape`
// on a hyphenated class name, and an image's d2 label would render outside the shape.
// So these nodes carry an EMPTY d2 label and the visible text lives in the SVG. Every
// other kind keeps its colour class and its normal d2 label.
let isImageKind = (kind: Protocol.componentKind): bool => kind == ExtensionPoint || kind == Extension

let imageDecl = (s: D2Shapes.t): string =>
  `shape: image; icon: ${q(s.uri)}; width: ${Int.toString(s.width)}; height: ${Int.toString(s.height)}`

// → (d2 label, inside-braces declaration). Image kinds get an empty label.
let nodeRender = (kind: Protocol.componentKind, label: string): (string, string) =>
  switch kind {
  | ExtensionPoint => ("", imageDecl(D2Shapes.extensionPointIcon(label)))
  | Extension => ("", imageDecl(D2Shapes.extensionIcon(label)))
  | _ => (label, `class: ${nodeClassOf(kind)}`)
  }

// Focus scoping (`neighbourhood` — whole connected component — and `focusView` —
// kind-aware, bounded at the EP/Extension connectors) lives in the sibling
// `GraphOps`; hosts compose it with this renderer.

// Generate D2 source for the graph. Nodes are grouped into a per-plugin container —
// `"<plugin>"."<id>"`; edges reference the same qualified paths. `focusId`, when
// present, thickens that node's border + animates touching edges. Empty graphs still
// emit the class block + a placeholder.
// `focusId` defaults to "" (no focus) — node ids are never empty, so "" never marks a
// real node. genType renders it `focusId: undefined | string`, matching the TS optional.
// `chapters` is a list of (nodeId, chapterName) pairs (empty by default): a node with a
// chapter sits in a `"<plugin>"."<chapter>"."<id>"` sub-container — its own coloured
// grouping band inside the plugin. Nodes without a chapter stay directly in the plugin.
// `highlightPlugin` (default "") outlines one plugin's container — a thick bold border —
// for the "show this whole plugin" selection. Empty ⇒ no container highlight.
// `allPlugins` (default []) declares an (initially empty) container per plugin up
// front — so every plugin shows as a bounded-context box even with no elements, the
// way the Context Map always does. A populated plugin's later `"<p>"."<node>"` child
// merges into the same container. Pass it for the unfocused full view only.
// `slices` is a list of (nodeId, sliceId) pairs (empty by default): a vertical slice box
// wrapping one ANCHOR node with the leaves it owns — write-side, an Aggregate/StateChangeSlice
// with its command(s) + emitted event(s); read-side, a ReadModel/StateViewSlice with the
// event(s) it projects. Every member maps to the same sliceId; the box nests INSIDE the
// anchor's plugin[.chapter] (so all members share that container). A node's slice nesting
// takes precedence over its own chapter so a slice's leaves always land beside their anchor.
// `sliceClass` is a list of (sliceId, class) pairs giving each box its D2 class — the family
// (`write-side`/`read-side`) optionally overlaid with a board-status colour
// (`slice-inprogress`/`slice-done`). A sliceId absent here defaults to `write-side`.
@genType
let toD2 = (
  nodes: array<gNode>,
  edges: array<gEdge>,
  ~focusId: string="",
  ~chapters: array<(string, string)>=[],
  ~highlightPlugin: string="",
  ~allPlugins: array<string>=[],
  ~slices: array<(string, string)>=[],
  ~sliceClass: array<(string, string)>=[],
): string => {
  let lines = [classes, ""]
  if nodes->Array.length == 0 && allPlugins->Array.length == 0 {
    lines->Array.push(`empty: "No plugins loaded" { class: box }`)
    lines->Array.join("\n")
  } else {
    // Empty plugin containers first (deduped), so an element-less plugin still appears.
    let declaredPlugin = Set.make()
    allPlugins->Array.forEach(p =>
      if p != "" && !(declaredPlugin->Set.has(p)) {
        declaredPlugin->Set.add(p)
        lines->Array.push(`${q(p)}: { }`)
      }
    )
    if allPlugins->Array.length > 0 {
      lines->Array.push("")
    }
    let pluginById = Dict.make()
    nodes->Array.forEach(n => pluginById->Dict.set(n.id, n.plugin))
    let chapterById = Dict.make()
    chapters->Array.forEach(((id, ch)) =>
      if ch != "" {
        chapterById->Dict.set(id, ch)
      }
    )
    let sliceById = Dict.make()
    slices->Array.forEach(((id, sl)) =>
      if sl != "" {
        sliceById->Dict.set(id, sl)
      }
    )
    // sliceId → box class (default `write-side` for back-compat / write slices).
    let classBySlice = Dict.make()
    sliceClass->Array.forEach(((sl, cls)) =>
      if sl != "" && cls != "" {
        classBySlice->Dict.set(sl, cls)
      }
    )
    let boxClassOf = sl =>
      switch classBySlice->Dict.get(sl) {
      | Some(cls) => cls
      | None => "write-side"
      }
    // A slice box nests inside the plugin[.chapter] of ITS anchor node, so every member
    // (anchor + owned leaves) shares one container. Derive that base path from the anchor
    // member — the slice's only Aggregate/StateChangeSlice (write) or ReadModel/StateViewSlice
    // (read) node.
    let isAnchor = (kind: Protocol.componentKind) =>
      switch kind {
      | Aggregate
      | StateChangeSlice
      | ReadModel
      | ReadModelStream
      | StateViewSlice
      | StateViewSliceStream => true
      | _ => false
      }
    let pluginChapterBase = id =>
      switch pluginById->Dict.get(id) {
      | Some(p) if p != "" =>
        switch chapterById->Dict.get(id) {
        | Some(ch) => Some(`${q(p)}.${q(ch)}`)
        | None => Some(q(p))
        }
      | _ => None
      }
    let sliceBase = Dict.make()
    nodes->Array.forEach(n =>
      switch sliceById->Dict.get(n.id) {
      | Some(sl) if isAnchor(n.kind) =>
        switch pluginChapterBase(n.id) {
        | Some(base) => sliceBase->Dict.set(sl, base)
        | None => ()
        }
      | _ => ()
      }
    )
    // Outline the highlighted plugin's container (declared before its children).
    if highlightPlugin != "" {
      lines->Array.push(`${q(highlightPlugin)}: { style.stroke-width: 4; style.bold: true }`)
    }
    // Qualified d2 path: a node lives inside its plugin's container (omit the container
    // only when the plugin is unknown/empty), nested one level deeper in a chapter
    // sub-container when it belongs to a chapter, and one level deeper again in a
    // write-side slice box when it belongs to a slice. The slice's resolved base
    // (plugin[.chapter] of the write-side member) overrides the node's own chapter, so a
    // command/event always sits beside its write-side node.
    let nodeRef = id =>
      switch sliceById->Dict.get(id) {
      | Some(sl) =>
        switch sliceBase->Dict.get(sl) {
        | Some(base) => `${base}.${q(sl)}.${q(id)}`
        | None =>
          // Slice base unknown (write-side member filtered out / plugin-less) — fall back
          // to plain plugin[.chapter] nesting so the node still renders.
          switch pluginChapterBase(id) {
          | Some(base) => `${base}.${q(id)}`
          | None => q(id)
          }
        }
      | None =>
        switch pluginChapterBase(id) {
        | Some(base) => `${base}.${q(id)}`
        | None => q(id)
        }
      }
    // Declare each chapter sub-container once so it carries the `chapter` class. Only
    // chapters whose node has a known plugin are drawn.
    let seenChapter = Set.make()
    nodes->Array.forEach(n =>
      switch (pluginById->Dict.get(n.id), chapterById->Dict.get(n.id)) {
      | (Some(p), Some(ch)) if p != "" =>
        let key = `${p}/${ch}`
        if !(seenChapter->Set.has(key)) {
          seenChapter->Set.add(key)
          lines->Array.push(`${q(p)}.${q(ch)}: ${q(ch)} { class: chapter }`)
        }
      | _ => ()
      }
    )
    // Declare each slice box once (after its chapter, so the chapter container exists),
    // labelled empty — the contained write-side node already carries the slice's name.
    // Only slices whose write-side member resolved a base (a known plugin) are drawn.
    let seenSlice = Set.make()
    nodes->Array.forEach(n =>
      switch sliceById->Dict.get(n.id) {
      | Some(sl) if !(seenSlice->Set.has(sl)) =>
        switch sliceBase->Dict.get(sl) {
        | Some(base) =>
          seenSlice->Set.add(sl)
          lines->Array.push(`${base}.${q(sl)}: "" { class: ${boxClassOf(sl)} }`)
        | None => ()
        }
      | _ => ()
      }
    )
    nodes->Array.forEach(n => {
      let (lbl, decl) = nodeRender(n.kind, n.label)
      // image-shape nodes ignore the d2 stroke-width focus, so skip it for them.
      let focus =
        !isImageKind(n.kind) && focusId == n.id ? "; style.stroke-width: 4; style.bold: true" : ""
      lines->Array.push(`${nodeRef(n.id)}: ${q(lbl)} { ${decl}${focus} }`)
    })
    lines->Array.push("")
    edges->Array.forEach(e => {
      // Cross-plugin edges render dashed regardless of relation.
      let crossPlugin = pluginById->Dict.get(e.from) != pluginById->Dict.get(e.to_)
      let cls = crossPlugin ? "cross-plugin" : edgeClassOf(e.kind)
      let hot =
        focusId != "" && (e.from == focusId || e.to_ == focusId)
          ? "; style.stroke-width: 3; style.animated: true"
          : ""
      // An optional connection label (e.g. the payload type at a translation boundary)
      // renders as the d2 edge label: `a -> b: "label" { … }`.
      let lbl = switch e.label {
      | Some(s) if s != "" => `: ${q(s)}`
      | _ => ""
      }
      lines->Array.push(`${nodeRef(e.from)} -> ${nodeRef(e.to_)}${lbl} { class: ${cls}${hot} }`)
    })
    lines->Array.join("\n")
  }
}
