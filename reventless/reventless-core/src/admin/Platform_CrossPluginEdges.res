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
    Handles two mechanisms:
    - EventTypeMatch: write-side in plugin A produces event types consumed by a SVS in plugin B.
    - Extension: an Extension in plugin A subscribes to an ExtensionPoint owned by plugin B
      (inferred from the dotted EP name prefix, e.g. "Catalog.Products" → owner "Catalog"). */
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

  // Collect StateViewSlices with their consumed event types.
  let svsConsumed =
    pluginEntries->Array.flatMap(((pluginName, structure)) =>
      structure.stateViewSlices->Array.map(svs => (pluginName, svs.name, svs.consumedEventTypes))
    )

  // EventTypeMatch: write-side in one plugin → SVS in a different plugin.
  writeSides->Array.forEach(((srcPlugin, srcComp, srcKind, produced)) => {
    svsConsumed->Array.forEach(((tgtPlugin, tgtSVS, consumed)) => {
      if srcPlugin != tgtPlugin {
        let viaEvents = produced->Array.filter(e => consumed->Array.includes(e))
        if viaEvents->Array.length > 0 {
          edges->Array.push({
            source: nodeFor(~pluginName=srcPlugin, ~name=srcComp, ~kind=srcKind),
            target: nodeFor(~pluginName=tgtPlugin, ~name=tgtSVS, ~kind="StateViewSlice"),
            mechanism: "EventTypeMatch",
            viaEvents,
            implicit: false,
          })
        }
      }
    })
  })

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
let sdlTypes = [
  `type Platform_GraphNode {\n  pluginName: String!\n  componentName: String!\n  kind: String!\n}`,
  `type Platform_GraphEdge {\n  source: Platform_GraphNode!\n  target: Platform_GraphNode!\n  mechanism: String!\n  viaEvents: [String!]!\n  implicit: Boolean!\n}`,
]

let sdlQueryField = `  platformCrossPluginEdges: [Platform_GraphEdge!]!`
