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

// StateChangeSlices opt into async dispatch via `@@reventless.async` on the
// spec file; the rendered factory becomes MakeAsync (CommandPending response).
let renderStateChangeSlices = (
  stems: array<string>,
  asyncStems: Dict.t<bool>,
): array<string> =>
  stems->Array.map(stem => {
    let factory = switch Dict.get(asyncStems, stem) {
    | Some(true) => "MakeAsync"
    | _ => "Make"
    }
    "  module "
    ++ stem
    ++ "Slice = Platform.StateChangeSlice."
    ++ factory
    ++ "("
    ++ stem
    ++ ", "
    ++ stem
    ++ Pairing.implSuffixForStateChange
    ++ ")"
  })

// AutomationSlice — 2-arg form. The merged `_Automation.res` shape exposes
// both `process` and the `mappings` array, so plugin assembly drops to
// `Platform.AutomationSlice.Make(<Stem>, <Stem>_Automation)`. Legacy 3-file
// shapes use a one-line bridge in `_Automation.res` to re-export `mappings`
// from the sibling `_Mappings.res`.
let renderAutomationSlices = (stems: array<string>): array<string> =>
  stems->Array.map(stem =>
    "  module "
    ++ stem
    ++ "Slice = Platform.AutomationSlice.Make("
    ++ stem
    ++ ", "
    ++ stem
    ++ "_Automation)"
  )

let renderAggregates = (aggregates: array<Pairing.aggregateDef>): array<string> =>
  aggregates->Array.flatMap(({spec, behavior, eventMappings, isAsync}) => {
    let em = eventMappings->Option.getOr("ReventlessInfra.NoEventMappings.Make(" ++ spec ++ ")")
    let factory = isAsync ? "MakeAsync" : "Make"
    [
      "  module " ++ spec ++ "Aggregate = Platform.Aggregate." ++ factory ++ "(",
      "    " ++ spec ++ ",",
      "    " ++ behavior ++ ",",
      "    " ++ em ++ ",",
      "  )",
    ]
  })

