// Pure domain-graph operations over the protocol graph model (`Protocol.graphNode`/
// `graphEdge`): Event-Graph slice-membership math, chapter propagation, DCB read-edge
// filtering, and component→node resolution. No IO or global state — graph in, derived
// answers out — so hosts (e.g. a VS Code extension webview pipeline) can call these
// through genType and unit tests can exercise them directly.

@genType type graphNode = Protocol.graphNode
@genType type graphEdge = Protocol.graphEdge

// A write-side box (Aggregate / StateChangeSlice) anchors a vertical slice.
let isWriteSide = (kind: string): bool =>
  switch kind {
  | "Aggregate" | "StateChangeSlice" => true
  | _ => false
  }

// Command/event leaves are the nodes a write-side box pulls in.
let isLeaf = (kind: string): bool => kind === "Command" || kind === "Event"

// Read-side boxes (incl. their `Stream` variants) each anchor a read slice.
let isReadSide = (kind: string): bool =>
  switch kind {
  | "StateViewSlice" | "StateViewSliceStream" | "ReadModel" | "ReadModelStream" => true
  | _ => false
  }

// Only ownership edges (handles / emits) pull a leaf into a box — a DCB `reads` edge
// connects an event to a *different* consuming slice and must not move it.
let isOwnershipEdge = (kind: string): bool => kind === "handles" || kind === "emits"

let addUnique = (m: Dict.t<array<string>>, k: string, v: string): unit =>
  switch m->Dict.get(k) {
  | Some(a) => a->Array.includes(v) ? () : a->Array.push(v)
  | None => m->Dict.set(k, [v])
  }

/** Node id → write-side slice id for the Event Graph's write-side boxes. Each
    Aggregate / StateChangeSlice anchors a slice (`"<writeSideId>::slice"`) that also
    pulls in the command(s) it handles + event(s) it emits. A leaf owned by more than
    one write-side is left unboxed (a D2 node lives in one container only). */
@genType
let slicesForNodes = (nodes: array<graphNode>, edges: array<graphEdge>): array<(string, string)> => {
  let byId = Dict.make()
  nodes->Array.forEach(n => byId->Dict.set(n.id, n))
  // leaf id → write-side ids owning it; write-side id → leaf ids it owns.
  let wsByLeaf: Dict.t<array<string>> = Dict.make()
  let leavesByWs: Dict.t<array<string>> = Dict.make()
  edges->Array.forEach(e =>
    if isOwnershipEdge(e.kind) {
      switch (byId->Dict.get(e.from), byId->Dict.get(e.to_)) {
      | (Some(a), Some(b)) =>
        let pair =
          isWriteSide(a.kind) && isLeaf(b.kind)
            ? Some((a, b))
            : isWriteSide(b.kind) && isLeaf(a.kind)
            ? Some((b, a))
            : None
        switch pair {
        | Some((ws, leaf)) =>
          addUnique(wsByLeaf, leaf.id, ws.id)
          addUnique(leavesByWs, ws.id, leaf.id)
        | None => ()
        }
      | _ => ()
      }
    }
  )
  let out = []
  nodes->Array.forEach(w =>
    if isWriteSide(w.kind) {
      let sliceId = w.id ++ "::slice"
      out->Array.push((w.id, sliceId))
      switch leavesByWs->Dict.get(w.id) {
      | Some(leaves) =>
        leaves->Array.forEach(leafId =>
          switch wsByLeaf->Dict.get(leafId) {
          | Some(owners) if Array.length(owners) === 1 => out->Array.push((leafId, sliceId))
          | _ => ()
          }
        )
      | None => ()
      }
    }
  )
  out
}

/** Node id → read-side slice id — the read-box mirror of `slicesForNodes`. Each
    ReadModel / StateViewSlice (and their Stream variants) wraps only its anchor; the
    event(s) it projects already live in their emitting write-side box. */
@genType
let readSlicesForNodes = (nodes: array<graphNode>): array<(string, string)> =>
  nodes->Array.filter(n => isReadSide(n.kind))->Array.map(n => (n.id, n.id ++ "::read-slice"))

/** Chapter membership for every graph node, given a `seed` of the component nodes
    whose chapter the host already resolved (`nodeId → chapter`). A command/event leaf
    carries no chapter of its own, so it inherits the chapter of the FIRST adjacent
    seeded node (in edge order) — this attributes a slice's command/event boxes to the
    slice's chapter. Seeds pass through unchanged; the order is seed-order then
    node-order, so downstream chapter grouping renders deterministically. Pure — the
    host builds the seed; this does only the graph propagation. */
@genType
let propagateChapters = (
  nodes: array<graphNode>,
  edges: array<graphEdge>,
  seed: array<(string, string)>,
): array<(string, string)> => {
  let byNode: Dict.t<string> = Dict.make()
  seed->Array.forEach(((id, ch)) => byNode->Dict.set(id, ch))
  nodes->Array.forEach(n =>
    if byNode->Dict.get(n.id)->Option.isNone && isLeaf(n.kind) {
      let assigned = ref(false)
      edges->Array.forEach(e =>
        if !assigned.contents {
          let otherId = e.from === n.id ? Some(e.to_) : e.to_ === n.id ? Some(e.from) : None
          switch otherId {
          | Some(oid) =>
            switch byNode->Dict.get(oid) {
            | Some(ch) =>
              byNode->Dict.set(n.id, ch)
              assigned := true
            | None => ()
            }
          | None => ()
          }
        }
      )
    }
  )
  byNode->Dict.toArray
}

/** A candidate DCB read edge gathered by the host: a producer event node → a consuming
    slice node, and whether it is a cross-partition (M:N) read (drawn with a distinct
    style). */
@genType
type readCandidate = {eventId: string, sliceId: string, crossPartition: bool}

