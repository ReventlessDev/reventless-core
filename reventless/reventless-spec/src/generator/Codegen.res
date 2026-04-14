// Renders a Pairing.resolved into Plugin.res source text.

// Strip suffix from a string if it ends with that suffix.
let stripSuffix = (s: string, suffix: string): string =>
  if s->String.endsWith(suffix) {
    s->String.slice(~start=0, ~end=s->String.length - suffix->String.length)
  } else {
    s
  }

// Derive EP module name from mapping stem: "ProductsExtensionPointMapping" → "ProductsExtensionPointMaker"
let epModuleName = (mappingStem: string): string =>
  stripSuffix(mappingStem, "Mapping") ++ "Maker"

// ── Section renderers ────────────────────────────────────────────────────────

let renderSlices = (
  ~platformFactory: string,
  ~suffix: string,
  stems: array<string>,
): array<string> =>
  stems->Array.map(stem =>
    "  module " ++ stem ++ suffix ++ " = Platform." ++ platformFactory ++ ".Make(" ++ stem ++ ")"
  )

let renderAggregates = (aggregates: array<Pairing.aggregateDef>): array<string> =>
  aggregates->Array.flatMap(({spec, behavior, eventMappings}) => {
    let em = eventMappings->Option.getOr("ReventlessInfra.NoEventMappings.Make(" ++ spec ++ ")")
    [
      "  module " ++ spec ++ "Aggregate = Platform.Aggregate.Make(",
      "    " ++ spec ++ ",",
      "    " ++ behavior ++ ",",
      "    " ++ em ++ ",",
      "  )",
    ]
  })

let renderReadModels = (readModels: array<Pairing.readModelDef>): array<string> =>
  readModels->Array.flatMap(({readModel, projections, mappingModules}) => {
    // Generate inline module list so @reventless.projections can infer the correct Mapping type
    let mappingEntries =
      mappingModules->Array.map(m => "module(" ++ projections ++ "." ++ m ++ ")")
    let mappingsLine = "    let mappings: array<module(Mapping)> = [" ++ mappingEntries->Array.join(", ") ++ "]"
    [
      "  @reventless.projections",
      "  module " ++ projections ++ "Wrapper: Mappings with module Target := " ++ readModel ++ " = {",
      mappingsLine,
      "  }",
      "  module " ++ readModel ++ "Maker = Platform.ReadModel.Make(" ++ readModel ++ ", " ++ projections ++ "Wrapper)",
    ]
  })

let renderTasks = (tasks: array<string>): array<string> =>
  tasks->Array.map(stem =>
    "  module " ++ stem ++ "Task = Platform.Task.Make(" ++ stem ++ ")"
  )

let renderExtensionPoints = (extensionPoints: array<Pairing.extensionPointDef>): array<string> =>
  extensionPoints->Array.flatMap(({group, mappings}) => {
    let count = mappings->Array.length
    let firstMapping = mappings->Array.getUnsafe(0)
    let moduleName = switch group {
    | None => epModuleName(firstMapping)
    | Some(g) => g ++ "Maker"
    }
    switch count {
    | 0 => []
    | 1 =>
      ["  module " ++ moduleName ++ " = Platform.ExtensionPoint.Make(" ++ firstMapping ++ ")"]
    | 2 =>
      let m2 = mappings->Array.getUnsafe(1)
      [
        "  module " ++ moduleName ++ " = Platform.ExtensionPoint.Make2(",
        "    " ++ firstMapping ++ ",",
        "    " ++ m2 ++ ",",
        "  )",
      ]
    | 3 =>
      let m2 = mappings->Array.getUnsafe(1)
      let m3 = mappings->Array.getUnsafe(2)
      [
        "  module " ++ moduleName ++ " = Platform.ExtensionPoint.Make3(",
        "    " ++ firstMapping ++ ",",
        "    " ++ m2 ++ ",",
        "    " ++ m3 ++ ",",
        "  )",
      ]
    | _ =>
      // MakeMulti — inline module expression
      let mappingLines =
        mappings->Array.map(m => "      module(" ++ m ++ "),")
      Array.flat([
        [
          "  module " ++ moduleName ++ " = Platform.ExtensionPoint.MakeMulti({",
          "    module Spec = " ++ firstMapping ++ ".ExtensionPoint",
          "    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec",
          "    let name = Spec.name",
          "    let moduleUrl: string = %raw(`import.meta.url`)",
          "    let mappings: array<module(Mapping)> = [",
        ],
        mappingLines,
        [
          "    ]",
          "  })",
        ],
      ])
    }
  })

let renderExtensions = (extensions: array<string>): array<string> =>
  extensions->Array.map(stem =>
    "  module " ++ stem ++ "Maker = Platform.Extension.Make(" ++ stem ++ ".Mapping)"
  )

// ── make() call ──────────────────────────────────────────────────────────────

