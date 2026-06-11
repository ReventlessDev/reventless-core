// Cross-plugin edge assembly for Platform_EventGraph.
// Pure query-time computation over pluginStructure entries from all connected plugins.
// Registered as `platformCrossPluginEdges` in the in-memory platform admin GraphQL server.

open Reventless.Plugin

let pluginPrefix = (name: string): string => {
  let idx = name->String.indexOf(".")
  if idx > 0 {
    name->String.slice(~start=0, ~end=idx)
  } else {
    ""
  }
}

/** Compute cross-plugin edges from all known pluginStructure entries.
    Handles four mechanisms:
    - EventTypeMatch: write-side in plugin A produces event types consumed by a
      StateViewSlice, AutomationSlice, or OutboundTranslationSlice in plugin B.
    - AutomationSlice: an AutomationSlice in plugin A routes commands to a writable
      (aggregate or StateChangeSlice) in plugin B, identified by `targetName`.
    - InboundTranslation: an InboundTranslationSlice in plugin A routes translated
      commands to a writable in plugin B, identified by `targetName`.
    - Extension: an Extension in plugin A subscribes to an ExtensionPoint owned by
      plugin B (inferred from the dotted EP name prefix, e.g. "Catalog.Products"
      → owner "Catalog"). */
let computeEdges = (pluginEntries: array<(string, pluginStructure)>): array<graphEdge> => {
  let edges: array<graphEdge> = []

  let nodeFor = (~pluginName, ~name as componentName, ~kind): graphNode => {
    pluginName,
    componentName,
    kind,
  }

  // Collect write-side components with their produced event types.
  let writeSides =
    pluginEntries->Array.flatMap(((pluginName, structure)) =>
      Array.concat(
        structure.aggregates->Array.map(a => (pluginName, a.name, "Aggregate", a.producedEventTypes)),
        structure.stateChangeSlices->Array.map(s => (
          pluginName,
          s.name,
          "StateChangeSlice",
          s.producedEventTypes,
        )),
      )
    )

  // Collect every event-consuming component (SVS, AutomationSlice, OutboundTranslationSlice).
  let eventConsumers =
    pluginEntries->Array.flatMap(((pluginName, structure)) =>
      Array.flat([
        // Internal slices are carried in pluginStructure for developer tooling but are
        // hidden from the deployed AutoUI's web event graph — skip them here so they gain
        // no cross-plugin edges (the dev `DomainGraph` builds its own intra-plugin edges).
        structure.stateViewSlices
        ->Array.filter(svs => svs.visibility != Some("Internal"))
        ->Array.map(svs => (pluginName, svs.name, "StateViewSlice", svs.consumedEventTypes)),
        structure.automationSlices->Array.map(a => (
          pluginName,
          a.name,
          "AutomationSlice",
          a.consumedEventTypes,
        )),
        structure.outboundTranslationSlices->Array.map(o => (
          pluginName,
          o.name,
          "OutboundTranslationSlice",
          o.consumedEventTypes,
        )),
      ])
    )

  // Resolution helper: which plugin owns a given writable (aggregate or SCS)?
  // Returns (pluginName, kind) where kind is "Aggregate" or "StateChangeSlice".
  let findWritableOwner = (~name): option<(string, string)> => {
    let owner = ref(None)
    pluginEntries->Array.forEach(((pluginName, structure)) =>
      switch owner.contents {
      | Some(_) => ()
      | None =>
        if structure.aggregates->Array.some(a => a.name == name) {
          owner := Some((pluginName, "Aggregate"))
        } else if structure.stateChangeSlices->Array.some(s => s.name == name) {
          owner := Some((pluginName, "StateChangeSlice"))
        }
      }
    )
    owner.contents
  }

  // EventTypeMatch: write-side in one plugin → event consumer in a different plugin.
  writeSides->Array.forEach(((srcPlugin, srcComp, srcKind, produced)) => {
    eventConsumers->Array.forEach(((tgtPlugin, tgtComp, tgtKind, consumed)) => {
      if srcPlugin != tgtPlugin {
        let viaEvents = produced->Array.filter(e => consumed->Array.includes(e))
        if viaEvents->Array.length > 0 {
          edges->Array.push({
            source: nodeFor(~pluginName=srcPlugin, ~name=srcComp, ~kind=srcKind),
            target: nodeFor(~pluginName=tgtPlugin, ~name=tgtComp, ~kind=tgtKind),
            mechanism: "EventTypeMatch",
            viaEvents,
            implicit: false,
          })
        }
      }
    })
  })

  // AutomationSlice → cross-plugin writable target.
  // viaEvents holds the produced command type names (the field name is shared with
  // EventTypeMatch by design — see SDL comment).
  pluginEntries->Array.forEach(((pluginName, structure)) =>
    structure.automationSlices->Array.forEach(a =>
      switch findWritableOwner(~name=a.targetName) {
      | Some((tgtPlugin, tgtKind)) if tgtPlugin != pluginName =>
        edges->Array.push({
          source: nodeFor(~pluginName, ~name=a.name, ~kind="AutomationSlice"),
          target: nodeFor(~pluginName=tgtPlugin, ~name=a.targetName, ~kind=tgtKind),
          mechanism: "AutomationSlice",
          viaEvents: a.producedCommandTypes,
          implicit: false,
        })
      | _ => ()
      }
    )
  )

  // InboundTranslationSlice → cross-plugin writable target.
  pluginEntries->Array.forEach(((pluginName, structure)) =>
    structure.inboundTranslationSlices->Array.forEach(its =>
      switch findWritableOwner(~name=its.targetName) {
      | Some((tgtPlugin, tgtKind)) if tgtPlugin != pluginName =>
        edges->Array.push({
          source: nodeFor(~pluginName, ~name=its.name, ~kind="InboundTranslationSlice"),
          target: nodeFor(~pluginName=tgtPlugin, ~name=its.targetName, ~kind=tgtKind),
          mechanism: "InboundTranslation",
          viaEvents: its.commandTypes,
          implicit: false,
        })
      | _ => ()
      }
    )
  )

  // Extension → ExtensionPoint: infer EP owner plugin from dotted name prefix.
  pluginEntries->Array.forEach(((pluginName, structure)) => {
    structure.extensions->Array.forEach(ext => {
      let ownerPlugin = pluginPrefix(ext.name)
      if ownerPlugin != "" && ownerPlugin != pluginName {
        edges->Array.push({
          source: nodeFor(~pluginName=ownerPlugin, ~name=ext.name, ~kind="ExtensionPoint"),
          target: nodeFor(~pluginName=pluginName, ~name=ext.name, ~kind="Extension"),
          mechanism: "Extension",
          viaEvents: ext.commandTypes,
          implicit: false,
        })
      }
    })
  })

  edges
}

// GraphQL SDL type definitions for the platformCrossPluginEdges query.
// `viaEvents` is interpreted by `mechanism`:
//   - EventTypeMatch / Extension → list of event type names
//   - AutomationSlice / InboundTranslation → list of command type names
let sdlTypes = [
  `type Platform_GraphNode {\n  pluginName: String!\n  componentName: String!\n  kind: String!\n}`,
  `type Platform_GraphEdge {\n  source: Platform_GraphNode!\n  target: Platform_GraphNode!\n  mechanism: String!\n  viaEvents: [String!]!\n  implicit: Boolean!\n}`,
]

let sdlQueryField = `  platformCrossPluginEdges: [Platform_GraphEdge!]!`
