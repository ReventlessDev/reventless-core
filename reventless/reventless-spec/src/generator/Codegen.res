// Renders a Pairing.resolved into Plugin.res source text.

// Strip suffix from a string if it ends with that suffix.
let stripSuffix = (s: string, suffix: string): string =>
  if s->String.endsWith(suffix) {
    s->String.slice(~start=0, ~end=s->String.length - suffix->String.length)
  } else {
    s
  }

// Derive EP module name from mapping stem: "ProductsExtensionPointMapping" → "ProductsExtensionPoint"
let epModuleName = (mappingStem: string): string => stripSuffix(mappingStem, "Mapping")

// ── Section renderers ────────────────────────────────────────────────────────

let renderSlices = (
  ~platformFactory: string,
  ~suffix: string,
  ~implSuffix: string,
  stems: array<string>,
): array<string> =>
  stems->Array.map(stem =>
    "  module "
    ++ stem
    ++ suffix
    ++ " = Platform."
    ++ platformFactory
    ++ ".Make("
    ++ stem
    ++ ", "
    ++ stem
    ++ implSuffix
    ++ ")"
  )

// AutomationSlice has an extra `Mappings` arg (Plan 04) — emits a 3-arg
// `Platform.AutomationSlice.Make(<Stem>, <Stem>_Automation, <Stem>_Mappings)`.
let renderAutomationSlices = (stems: array<string>): array<string> =>
  stems->Array.map(stem =>
    "  module "
    ++ stem
    ++ "Slice = Platform.AutomationSlice.Make("
    ++ stem
    ++ ", "
    ++ stem
    ++ "_Automation, "
    ++ stem
    ++ "_Mappings)"
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
      "  module " ++ readModel ++ " = Platform.ReadModel.Make(" ++ readModel ++ ", " ++ projections ++ "Wrapper)",
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
    | Some(g) => g
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
    "  module " ++ stem ++ " = Platform.Extension.Make(" ++ stem ++ ".Mapping)"
  )

// AWS-specific renderers were removed in favour of the canonical ones — the
// AWS Plugin.res now emits `open <Namespace>` so bare stems resolve, and the
// AWS Platform.{Aggregate,ReadModel}.Make functors delegate to the
// `*_Builder_Single` strategy under the hood (see reventless-aws/src/Platform.res).

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

let renderStateViewSlicesMakeParam = (
  slices: array<string>,
  streamSlices: array<string>,
): option<string> => {
  let entries = Array.flat([
    slices->Array.map(s => "module(" ++ s ++ "Slice)"),
    streamSlices->Array.map(s => "module(" ++ s ++ "StreamSlice)"),
  ])
  if entries->Array.length === 0 {
    None
  } else {
    Some("      ~stateViewSlices=[" ++ entries->Array.join(", ") ++ "],")
  }
}