/** The DCB read edges (`reads` / `readsCrossPartition`) to ADD to the graph for the
    given candidates: only where BOTH endpoints exist as nodes, the pair isn't already
    connected in EITHER direction, and the pair isn't already emitted by an earlier
    candidate. Pure — the host gathers the candidates and pushes the returned edges
    onto its merged graph. */
@genType
let readEdgesToAdd = (
  nodes: array<graphNode>,
  edges: array<graphEdge>,
  candidates: array<readCandidate>,
): array<graphEdge> => {
  let nodeIds = Set.make()
  nodes->Array.forEach(n => nodeIds->Set.add(n.id))
  let connected = Set.make()
  edges->Array.forEach(e => {
    connected->Set.add(e.from ++ "|" ++ e.to_)
    connected->Set.add(e.to_ ++ "|" ++ e.from)
  })
  let seen = Set.make()
  let out: array<graphEdge> = []
  candidates->Array.forEach(c => {
    let k = c.eventId ++ "|" ++ c.sliceId
    if (
      nodeIds->Set.has(c.eventId) &&
      nodeIds->Set.has(c.sliceId) &&
      !(connected->Set.has(k)) &&
      !(seen->Set.has(k))
    ) {
      seen->Set.add(k)
      out->Array.push({
        from: c.eventId,
        to_: c.sliceId,
        kind: c.crossPartition ? "readsCrossPartition" : "reads",
      })
    }
  })
  out
}

// A component may surface in the graph under a `Stream` variant kind (a
// `StateViewSliceStream` component becomes a `StateViewSlice` node, etc.), so kind
// comparisons between an inventory and the graph ignore the `Stream` suffix.
@genType
let baseKind = (k: string): string => k->String.replaceRegExp(%re("/Stream$/"), "")

// Is `name` one of the dotted segments of `label`? EP/Extension graph labels are
// fully-qualified (e.g. "Catalog.Products"); an inventory carries a single segment.
@genType
let isDottedSegment = (label: string, name: string): bool =>
  ("." ++ label ++ ".")->String.includes("." ++ name ++ ".")

// EP/Extension nodes carry a dotted (fully-qualified) label; other kinds a bare name.
let isFqKind = (kind: string): bool => kind === "ExtensionPoint" || kind === "Extension"

// A command/event leaf adjacent to a component node — the host enriches these with
// field rows / consumers / orphan flags after resolving them.
@genType type graphLeaf = {id: string, label: string}
@genType type leafGroups = {commands: array<graphLeaf>, events: array<graphLeaf>}

/** Command/event nodes adjacent to `nodeId`, each as {id, label} — deduped by id and
    sorted by label. (Command/event labels are PascalCase type names, so a code-point
    `String.compare` orders them like a locale compare would.) */
@genType
let cmdEvtForNode = (
  nodes: array<graphNode>,
  edges: array<graphEdge>,
  nodeId: string,
): leafGroups => {
  let byId = Dict.make()
  nodes->Array.forEach((n: graphNode) => byId->Dict.set(n.id, n))
  let cmds = Dict.make()
  let evts = Dict.make()
  edges->Array.forEach((e: graphEdge) => {
    let other =
      e.from === nodeId
        ? byId->Dict.get(e.to_)
        : e.to_ === nodeId
        ? byId->Dict.get(e.from)
        : None
    switch other {
    | Some(o) =>
      if o.kind === "Command" {
        cmds->Dict.set(o.id, o.label)
      } else if o.kind === "Event" {
        evts->Dict.set(o.id, o.label)
      }
    | None => ()
    }
  })
  let toLeaves = (m: Dict.t<string>): array<graphLeaf> =>
    m
    ->Dict.toArray
    ->Array.map(((id, label)) => {id, label})
    ->Array.toSorted((a, b) => String.compare(a.label, b.label))
  {commands: toLeaves(cmds), events: toLeaves(evts)}
}

/** Resolve an inventory component (kind + short name) to its graph node — the source
    of truth for the fully-qualified display name and adjacent command/event types.
    Graphs key nodes by framework plugin name, not the package name, so we match on
    kind + name: write/read/automation nodes by the bare name, EP/Extension by a dotted
    segment. `None` until a `graph` event has arrived. */
@genType
let graphNodeForComponent = (
  nodes: array<graphNode>,
  kind: string,
  name: string,
): option<graphNode> =>
  isFqKind(kind)
    ? nodes->Array.find((n: graphNode) => n.kind === kind && isDottedSegment(n.label, name))
    : nodes->Array.find((n: graphNode) => baseKind(n.kind) === baseKind(kind) && n.label === name)

/** Node id for a component, resolving (in order) an exact fully-qualified label, then a
    same-kind bare-name match, then a same-kind dotted-segment match. Kind-restricted so
    a same-named node of another kind can't be picked. Shared by graph focus and
    selection-sync flows. */
@genType
let resolveComponentNodeId = (
  nodes: array<graphNode>,
  kind: string,
  name: string,
  fq: option<string>,
): option<string> => {
  let sameKind = (n: graphNode) => baseKind(n.kind) === baseKind(kind)
  let lastSeg = s => s->String.slice(~start=s->String.lastIndexOf(".") + 1, ~end=String.length(s))
  let byFq = switch fq {
  | Some(v) => nodes->Array.find(n => n.label === v)
  | None => None
  }
  let match_ = switch byFq {
  | Some(_) as m => m
  | None =>
    switch nodes->Array.find(n => sameKind(n) && n.label === name) {
    | Some(_) as m => m
    | None =>
      nodes->Array.find(n =>
        sameKind(n) && (lastSeg(n.label) === name || isDottedSegment(n.label, name))
      )
    }
  }
  match_->Option.map(n => n.id)
}