let renderReadModels = (readModels: array<Pairing.readModelDef>): array<string> =>
  readModels->Array.flatMap(({readModel, projections, stream}) => {
    // The projections file declares `let mappings` via `@@reventless.mappings`,
    // so we reference it directly. The wrapping module name appends `ReadModel`
    // so the LHS doesn't shadow the bare-named spec module (e.g., `Categories`).
    let wrapperName = if readModel->String.endsWith("ReadModel") {
      readModel
    } else {
      readModel ++ "ReadModel"
    }
    // `ReadModelStream/` read models get a DynamoDB-Stream-backed QueryDb so the
    // platform wires a StateTopic Lambda for AppSync Events (Source B) live updates.
    let factory = stream ? "Platform.ReadModelStream.Make" : "Platform.ReadModel.Make"
    [
      "  module " ++ wrapperName ++ " = " ++ factory ++ "(" ++ readModel ++ ", " ++ projections ++ ")",
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
    // The wrapping module name in Plugin.res is the legacy `<rm>` (when the
    // spec already ends in `ReadModel`) or `<rm>ReadModel` (post-Phase-3.3,
    // when the spec is the bare plural like `Categories`). Mirrors the LHS
    // chosen by [renderReadModels] above.
    let entries = readModels->Array.map(({readModel}) => {
      let wrapperName = if readModel->String.endsWith("ReadModel") {
        readModel
      } else {
        readModel ++ "ReadModel"
      }
      "module(" ++ wrapperName ++ ")"
    })
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
  ~extensionPoints: array<Pairing.extensionPointDef>,
  ~componentChapters: array<(string, string)>,
): option<array<string>> => {
  // The structure call carries the EP *mapping* files (one per Delegate
  // connection), not the wrapped ExtensionPoint module — Plugin_Structure reads
  // each mapping's Delegate to derive the extension point's source event types.
  let epMappingStems = extensionPoints->Array.flatMap(({mappings}) => mappings)
  let hasComponents =
    aggregates->Array.length > 0 ||
    readModels->Array.length > 0 ||
    stateViewSlices->Array.length > 0 ||
    stateViewSlicesStream->Array.length > 0 ||
    stateChangeSlices->Array.length > 0 ||
    automationSlices->Array.length > 0 ||
    outboundTranslationSlices->Array.length > 0 ||
    inboundTranslationSlices->Array.length > 0 ||
    extensions->Array.length > 0 ||
    epMappingStems->Array.length > 0
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
      let entries = readModels->Array.map(({readModel}) => {
        let wrapperName = if readModel->String.endsWith("ReadModel") {
          readModel
        } else {
          readModel ++ "ReadModel"
        }
        "module(" ++ wrapperName ++ ")"
      })
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
    if epMappingStems->Array.length > 0 {
      let entries = epMappingStems->Array.map(s => "module(" ++ s ++ ")")
      ls->Array.push("    ~extensionPoints=[" ++ entries->Array.join(", ") ++ "],")
    }
    // Chapter grouping bands per component, captured from the source folder layout.
    // Only emitted when at least one component lives under a chapter folder, so
    // plugins with a flat `src/` keep a byte-identical generated Plugin.res.
    if componentChapters->Array.length > 0 {
      let entries =
        componentChapters->Array.map(((stem, chapter)) =>
          "(\"" ++ stem ++ "\", \"" ++ chapter ++ "\")"
        )
      ls->Array.push("    ~componentChapters=Dict.fromArray([" ++ entries->Array.join(", ") ++ "]),")
    }
    ls->Array.push("  )")
    Some(ls)
  }
}

// ── Duplicate spec-stem lint ─────────────────────────────────────────────────
// Within one plugin, every spec file's stem produces a top-level ReScript
// module name. Two spec files with the same stem (across folders) collide at
// link time with a confusing error. We catch the collision here with a clear
// message naming both file paths.

let validateUniqueSpecStems = (~discovered: array<Discovery.discoveredFile>) => {
  // Each discovered .res file becomes a top-level ReScript module named after
  // its filename stem. Two files with the same stem in different folders
  // collide at link time, so we surface the conflict here with both paths.
  let byStem: Dict.t<array<string>> = Dict.make()
  discovered->Array.forEach((d: Discovery.discoveredFile) => {
    let existing = byStem->Dict.get(d.stem)->Option.getOr([])
    existing->Array.push(d.relPath)
    byStem->Dict.set(d.stem, existing)
  })
  byStem
  ->Dict.toArray
  ->Array.forEach(((stem, paths)) => {
    if paths->Array.length > 1 {
      let pathList = paths->Array.toSorted((a, b) => if a < b {-1.0} else if a > b {1.0} else {0.0})->Array.join("\n  - ")
      JsError.throwWithMessage(
        "Generator: stem `" ++
        stem ++
        "` is used by multiple files. Filename stems must be unique across a plugin so the generated module names don't collide:\n  - " ++
        pathList,
      )
    }
  })
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
    // Deploy-time bootstrap seam (no-op unless a package registers a
    // contribution). PreDeploy runs before the platform/plugin graph builds.
    "ReventlessInfra.DeployBootstrap.run(PreDeploy)",
    "",
    "module Platform = ReventlessAws.Platform.Make()",
    "module " ++ name ++ " = Plugin.Make(Platform)",
    "",
    "let default = Platform.deployPlugin(",
    "  ~plugin=module(" ++ name ++ "),",
    ")",
    "",
    // PostDeploy runs after the graph is registered (exports, cross-stack output).
    "ReventlessInfra.DeployBootstrap.run(PostDeploy)",
    "",
  ]->Array.join("\n")
}

// ── Aws-variant render ───────────────────────────────────────────────────────
// The AWS Plugin.res delegates to the source plugin's `Plugin.Make` functor;
// all slice/aggregate/readmodel declarations and the federation override
// env-var read live in the Composition variant. The wrapper just retypes the
// Platform constraint and re-exports `make` for the AWS deploy path.

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

let renderAwsWrapper = (~compositionNamespace: string): string => {
  [
    "// AUTO-GENERATED — do not edit. Run `npm run generate` to update.",
    "",
    "module Make = (",
    "  Platform: ReventlessInfra.Platform.T",
    "    with type api = ReventlessAws.Types.AppSync.api",
    "    and type role = ReventlessAws.Types.AppSync.role,",
    ") => {",
    "  module Composition = " ++ compositionNamespace ++ ".Plugin.Make(Platform)",
    "  let make = () => Composition.make()",
    "}",
    "",
  ]->Array.join("\n")
}

// ── Composition-variant render ───────────────────────────────────────────────

