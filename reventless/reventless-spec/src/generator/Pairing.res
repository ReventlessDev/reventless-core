// Applies pairing rules to discovered files.
// - Aggregates: pairs Foo + FooBehavior; finds Foo_EventMappings if present
// - ReadModels: pairs FooReadModel + FooProjections; extracts mapping module names from projections file
// - Slices (Plan 02): pair X + X_<Kind> where Kind is the implementation
//   suffix matching the slice's folder. The slice arrays carry only spec
//   stems; the corresponding impl stem is `<stem>_<implSuffix>`.
//     * StateChangeSlice / StateViewSlice  → Behavior / Projection
//     * AutomationSlice                    → Automation
//     * In/OutboundTranslationSlice        → Translation
// - ExtensionPoints: groups by epGroup, counts mappings, selects Make variant

// Implementation-file suffix per slice kind. Used to filter impl files out
// of the slice arrays (they're paired with their spec stems via this
// suffix at codegen time) and to compute the impl module reference.
let implSuffixForStateChange = "_Behavior"
let implSuffixForStateView = "_Projection"
let implSuffixForAutomation = "_Automation"
let implSuffixForTranslation = "_Translation"
// Plan 04: AutomationSlice splits source-side concerns into a `_Mappings`
// sibling. Treated as an impl file so it doesn't surface as a slice spec.
let mappingsSuffixForAutomation = "_Mappings"

let isImplStem = (stem: string): bool =>
  stem->String.endsWith(implSuffixForStateChange)
  || stem->String.endsWith(implSuffixForStateView)
  || stem->String.endsWith(implSuffixForAutomation)
  || stem->String.endsWith(implSuffixForTranslation)
  || stem->String.endsWith(mappingsSuffixForAutomation)

type aggregateDef = {spec: string, behavior: string, eventMappings: option<string>}
// readModelDef pairs a ReadModel spec with its sibling `_Projections.res`
// file. Codegen emits `Platform.ReadModel.Make(<spec>, <projections>)` and
// expects the projections file to declare `let mappings` via
// `@@reventless.mappings`.
type readModelDef = {
  readModel: string,
  projections: string,
}
type extensionPointDef = {group: option<string>, mappings: array<string>}

type resolved = {
  stateChangeSlices: array<string>,
  stateViewSlices: array<string>,
  stateViewSlicesStream: array<string>,
  automationSlices: array<string>,
  inboundTranslationSlices: array<string>,
  outboundTranslationSlices: array<string>,
  // stem → declared targetName (None = not declared or explicitly None)
  automationSliceTargets: Dict.t<option<string>>,
  inboundTranslationSliceTargets: Dict.t<option<string>>,
  outboundTranslationSliceTargets: Dict.t<option<string>>,
  aggregates: array<aggregateDef>,
  readModels: array<readModelDef>,
  tasks: array<string>,
  extensionPoints: array<extensionPointDef>,
  extensions: array<string>,
}

// Scan srcDir recursively for `<Agg>_EventMappings.res` and `<Agg>_Mappings.res`
// files and collect {AggName → mappingStem} dict. Supports the legacy flat
// layout (`srcDir/EventMappings/`), the per-entity layout
// (`srcDir/<Agg>/Aggregate/<Agg>_EventMappings.res`), AND the Phase-3-2
// post-rename form (`<Agg>_Mappings.res`). `Plugin/`, `tests/`, `lib/` are
// skipped. The new `_Mappings.res` form is only matched inside an
// `Aggregate/` (or `EventMappings/`) folder so AutomationSlice's own
// `_Mappings.res` siblings don't get scooped up.
let findEventMappings = (~srcDir: string): Dict.t<string> => {
  let dict = Dict.make()
  let parentDirIsAggregate = (relSegments: array<string>): bool =>
    switch relSegments->Array.length {
    | 0 => false
    | n =>
      let parent = relSegments->Array.getUnsafe(n - 1)
      parent === "Aggregate" || parent === "EventMappings"
    }
  let rec walk = (dir: string, segments: array<string>) =>
    Generator_Node.readDir(dir)->Array.forEach(entry => {
      let name = entry->Generator_Node.direntName
      if entry->Generator_Node.isDirectory {
        if name !== "Plugin" && name !== "tests" && name !== "lib" {
          walk(Generator_Node.join([dir, name]), Array.concat(segments, [name]))
        }
      } else if entry->Generator_Node.isFile {
        if name->String.endsWith("_Mappings.res") && parentDirIsAggregate(segments) {
          let stem = name->String.slice(~start=0, ~end=name->String.length - 4)
          // "_Mappings" = 9 chars
          let aggName = stem->String.slice(~start=0, ~end=stem->String.length - 9)
          Dict.set(dict, aggName, stem)
        } else if name->String.endsWith("_EventMappings.res") {
          let stem = name->String.slice(~start=0, ~end=name->String.length - 4)
          // "_EventMappings" = 14 chars
          let aggName = stem->String.slice(~start=0, ~end=stem->String.length - 14)
          // Don't overwrite a `_Mappings.res` discovered earlier.
          switch Dict.get(dict, aggName) {
          | Some(_) => ()
          | None => Dict.set(dict, aggName, stem)
          }
        }
      }
    })
  if Generator_Node.existsSync(srcDir) {
    walk(srcDir, [])
  }
  dict
}