let renderMakeParam = (
  ~param: string,
  ~items: array<string>,
  ~moduleSuffix: string,
): option<string> =>
  if items->Array.length === 0 {
    None
  } else {
    let entries = items->Array.map(s => "module(" ++ s ++ moduleSuffix ++ ")")
    Some("      ~" ++ param ++ "=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderReadModelMakeParam = (readModels: array<Pairing.readModelDef>): option<string> =>
  if readModels->Array.length === 0 {
    None
  } else {
    let entries = readModels->Array.map(({readModel}) => "module(" ++ readModel ++ "Maker)")
    Some("      ~readModels=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderAggregateMakeParam = (aggregates: array<Pairing.aggregateDef>): option<string> =>
  if aggregates->Array.length === 0 {
    None
  } else {
    let entries = aggregates->Array.map(({spec}) => "module(" ++ spec ++ "Aggregate)")
    Some("      ~aggregates=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderEpMakeParam = (extensionPoints: array<Pairing.extensionPointDef>): option<string> =>
  if extensionPoints->Array.length === 0 {
    None
  } else {
    let entries = extensionPoints->Array.map(({group, mappings}) => {
      let firstMapping = mappings->Array.getUnsafe(0)
      let moduleName = switch group {
      | None => epModuleName(firstMapping)
      | Some(g) => g ++ "Maker"
      }
      "module(" ++ moduleName ++ ")"
    })
    Some("      ~extensionPoints=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderExtensionMakeParam = (extensions: array<string>): option<string> =>
  if extensions->Array.length === 0 {
    None
  } else {
    let entries = extensions->Array.map(s => "module(" ++ s ++ "Maker)")
    Some("      ~extensions=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderTaskMakeParam = (tasks: array<string>): option<string> =>
  if tasks->Array.length === 0 {
    None
  } else {
    let entries = tasks->Array.map(s => "module(" ++ s ++ "Task)")
    Some("      ~tasks=[" ++ entries->Array.join(", ") ++ "],")
  }

// ── Top-level render ─────────────────────────────────────────────────────────

let render = (~config: Config.config, ~resolved: Pairing.resolved): string => {
  let hasReadModels = resolved.readModels->Array.length > 0
  let lines: array<string> = []

  // Header
  lines->Array.push("// AUTO-GENERATED — do not edit. Run `npm run generate` to update.")

  // Open Reventless.Projection only when ReadModels are present
  if hasReadModels {
    lines->Array.push("open Reventless.Projection")
    lines->Array.push("")
  }

  lines->Array.push("module Make = (Platform: ReventlessInfra.Platform.T) => {")

  // StateChangeSlices
  if resolved.stateChangeSlices->Array.length > 0 {
    lines->Array.push("  // StateChangeSlices")
    renderSlices(~platformFactory="StateChangeSlice", ~suffix="Slice", resolved.stateChangeSlices)
    ->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // StateViewSlices
  if resolved.stateViewSlices->Array.length > 0 {
    lines->Array.push("  // StateViewSlices")
    renderSlices(~platformFactory="StateViewSlice", ~suffix="Slice", resolved.stateViewSlices)
    ->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // AutomationSlices
  if resolved.automationSlices->Array.length > 0 {
    lines->Array.push("  // AutomationSlices")
    renderSlices(~platformFactory="AutomationSlice", ~suffix="Slice", resolved.automationSlices)
    ->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // OutboundTranslationSlices
  if resolved.outboundTranslationSlices->Array.length > 0 {
    lines->Array.push("  // OutboundTranslationSlices")
    renderSlices(
      ~platformFactory="OutboundTranslationSlice",
      ~suffix="Slice",
      resolved.outboundTranslationSlices,
    )->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // InboundTranslationSlices
  if resolved.inboundTranslationSlices->Array.length > 0 {
    lines->Array.push("  // InboundTranslationSlices")
    renderSlices(
      ~platformFactory="InboundTranslationSlice",
      ~suffix="Slice",
      resolved.inboundTranslationSlices,
    )->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // Aggregates
  if resolved.aggregates->Array.length > 0 {
    lines->Array.push("  // Aggregates")
    renderAggregates(resolved.aggregates)->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // ReadModels
  if resolved.readModels->Array.length > 0 {
    lines->Array.push("  // ReadModels")
    renderReadModels(resolved.readModels)->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // Tasks
  if resolved.tasks->Array.length > 0 {
    lines->Array.push("  // Tasks")
    renderTasks(resolved.tasks)->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // ExtensionPoints
  if resolved.extensionPoints->Array.length > 0 {
    lines->Array.push("  // ExtensionPoints")
    renderExtensionPoints(resolved.extensionPoints)->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // Extensions
  if resolved.extensions->Array.length > 0 {
    lines->Array.push("  // Extensions")
    renderExtensions(resolved.extensions)->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // make() call
  lines->Array.push("  let make = () =>")
  lines->Array.push("    Platform.Plugin.make(")
  lines->Array.push("      ~name=\"" ++ config.name ++ "\",")
  lines->Array.push("      ~heartbeatInterval=" ++ config.heartbeatInterval->Int.toString ++ ",")

  let makeParams = [
    renderEpMakeParam(resolved.extensionPoints),
    renderExtensionMakeParam(resolved.extensions),
    renderAggregateMakeParam(resolved.aggregates),
    renderReadModelMakeParam(resolved.readModels),
    renderTaskMakeParam(resolved.tasks),
    renderMakeParam(~param="stateChangeSlices", ~items=resolved.stateChangeSlices, ~moduleSuffix="Slice"),
    renderMakeParam(~param="stateViewSlices", ~items=resolved.stateViewSlices, ~moduleSuffix="Slice"),
    renderMakeParam(~param="automationSlices", ~items=resolved.automationSlices, ~moduleSuffix="Slice"),
    renderMakeParam(
      ~param="outboundTranslationSlices",
      ~items=resolved.outboundTranslationSlices,
      ~moduleSuffix="Slice",
    ),
    renderMakeParam(
      ~param="inboundTranslationSlices",
      ~items=resolved.inboundTranslationSlices,
      ~moduleSuffix="Slice",
    ),
  ]

  makeParams->Array.filterMap(x => x)->Array.forEach(line => lines->Array.push(line))

  lines->Array.push("    )")
  lines->Array.push("}")
  lines->Array.push("")

  lines->Array.join("\n")
}