let renderComposition = (
  ~config: Config.config,
  ~resolved: Pairing.resolved,
  ~componentChapters: array<(string, string)>,
): string => {
  let lines: array<string> = []

  // Header
  lines->Array.push("// AUTO-GENERATED — do not edit. Run `npm run generate` to update.")
  // Federation override URL — empty/unset means Auto UI renders every fragment.
  // Read once at module init; same env var is honoured by the AWS wrapper.
  lines->Array.push("")
  lines->Array.push(
    "@val external uiBundleUrl: option<string> = \"process.env." ++
    pluginNameToEnvBase(config.name) ++
    "_UI_BUNDLE_URL\"",
  )
  lines->Array.push("")
  lines->Array.push("module Make = (Platform: ReventlessInfra.Platform.T) => {")

  let push = (sectionLines: array<string>) => {
    sectionLines->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  }

  // StateChangeSlices — per-stem MakeAsync opt-in via @@reventless.async
  if resolved.stateChangeSlices->Array.length > 0 {
    lines->Array.push("  // StateChangeSlices")
    renderStateChangeSlices(
      resolved.stateChangeSlices,
      resolved.asyncStateChangeSlices,
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

  // AutomationSlices — 2-arg form: (Spec, _Automation)
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
    ~extensionPoints=resolved.extensionPoints,
    ~componentChapters,
  )
  let hasPluginStructure = pluginStructureLines->Option.isSome
  switch pluginStructureLines {
  | Some(defLines) =>
    defLines->Array.forEach(l => lines->Array.push(l))
    lines->Array.push("")
  | None => ()
  }

  // make() call — Composition variant only (Aws variant uses renderAwsWrapper).
  // Auto UI is always derived from pluginStructure by the host-shell. The
  // uiFragments manifest is purely a federation-override map: empty
  // remoteEntryUrl ⇒ Auto UI renders the fragment. The wiring is emitted
  // whenever pluginStructure exists, so any plugin (aggregate/DCB/hybrid)
  // can opt into a custom React bundle via the env var.
  lines->Array.push("  let make = () =>")
  lines->Array.push("    Platform.Plugin.make(")
  lines->Array.push("      ~name=\"" ++ config.name ++ "\",")
  lines->Array.push("      ~heartbeatInterval=" ++ config.heartbeatInterval->Int.toString ++ ",")

  let uiFragmentsParam = if hasPluginStructure {
    let ls: array<string> = []
    ls->Array.push("      ~uiFragments=?uiBundleUrl->Option.map(url =>")
    ls->Array.push("        Platform.Plugin.makeAutoUIManifest(")
    ls->Array.push("          ~remoteEntryUrl=url,")
    ls->Array.push("          ~name=\"" ++ config.name ++ "\",")
    ls->Array.push("          ~pluginStructure,")
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
    // Components carrying `@@reventless.systemCallable` — only emitted when at
    // least one opts in, so existing generated Plugin.res files stay identical.
    resolved.systemCallableComponents->Array.length > 0
      ? Some(
          "      ~systemCallableComponents=[" ++
          resolved.systemCallableComponents
          ->Array.map(n => "\"" ++ n ++ "\"")
          ->Array.join(", ") ++ "],",
        )
      : None,
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

let render = (
  ~config: Config.config,
  ~resolved: Pairing.resolved,
  ~discovered: array<Discovery.discoveredFile>,
): string => {
  validateUniqueSpecStems(~discovered)
  validateSliceTargets(~resolved)
  // Chapter map, keyed by each component's spec stem (= its `Spec.name` for every
  // graph-node kind, which is how `Plugin_Structure` looks the chapter up). Filtered
  // to the actual component stems so body files (`_Behavior`, `_Projections`, …) —
  // which `Discovery` also surfaces and which share their component's chapter — don't
  // leak noise entries into the generated call. Tasks / extensions / extension points
  // carry no chapter field, so they are excluded too.
  let componentStems = Array.flat([
    resolved.aggregates->Array.map(({spec}) => spec),
    resolved.readModels->Array.map(({readModel}) => readModel),
    resolved.stateChangeSlices,
    resolved.stateViewSlices,
    resolved.stateViewSlicesStream,
    resolved.automationSlices,
    resolved.outboundTranslationSlices,
    resolved.inboundTranslationSlices,
  ])
  let componentChapters =
    Discovery.chaptersByStem(discovered)->Array.filter(((stem, _)) =>
      componentStems->Array.includes(stem)
    )
  switch config.variant {
  | Aws({compositionNamespace}) => renderAwsWrapper(~compositionNamespace)
  | Composition => renderComposition(~config, ~resolved, ~componentChapters)
  }
}