let sortedStems = (stems: array<string>): array<string> =>
  stems->Array.toSorted((a, b) => if a < b {-1.0} else if a > b {1.0} else {0.0})

// Read a slice spec file and extract the value of `let targetName = ...`.
// Returns Some(name) for string literals (including inside Some("...")),
// or None for `let targetName = None` or when the line is absent.
let extractTargetName = (filePath: string): option<string> => {
  try {
    let content = Generator_Node.readFileSync(filePath)
    let result = ref(None)
    content->String.split("\n")->Array.forEach(line => {
      let trimmed = line->String.trimStart
      if trimmed->String.startsWith("let targetName = ") {
        let firstQuote = trimmed->String.indexOf("\"")
        let lastQuote = trimmed->String.lastIndexOf("\"")
        if firstQuote >= 0 && lastQuote > firstQuote {
          result := Some(trimmed->String.slice(~start=firstQuote + 1, ~end=lastQuote))
        }
        // `let targetName = None` → no quotes found → result stays None
      }
    })
    result.contents
  } catch {
  | _ => None
  }
}

let resolve = (discovered: array<Discovery.discoveredFile>, ~srcDir: string): resolved => {
  let eventMappings = findEventMappings(~srcDir)

  let stateChangeSlices = []
  let stateViewSlices = []
  let stateViewSlicesStream = []
  let automationSlices = []
  let inboundTranslationSlices = []
  let outboundTranslationSlices = []
  // relPath dicts for slices that declare targetName
  let automationSliceRelPaths: Dict.t<string> = Dict.make()
  let inboundTranslationSliceRelPaths: Dict.t<string> = Dict.make()
  let outboundTranslationSliceRelPaths: Dict.t<string> = Dict.make()
  let aggregateSpecs: array<string> = []
  let aggregateBehaviors: array<string> = []
  let readModelStems: array<string> = []
  // projectionsByRelPath: stem → relPath mapping for projections files
  let projectionsByRelPath: Dict.t<string> = Dict.make()
  let tasks = []
  let epFiles: array<Discovery.discoveredFile> = []
  let extensions = []

  // Classify discovered files by component type. For the five slice
  // families, impl files (X_Behavior / X_Projection / X_Automation /
  // X_Translation) are filtered out: they're paired with their spec stems
  // at codegen time via the `_<ImplKind>` suffix convention.
  discovered->Array.forEach(({stem, componentType, epGroup, relPath}) => {
    switch componentType {
    | StateChangeSlice =>
      if !isImplStem(stem) { stateChangeSlices->Array.push(stem) }
    | StateViewSlice =>
      if !isImplStem(stem) { stateViewSlices->Array.push(stem) }
    | StateViewSliceStream =>
      if !isImplStem(stem) { stateViewSlicesStream->Array.push(stem) }
    | AutomationSlice =>
      if !isImplStem(stem) {
        automationSlices->Array.push(stem)
        automationSliceRelPaths->Dict.set(stem, relPath)
      }
    | InboundTranslationSlice =>
      if !isImplStem(stem) {
        inboundTranslationSlices->Array.push(stem)
        inboundTranslationSliceRelPaths->Dict.set(stem, relPath)
      }
    | OutboundTranslationSlice =>
      if !isImplStem(stem) {
        outboundTranslationSlices->Array.push(stem)
        outboundTranslationSliceRelPaths->Dict.set(stem, relPath)
      }
    | Aggregate =>
      if stem->String.endsWith("Behavior") {
        aggregateBehaviors->Array.push(stem)
      } else {
        aggregateSpecs->Array.push(stem)
      }
    | ReadModel =>
      if stem->String.endsWith("Projections") {
        Dict.set(projectionsByRelPath, stem, relPath)
      } else {
        readModelStems->Array.push(stem)
      }
    | Task => tasks->Array.push(stem)
    | ExtensionPoint => epFiles->Array.push({stem, componentType, epGroup, relPath})
    | Extension => extensions->Array.push(stem)
    }
  })

  // ── Aggregate pairing ──────────────────────────────────────────────────────
  // Tries the post-Phase-3.1 `<Spec>_Behavior` form first, then falls back
  // to the legacy `<Spec>Behavior` (no underscore).
  let aggregates =
    aggregateSpecs
    ->sortedStems
    ->Array.filterMap(spec => {
      let underscored = spec ++ "_Behavior"
      let bare = spec ++ "Behavior"
      let behaviorStem = if aggregateBehaviors->Array.includes(underscored) {
        Some(underscored)
      } else if aggregateBehaviors->Array.includes(bare) {
        Some(bare)
      } else {
        None
      }
      switch behaviorStem {
      | Some(behavior) =>
        Some({
          spec,
          behavior,
          eventMappings: Dict.get(eventMappings, spec),
        })
      | None =>
        Console.warn("Generator: Aggregate spec `" ++ spec ++ "` has no matching `" ++ underscored ++ "` or `" ++ bare ++ "` — skipping")
        None
      }
    })

  // ── ReadModel pairing ──────────────────────────────────────────────────────
  // Pairs spec `<Plural>` with impl `<Plural>_Projections.res`. The legacy
  // unpaired forms (`<Plural>ReadModel.res` / `<Plural>Projections.res`) are
  // no longer recognised — see PR3-5 of the close-ppx-gaps-and-unify-naming
  // plan for the migration; downstream codebases should rename to the
  // underscored form.
  let readModels =
    readModelStems
    ->sortedStems
    ->Array.filterMap(rm => {
      // Strip optional ReadModel suffix to get the base plural name.
      let baseName = if rm->String.endsWith("ReadModel") {
        rm->String.slice(~start=0, ~end=rm->String.length - 9)
      } else {
        rm
      }
      let underscoredProj = baseName ++ "_Projections"
      switch Dict.get(projectionsByRelPath, underscoredProj) {
      | None =>
        Console.warn("Generator: ReadModel `" ++ rm ++ "` has no matching `" ++ underscoredProj ++ ".res` — skipping")
        None
      | Some(_) =>
        Some({readModel: rm, projections: underscoredProj})
      }
    })

  // ── ExtensionPoint grouping ────────────────────────────────────────────────
  let epByGroup: Dict.t<array<string>> = Dict.make()
  let flatEpMappings: array<string> = []

  epFiles->Array.forEach(({stem, epGroup}) => {
    switch epGroup {
    | None => flatEpMappings->Array.push(stem)
    | Some(g) =>
      let arr = Dict.get(epByGroup, g)->Option.getOr({
        let a: array<string> = []
        Dict.set(epByGroup, g, a)
        a
      })
      arr->Array.push(stem)
    }
  })

  let extensionPoints: array<extensionPointDef> = []

  if flatEpMappings->Array.length > 0 {
    extensionPoints->Array.push({group: None, mappings: flatEpMappings->sortedStems})
  }

  Dict.toArray(epByGroup)->Array.forEach(((group, mappings)) => {
    extensionPoints->Array.push({group: Some(group), mappings: mappings->sortedStems})
  })

  // ── targetName extraction ──────────────────────────────────────────────────
  let buildTargets = (stems: array<string>, relPaths: Dict.t<string>): Dict.t<option<string>> => {
    let dict = Dict.make()
    stems->Array.forEach(stem => {
      let target = switch Dict.get(relPaths, stem) {
      | None => None
      | Some(relPath) => extractTargetName(Generator_Node.join([srcDir, relPath]))
      }
      dict->Dict.set(stem, target)
    })
    dict
  }

  {
    stateChangeSlices: stateChangeSlices->sortedStems,
    stateViewSlices: stateViewSlices->sortedStems,
    stateViewSlicesStream: stateViewSlicesStream->sortedStems,
    automationSlices: automationSlices->sortedStems,
    inboundTranslationSlices: inboundTranslationSlices->sortedStems,
    outboundTranslationSlices: outboundTranslationSlices->sortedStems,
    automationSliceTargets: buildTargets(automationSlices, automationSliceRelPaths),
    inboundTranslationSliceTargets: buildTargets(
      inboundTranslationSlices,
      inboundTranslationSliceRelPaths,
    ),
    outboundTranslationSliceTargets: buildTargets(
      outboundTranslationSlices,
      outboundTranslationSliceRelPaths,
    ),
    aggregates,
    readModels,
    tasks: tasks->sortedStems,
    extensionPoints,
    extensions: extensions->sortedStems,
  }
}