let renderReadModelMakeParam = (readModels: array<Pairing.readModelDef>): option<string> =>
  if readModels->Array.length === 0 {
    None
  } else {
    let entries = readModels->Array.map(({readModel}) => "module(" ++ readModel ++ ")")
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
      | Some(g) => g
      }
      "module(" ++ moduleName ++ ")"
    })
    Some("      ~extensionPoints=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderExtensionMakeParam = (extensions: array<string>): option<string> =>
  if extensions->Array.length === 0 {
    None
  } else {
    let entries = extensions->Array.map(s => "module(" ++ s ++ ")")
    Some("      ~extensions=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderTaskMakeParam = (tasks: array<string>): option<string> =>
  if tasks->Array.length === 0 {
    None
  } else {
    let entries = tasks->Array.map(s => "module(" ++ s ++ "Task)")
    Some("      ~tasks=[" ++ entries->Array.join(", ") ++ "],")
  }

let renderPluginStructureCall = (
  ~name: string,
  ~aggregates: array<Pairing.aggregateDef>,
  ~readModels: array<Pairing.readModelDef>,
  ~stateViewSlices: array<string>,
  ~stateViewSlicesStream: array<string>,
  ~stateChangeSlices: array<string>,
  ~automationSlices: array<string>,
  ~outboundTranslationSlices: array<string>,
  ~inboundTranslationSlices: array<string>,
  ~extensions: array<string>,
): option<array<string>> => {
  let hasComponents =
    aggregates->Array.length > 0 ||
    readModels->Array.length > 0 ||
    stateViewSlices->Array.length > 0 ||
    stateViewSlicesStream->Array.length > 0 ||
    stateChangeSlices->Array.length > 0 ||
    automationSlices->Array.length > 0 ||
    outboundTranslationSlices->Array.length > 0 ||
    inboundTranslationSlices->Array.length > 0 ||
    extensions->Array.length > 0
  if !hasComponents {
    None
  } else {
    let ls: array<string> = []
    ls->Array.push("  let pluginStructure = Platform.Plugin.makePluginDefinition(")
    ls->Array.push("    ~name=\"" ++ name ++ "\",")
    if aggregates->Array.length > 0 {
      let entries = aggregates->Array.map(({spec}) => "module(" ++ spec ++ "Aggregate)")
      ls->Array.push("    ~aggregates=[" ++ entries->Array.join(", ") ++ "],")
    }
    if readModels->Array.length > 0 {
      let entries = readModels->Array.map(({readModel}) => "module(" ++ readModel ++ ")")
      ls->Array.push("    ~readModels=[" ++ entries->Array.join(", ") ++ "],")
    }
    let allStateViewEntries = Array.flat([
      stateViewSlices->Array.map(s => "module(" ++ s ++ "Slice)"),
      stateViewSlicesStream->Array.map(s => "module(" ++ s ++ "StreamSlice)"),
    ])
    if allStateViewEntries->Array.length > 0 {
      ls->Array.push("    ~stateViewSlices=[" ++ allStateViewEntries->Array.join(", ") ++ "],")
    }
    if stateChangeSlices->Array.length > 0 {
      let entries = stateChangeSlices->Array.map(s => "module(" ++ s ++ "Slice)")
      ls->Array.push("    ~stateChangeSlices=[" ++ entries->Array.join(", ") ++ "],")
    }
    if automationSlices->Array.length > 0 {
      let entries = automationSlices->Array.map(s => "module(" ++ s ++ "Slice)")
      ls->Array.push("    ~automationSlices=[" ++ entries->Array.join(", ") ++ "],")
    }
    if outboundTranslationSlices->Array.length > 0 {
      let entries = outboundTranslationSlices->Array.map(s => "module(" ++ s ++ "Slice)")
      ls->Array.push("    ~outboundTranslationSlices=[" ++ entries->Array.join(", ") ++ "],")
    }
    if inboundTranslationSlices->Array.length > 0 {
      let entries = inboundTranslationSlices->Array.map(s => "module(" ++ s ++ "Slice)")
      ls->Array.push("    ~inboundTranslationSlices=[" ++ entries->Array.join(", ") ++ "],")
    }
    if extensions->Array.length > 0 {
      let entries = extensions->Array.map(s => "module(" ++ s ++ ")")
      ls->Array.push("    ~extensions=[" ++ entries->Array.join(", ") ++ "],")
    }
    ls->Array.push("  )")
    Some(ls)
  }
}

// ── targetName validation ────────────────────────────────────────────────────

let validateSliceTargets = (~resolved: Pairing.resolved) => {
  let knownReceivers = Array.concat(
    resolved.aggregates->Array.map(({spec}) => spec),
    resolved.stateChangeSlices,
  )

  let check = (~kind: string, stem: string, target: option<string>) =>
    switch target {
    | None =>
      JsError.throwWithMessage(
        "Generator: " ++
        kind ++
        " `" ++
        stem ++
        "` is missing `let targetName = \"...\"`. Valid targets: " ++
        knownReceivers->Array.join(", "),
      )
    | Some(t) when !(knownReceivers->Array.includes(t)) =>
      JsError.throwWithMessage(
        "Generator: " ++
        kind ++
        " `" ++
        stem ++
        "` declares targetName = \"" ++
        t ++
        "\" but no such command receiver exists. Valid targets: " ++
        knownReceivers->Array.join(", "),
      )
    | Some(_) => ()
    }

  resolved.automationSlices->Array.forEach(stem =>
    check(
      ~kind="AutomationSlice",
      stem,
      resolved.automationSliceTargets->Dict.get(stem)->Option.getOr(None),
    )
  )

  resolved.inboundTranslationSlices->Array.forEach(stem =>
    check(
      ~kind="InboundTranslationSlice",
      stem,
      resolved.inboundTranslationSliceTargets->Dict.get(stem)->Option.getOr(None),
    )
  )

  // OutboundTranslationSlice: only validate when targetName = Some(name) (None = fire-and-forget)
  resolved.outboundTranslationSlices->Array.forEach(stem => {
    switch resolved.outboundTranslationSliceTargets->Dict.get(stem)->Option.getOr(None) {
    | Some(t) when !(knownReceivers->Array.includes(t)) =>
      JsError.throwWithMessage(
        "Generator: OutboundTranslationSlice `" ++
        stem ++
        "` declares targetName = Some(\"" ++
        t ++
        "\") but no such command receiver exists. Valid targets: " ++
        knownReceivers->Array.join(", "),
      )
    | _ => ()
    }
  })
}

// ── Main.res render (AWS mode only) ─────────────────────────────────────────

let renderMain = (~config: Config.config): string => {
  let name = config.name
  [
    "// AUTO-GENERATED — do not edit. Run `npm run generate` to update.",
    "// " ++ name ++ " plugin — AWS deployment.",
    "",
    "module Platform = ReventlessAws.Platform.Make()",
    "module " ++ name ++ " = Plugin.Make(Platform)",
    "",
    "let default = Platform.deployPlugin(",
    "  ~version=Reventless.PackageVersion.fromCaller(),",
    "  ~plugin=module(" ++ name ++ "),",
    ")",
    "",
  ]->Array.join("\n")
}

// ── Aws-variant render ───────────────────────────────────────────────────────
// The AWS Plugin.res just delegates to the source plugin's `Plugin.Make`
// functor; all slice/aggregate/readmodel declarations live in the standard
// variant. The eta-expanded `make = () => Composition.make(...)` is required because
// the standard `make`'s `(~uiBundleUrl: string=?, unit) => component` does not
// match `PluginMaker.make: unit => component` for first-class module packing.
//
// When the standard variant has UI components (aggregates or readmodels), AWS
// reads `<PLUGIN_NAME_SNAKE>_UI_BUNDLE_URL` from process.env and forwards it,
// matching the platform-in-memory convention so the same env var works in both
// deploy paths.

// Convert a PascalCase plugin name to SCREAMING_SNAKE_CASE for env var naming.
// "Ordering" → "ORDERING"; "OnlineShop" → "ONLINE_SHOP".
let pluginNameToEnvBase = (name: string): string =>
  name
  ->String.split("")
  ->Array.mapWithIndex((ch, i) => {
    let isUpper = ch !== "" && ch === ch->String.toUpperCase && ch !== ch->String.toLowerCase
    i > 0 && isUpper ? "_" ++ ch : ch
  })
  ->Array.join("")
  ->String.toUpperCase

let renderAwsWrapper = (
  ~name: string,
  ~compositionNamespace: string,
  ~hasUiComponents: bool,
): string => {
  let header = ["// AUTO-GENERATED — do not edit. Run `npm run generate` to update."]
  let externLines = if hasUiComponents {
    let envVar = pluginNameToEnvBase(name) ++ "_UI_BUNDLE_URL"
    [
      "",
      "@val external uiBundleUrl: option<string> = \"process.env." ++ envVar ++ "\"",
    ]
  } else {
    []
  }
  let functorLines = [
    "",
    "module Make = (",
    "  Platform: ReventlessInfra.Platform.T",
    "    with type api = ReventlessAws.Types.AppSync.api",
    "    and type role = ReventlessAws.Types.AppSync.role,",
    ") => {",
    "  module Composition = " ++ compositionNamespace ++ ".Plugin.Make(Platform)",
  ]
  let makeLines = hasUiComponents
    ? ["  let make = () => Composition.make(~uiBundleUrl?)"]
    : ["  let make = () => Composition.make()"]
  let footer = ["}", ""]
  Array.flat([header, externLines, functorLines, makeLines, footer])->Array.join("\n")
}

// ── Composition-variant render ───────────────────────────────────────────────

let renderComposition = (~config: Config.config, ~resolved: Pairing.resolved): string => {
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

  let push = (sectionLines: array<string>) => {
    sectionLines->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // StateChangeSlices
  if resolved.stateChangeSlices->Array.length > 0 {
    lines->Array.push("  // StateChangeSlices")
    renderSlices(
      ~platformFactory="StateChangeSlice",
      ~suffix="Slice",
      ~implSuffix=Pairing.implSuffixForStateChange,
      resolved.stateChangeSlices,
    )->push
  }

  // StateViewSlices
  if resolved.stateViewSlices->Array.length > 0 {
    lines->Array.push("  // StateViewSlices")
    renderSlices(
      ~platformFactory="StateViewSlice",
      ~suffix="Slice",
      ~implSuffix=Pairing.implSuffixForStateView,
      resolved.stateViewSlices,
    )->push
  }

  // StateViewSliceStreams
  if resolved.stateViewSlicesStream->Array.length > 0 {
    lines->Array.push("  // StateViewSliceStreams")
    renderSlices(
      ~platformFactory="StateViewSliceStream",
      ~suffix="StreamSlice",
      ~implSuffix=Pairing.implSuffixForStateView,
      resolved.stateViewSlicesStream,
    )->push
  }

  // AutomationSlices — Plan 04 3-arg form: (Spec, _Automation, _Mappings)
  if resolved.automationSlices->Array.length > 0 {
    lines->Array.push("  // AutomationSlices")
    renderAutomationSlices(resolved.automationSlices)->push
  }

  // OutboundTranslationSlices
  if resolved.outboundTranslationSlices->Array.length > 0 {
    lines->Array.push("  // OutboundTranslationSlices")
    renderSlices(
      ~platformFactory="OutboundTranslationSlice",
      ~suffix="Slice",
      ~implSuffix=Pairing.implSuffixForTranslation,
      resolved.outboundTranslationSlices,
    )->push
  }

  // InboundTranslationSlices
  if resolved.inboundTranslationSlices->Array.length > 0 {
    lines->Array.push("  // InboundTranslationSlices")
    renderSlices(
      ~platformFactory="InboundTranslationSlice",
      ~suffix="Slice",
      ~implSuffix=Pairing.implSuffixForTranslation,
      resolved.inboundTranslationSlices,
    )->push
  }

  // Aggregates
  if resolved.aggregates->Array.length > 0 {
    lines->Array.push("  // Aggregates")
    renderAggregates(resolved.aggregates)->push
  }

  // ReadModels
  if resolved.readModels->Array.length > 0 {
    lines->Array.push("  // ReadModels")
    renderReadModels(resolved.readModels)->push
  }

  // Tasks
  if resolved.tasks->Array.length > 0 {
    lines->Array.push("  // Tasks")
    renderTasks(resolved.tasks)->push
  }

  // ExtensionPoints
  if resolved.extensionPoints->Array.length > 0 {
    lines->Array.push("  // ExtensionPoints")
    renderExtensionPoints(resolved.extensionPoints)->push
  }

  // Extensions
  if resolved.extensions->Array.length > 0 {
    lines->Array.push("  // Extensions")
    renderExtensions(resolved.extensions)->push
  }

  // pluginStructure
  let pluginStructureLines = renderPluginStructureCall(
    ~name=config.name,
    ~aggregates=resolved.aggregates,
    ~readModels=resolved.readModels,
    ~stateViewSlices=resolved.stateViewSlices,
    ~stateViewSlicesStream=resolved.stateViewSlicesStream,
    ~stateChangeSlices=resolved.stateChangeSlices,
    ~automationSlices=resolved.automationSlices,
    ~outboundTranslationSlices=resolved.outboundTranslationSlices,
    ~inboundTranslationSlices=resolved.inboundTranslationSlices,
    ~extensions=resolved.extensions,
  )
  let hasPluginStructure = pluginStructureLines->Option.isSome
  switch pluginStructureLines {
  | Some(defLines) =>
    defLines->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  | None => ()
  }

  // make() call — Composition variant only (Aws variant uses renderAwsWrapper).
  // uiBundleUrl is only meaningful when the plugin has aggregates or read
  // models, since makeAutoUIManifest derives panels/pages from those kinds.
  let hasUiComponents = resolved.aggregates->Array.length > 0 || resolved.readModels->Array.length > 0
  let makeSig = hasUiComponents ? "  let make = (~uiBundleUrl=?) =>" : "  let make = () =>"
  lines->Array.push(makeSig)
  lines->Array.push("    Platform.Plugin.make(")
  lines->Array.push("      ~name=\"" ++ config.name ++ "\",")
  lines->Array.push("      ~heartbeatInterval=" ++ config.heartbeatInterval->Int.toString ++ ",")

  let uiFragmentsParam = if hasUiComponents {
    let aggEntries =
      resolved.aggregates->Array.map(({spec}) => "module(" ++ spec ++ "Aggregate)")
    let rmEntries =
      resolved.readModels->Array.map(({readModel}) => "module(" ++ readModel ++ ")")
    let ls: array<string> = []
    ls->Array.push("      ~uiFragments=?uiBundleUrl->Option.map(url =>")
    ls->Array.push("        Platform.Plugin.makeAutoUIManifest(")
    ls->Array.push("          ~remoteEntryUrl=url,")
    ls->Array.push("          ~name=\"" ++ config.name ++ "\",")
    ls->Array.push("          ~aggregates=[" ++ aggEntries->Array.join(", ") ++ "],")
    ls->Array.push("          ~readModels=[" ++ rmEntries->Array.join(", ") ++ "],")
    ls->Array.push("          ~readModelPositions=[\"platform-summary\"],")
    ls->Array.push("          ~aggregatePositions=[\"resource-detail\"],")
    ls->Array.push("        )")
    ls->Array.push("      ),")
    Some(ls)
  } else {
    None
  }

  let makeParams = [
    renderEpMakeParam(resolved.extensionPoints),
    renderExtensionMakeParam(resolved.extensions),
    renderAggregateMakeParam(resolved.aggregates),
    renderReadModelMakeParam(resolved.readModels),
    renderTaskMakeParam(resolved.tasks),
    renderMakeParam(~param="stateChangeSlices", ~items=resolved.stateChangeSlices, ~moduleSuffix="Slice"),
    renderStateViewSlicesMakeParam(resolved.stateViewSlices, resolved.stateViewSlicesStream),
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
    hasPluginStructure ? Some("      ~pluginStructure=pluginStructure,") : None,
  ]

  makeParams->Array.filterMap(x => x)->Array.forEach(line => lines->Array.push(line))
  switch uiFragmentsParam {
  | Some(uiLines) => uiLines->Array.forEach(line => lines->Array.push(line))
  | None => ()
  }

  lines->Array.push("    )")
  lines->Array.push("}")
  lines->Array.push("")

  lines->Array.join("\n")
}

// ── Top-level render ─────────────────────────────────────────────────────────

let render = (~config: Config.config, ~resolved: Pairing.resolved): string => {
  validateSliceTargets(~resolved)
  switch config.variant {
  | Aws({compositionNamespace}) =>
    let hasUiComponents =
      resolved.aggregates->Array.length > 0 || resolved.readModels->Array.length > 0
    renderAwsWrapper(~name=config.name, ~compositionNamespace, ~hasUiComponents)
  | Composition => renderComposition(~config, ~resolved)
  }
}
