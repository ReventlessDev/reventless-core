@@reventless.spec("PlatformEventGraph")

open Reventless.Plugin

@schema
type state = {
  pluginName: string,
  nodes: array<graphNode>,
  edges: array<graphEdge>,
}

let nodeFor = (~pluginName, ~name as componentName, ~kind): graphNode => {
  pluginName,
  componentName,
  kind,
}

let writeKind = (~structure: pluginStructure, name): string =>
  if structure.aggregates->Array.some(a => a.name == name) {
    "Aggregate"
  } else {
    "StateChangeSlice"
  }

let nodesFromStructure = (~pluginName, structure: pluginStructure): array<graphNode> =>
  Array.flat([
    structure.aggregates->Array.map(({name}) => nodeFor(~pluginName, ~name, ~kind="Aggregate")),
    structure.stateChangeSlices->Array.map(({name}) =>
      nodeFor(~pluginName, ~name, ~kind="StateChangeSlice")
    ),
    structure.stateViewSlices->Array.map(({name}) =>
      nodeFor(~pluginName, ~name, ~kind="StateViewSlice")
    ),
    structure.readModels->Array.map(({name}) => nodeFor(~pluginName, ~name, ~kind="ReadModel")),
    structure.automationSlices->Array.map(({name}) =>
      nodeFor(~pluginName, ~name, ~kind="AutomationSlice")
    ),
    structure.outboundTranslationSlices->Array.map(({name}) =>
      nodeFor(~pluginName, ~name, ~kind="OutboundTranslationSlice")
    ),
    structure.inboundTranslationSlices->Array.map(({name}) =>
      nodeFor(~pluginName, ~name, ~kind="InboundTranslationSlice")
    ),
    structure.extensions->Array.map(({name}) => nodeFor(~pluginName, ~name, ~kind="Extension")),
  ])

let edgesFromStructure = (~pluginName, structure: pluginStructure): array<graphEdge> => {
  let wk = name => writeKind(~structure, name)

  let writeToView =
    Array.concat(
      structure.aggregates->Array.map(w => (w, "Aggregate")),
      structure.stateChangeSlices->Array.map(w => (w, "StateChangeSlice")),
    )->Array.flatMap(((w, kind)) =>
      w.linkedViews->Array.map(viewName => ({
        source: nodeFor(~pluginName, ~name=w.name, ~kind),
        target: nodeFor(~pluginName, ~name=viewName, ~kind="StateViewSlice"),
        mechanism: "EventTypeMatch",
        viaEvents: w.producedEventTypes,
        implicit: false,
      }: graphEdge))
    )

  let autoToTarget =
    structure.automationSlices->Array.map(a => ({
      source: nodeFor(~pluginName, ~name=a.name, ~kind="AutomationSlice"),
      target: nodeFor(~pluginName, ~name=a.targetName, ~kind=wk(a.targetName)),
      mechanism: "AutomationSlice",
      viaEvents: a.producedCommandTypes,
      implicit: false,
    }: graphEdge))

  let inboundToTarget =
    structure.inboundTranslationSlices->Array.map(its => ({
      source: nodeFor(~pluginName, ~name=its.name, ~kind="InboundTranslationSlice"),
      target: nodeFor(~pluginName, ~name=its.targetName, ~kind=wk(its.targetName)),
      mechanism: "InboundTranslation",
      viaEvents: its.commandTypes,
      implicit: false,
    }: graphEdge))

  let extensionToDelegate =
    structure.extensions->Array.flatMap(ext =>
      ext.delegateNames->Array.map(delegateName => ({
        source: nodeFor(~pluginName, ~name=ext.name, ~kind="Extension"),
        target: nodeFor(~pluginName, ~name=delegateName, ~kind=wk(delegateName)),
        mechanism: "Extension",
        viaEvents: ext.commandTypes,
        implicit: false,
      }: graphEdge))
    )

  Array.flat([writeToView, autoToTarget, inboundToTarget, extensionToDelegate])
}

let buildEntry = (~pluginName, structure: pluginStructure): state => {
  pluginName,
  nodes: nodesFromStructure(~pluginName, structure),
  edges: edgesFromStructure(~pluginName, structure),
}
