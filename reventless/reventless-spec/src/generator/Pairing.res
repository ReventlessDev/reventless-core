// Applies pairing rules to discovered files.
// - Aggregates: pairs Foo + FooBehavior; finds Foo_EventMappings if present
// - ReadModels: pairs FooReadModel + FooProjections; extracts mapping module names from projections file
// - ExtensionPoints: groups by epGroup, counts mappings, selects Make variant
// - All other types: no pairing needed (pass through as stems)

type aggregateDef = {spec: string, behavior: string, eventMappings: option<string>}
// mappingModules: module names found inside the projections file (e.g. ["ProductMapping"])
type readModelDef = {readModel: string, projections: string, mappingModules: array<string>}
type extensionPointDef = {group: option<string>, mappings: array<string>}

type resolved = {
  stateChangeSlices: array<string>,
  stateViewSlices: array<string>,
  automationSlices: array<string>,
  inboundTranslationSlices: array<string>,
  outboundTranslationSlices: array<string>,
  aggregates: array<aggregateDef>,
  readModels: array<readModelDef>,
  tasks: array<string>,
  extensionPoints: array<extensionPointDef>,
  extensions: array<string>,
}

// Scan srcDir/EventMappings/ and collect {AggName → mappingStem} dict.
let findEventMappings = (~srcDir: string): Dict.t<string> => {
  let dict = Dict.make()
  let emDir = Generator_Node.join([srcDir, "EventMappings"])
  if Generator_Node.existsSync(emDir) {
    Generator_Node.readDir(emDir)->Array.forEach(entry => {
      if entry->Generator_Node.isFile {
        let filename = entry->Generator_Node.direntName
        if filename->String.endsWith("_EventMappings.res") {
          let stem = filename->String.slice(~start=0, ~end=filename->String.length - 4)
          let aggName = stem->String.slice(~start=0, ~end=stem->String.length - 14) // "_EventMappings" = 14 chars
          Dict.set(dict, aggName, stem)
        }
      }
    })
  }
  dict
}

// Read a projections .res file and extract names of mapping modules.
// Looks for lines starting with "module XyzMapping = Mapping.Make(".
let extractMappingModules = (filePath: string): array<string> => {
  let result: array<string> = []
  try {
    let content = Generator_Node.readFileSync(filePath)
    content->String.split("\n")->Array.forEach(line => {
      let trimmed = line->String.trimStart
      if trimmed->String.startsWith("module ") && trimmed->String.includes("= Mapping.Make(") {
        // Extract module name: "module FooMapping = Mapping.Make(..." → "FooMapping"
        let afterModule = trimmed->String.slice(~start=7, ~end=trimmed->String.length)
        switch afterModule->String.indexOf(" ") {
        | -1 => ()
        | spaceIdx => result->Array.push(afterModule->String.slice(~start=0, ~end=spaceIdx))
        }
      }
    })
  } catch {
  | _ => ()
  }
  result
}

let sortedStems = (stems: array<string>): array<string> =>
  stems->Array.toSorted((a, b) => if a < b {-1.0} else if a > b {1.0} else {0.0})

let resolve = (discovered: array<Discovery.discoveredFile>, ~srcDir: string): resolved => {
  let eventMappings = findEventMappings(~srcDir)

  let stateChangeSlices = []
  let stateViewSlices = []
  let automationSlices = []
  let inboundTranslationSlices = []
  let outboundTranslationSlices = []
  let aggregateSpecs: array<string> = []
  let aggregateBehaviors: array<string> = []
  let readModelStems: array<string> = []
  // projectionsByRelPath: stem → relPath mapping for projections files
  let projectionsByRelPath: Dict.t<string> = Dict.make()
  let tasks = []
  let epFiles: array<Discovery.discoveredFile> = []
  let extensions = []

  // Classify discovered files by component type
  discovered->Array.forEach(({stem, componentType, epGroup, relPath}) => {
    switch componentType {
    | StateChangeSlice => stateChangeSlices->Array.push(stem)
    | StateViewSlice => stateViewSlices->Array.push(stem)
    | AutomationSlice => automationSlices->Array.push(stem)
    | InboundTranslationSlice => inboundTranslationSlices->Array.push(stem)
    | OutboundTranslationSlice => outboundTranslationSlices->Array.push(stem)
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
  let aggregates =
    aggregateSpecs
    ->sortedStems
    ->Array.filterMap(spec => {
      let behaviorStem = spec ++ "Behavior"
      if aggregateBehaviors->Array.includes(behaviorStem) {
        Some({
          spec,
          behavior: behaviorStem,
          eventMappings: Dict.get(eventMappings, spec),
        })
      } else {
        Console.warn("Generator: Aggregate spec `" ++ spec ++ "` has no matching `" ++ behaviorStem ++ "` — skipping")
        None
      }
    })

  // ── ReadModel pairing ──────────────────────────────────────────────────────
  let readModels =
    readModelStems
    ->sortedStems
    ->Array.filterMap(rm => {
      // FooReadModel → FooProjections (strip "ReadModel", add "Projections")
      let baseName = if rm->String.endsWith("ReadModel") {
        rm->String.slice(~start=0, ~end=rm->String.length - 9)
      } else {
        rm
      }
      let projStem = baseName ++ "Projections"
      switch Dict.get(projectionsByRelPath, projStem) {
      | None =>
        Console.warn("Generator: ReadModel `" ++ rm ++ "` has no matching `" ++ projStem ++ "` — skipping")
        None
      | Some(projRelPath) =>
        let filePath = Generator_Node.join([srcDir, projRelPath])
        let mappingModules = extractMappingModules(filePath)
        Some({readModel: rm, projections: projStem, mappingModules})
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

  {
    stateChangeSlices: stateChangeSlices->sortedStems,
    stateViewSlices: stateViewSlices->sortedStems,
    automationSlices: automationSlices->sortedStems,
    inboundTranslationSlices: inboundTranslationSlices->sortedStems,
    outboundTranslationSlices: outboundTranslationSlices->sortedStems,
    aggregates,
    readModels,
    tasks: tasks->sortedStems,
    extensionPoints,
    extensions: extensions->sortedStems,
  }
}
