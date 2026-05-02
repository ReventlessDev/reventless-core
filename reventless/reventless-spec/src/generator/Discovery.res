// Directory scanner: walks src/, classifies .res files by parent folder name.

type componentType =
  | StateChangeSlice
  | StateViewSlice
  | StateViewSliceStream
  | AutomationSlice
  | InboundTranslationSlice
  | OutboundTranslationSlice
  | Aggregate
  | ReadModel
  | Task
  | ExtensionPoint
  | Extension

// relPath: path relative to srcDir (e.g. "ReadModel/ProductsProjections.res")
type discoveredFile = {stem: string, componentType: componentType, epGroup: option<string>, relPath: string}

let folderToComponentType = (folder: string): option<componentType> =>
  switch folder {
  | "StateChange" | "StateChanges" | "StateChangeSlice" | "StateChangeSlices" =>
    Some(StateChangeSlice)
  | "StateView" | "StateViews" | "StateViewSlice" | "StateViewSlices" => Some(StateViewSlice)
  | "StateViewSliceStream" | "StateViewSliceStreams" => Some(StateViewSliceStream)
  | "Automation" | "Automations" | "AutomationSlice" | "AutomationSlices" => Some(AutomationSlice)
  | "InboundTranslation"
  | "InboundTranslations"
  | "InboundTranslationSlice"
  | "InboundTranslationSlices" =>
    Some(InboundTranslationSlice)
  | "OutboundTranslation"
  | "OutboundTranslations"
  | "OutboundTranslationSlice"
  | "OutboundTranslationSlices" =>
    Some(OutboundTranslationSlice)
  | "Aggregate" | "Aggregates" => Some(Aggregate)
  | "ReadModel" | "ReadModels" => Some(ReadModel)
  | "Task" | "Tasks" => Some(Task)
  | "ExtensionPoint" | "ExtensionPoints" => Some(ExtensionPoint)
  | "Extension" | "Extensions" => Some(Extension)
  | _ => None
  }

let isAlwaysExcludedDir = (name: string): bool =>
  name === "Plugin" || name === "tests" || name === "lib"

// Simple glob matching: supports exact match, `/**` prefix, and `/*` single level.
let matchesGlob = (path: string, pattern: string): bool =>
  if pattern === "**" {
    true
  } else if not(pattern->String.includes("*")) {
    // Exact file match or directory prefix
    path === pattern || path->String.startsWith(pattern ++ "/")
  } else if pattern->String.endsWith("/**") {
    let prefix = pattern->String.slice(~start=0, ~end=pattern->String.length - 3)
    path === prefix || path->String.startsWith(prefix ++ "/")
  } else if pattern->String.endsWith("/*") {
    let prefix = pattern->String.slice(~start=0, ~end=pattern->String.length - 2)
    path->String.startsWith(prefix ++ "/") &&
      !(path
      ->String.slice(~start=prefix->String.length + 1, ~end=path->String.length)
      ->String.includes("/"))
  } else {
    path === pattern
  }

let isExcluded = (relPath: string, excludePatterns: array<string>): bool =>
  excludePatterns->Array.some(p => matchesGlob(relPath, p))

let stemOf = (filename: string): option<string> =>
  if filename->String.endsWith(".res") {
    Some(filename->String.slice(~start=0, ~end=filename->String.length - 4))
  } else {
    None
  }

let isSkipped = (stem: string): bool =>
  stem->String.endsWith("Test")
  || stem->String.endsWith("Fixtures")
  // `_EventMappings` and `_Mappings` files in per-entity Aggregate/ folders
  // are picked up by the dedicated [Pairing.findEventMappings] walker;
  // treating them as Aggregate specs would hunt for a non-existent
  // `_EventMappingsBehavior` / `_MappingsBehavior`.
  || stem->String.endsWith("_EventMappings")
  || stem->String.endsWith("_Mappings")

// Collect .res files directly in dir (non-recursive) into acc.
let collectFiles = (
  ~dir: string,
  ~relDir: string,
  ~componentType: componentType,
  ~epGroup: option<string>,
  ~exclude: array<string>,
  ~acc: array<discoveredFile>,
): unit =>
  Generator_Node.readDir(dir)->Array.forEach(entry => {
    if entry->Generator_Node.isFile {
      let filename = entry->Generator_Node.direntName
      let relPath = if relDir === "" {filename} else {relDir ++ "/" ++ filename}
      if !isExcluded(relPath, exclude) {
        switch stemOf(filename) {
        | Some(stem) if !isSkipped(stem) => acc->Array.push({stem, componentType, epGroup, relPath})
        | _ => ()
        }
      }
    }
  })

// Recursively walk srcDir, classifying files into acc.
let rec walkDir = (
  ~dir: string,
  ~relDir: string,
  ~parentComponentType: option<componentType>,
  ~epGroup: option<string>,
  ~exclude: array<string>,
  ~acc: array<discoveredFile>,
): unit =>
  Generator_Node.readDir(dir)->Array.forEach(entry => {
    let entryName = entry->Generator_Node.direntName
    let relPath = if relDir === "" {entryName} else {relDir ++ "/" ++ entryName}

    if isExcluded(relPath, exclude) {
      ()
    } else if entry->Generator_Node.isDirectory {
      if isAlwaysExcludedDir(entryName) {
        ()
      } else {
        switch folderToComponentType(entryName) {
        | Some(ExtensionPoint) =>
          let epDir = Generator_Node.join([dir, entryName])
          let children = Generator_Node.readDir(epDir)
          let hasSubDirs = children->Array.some(e => e->Generator_Node.isDirectory)
          if hasSubDirs {
            // Each subfolder is a named EP group
            children->Array.forEach(child => {
              if child->Generator_Node.isDirectory {
                let groupName = child->Generator_Node.direntName
                let groupDir = Generator_Node.join([epDir, groupName])
                let groupRelDir = relPath ++ "/" ++ groupName
                collectFiles(
                  ~dir=groupDir,
                  ~relDir=groupRelDir,
                  ~componentType=ExtensionPoint,
                  ~epGroup=Some(groupName),
                  ~exclude,
                  ~acc,
                )
              }
            })
          } else {
            // Flat EP folder — all .res files are for one extension point
            collectFiles(
              ~dir=epDir,
              ~relDir=relPath,
              ~componentType=ExtensionPoint,
              ~epGroup=None,
              ~exclude,
              ~acc,
            )
          }
        | Some(ct) =>
          // Recurse into component type folder, collecting files at any depth
          walkDir(
            ~dir=Generator_Node.join([dir, entryName]),
            ~relDir=relPath,
            ~parentComponentType=Some(ct),
            ~epGroup=None,
            ~exclude,
            ~acc,
          )
        | None =>
          // Chapter folder or other — recurse inheriting parent context
          walkDir(
            ~dir=Generator_Node.join([dir, entryName]),
            ~relDir=relPath,
            ~parentComponentType,
            ~epGroup,
            ~exclude,
            ~acc,
          )
        }
      }
    } else if entry->Generator_Node.isFile {
      switch parentComponentType {
      | None => ()
      | Some(ct) =>
        let filename = entryName
        if !isExcluded(relPath, exclude) {
          switch stemOf(filename) {
          | Some(stem) if !isSkipped(stem) => acc->Array.push({stem, componentType: ct, epGroup, relPath})
          | _ => ()
          }
        }
      }
    }
  })

let scan = (~srcDir: string, ~exclude: array<string>): array<discoveredFile> => {
  let acc: array<discoveredFile> = []
  walkDir(~dir=srcDir, ~relDir="", ~parentComponentType=None, ~epGroup=None, ~exclude, ~acc)
  acc
}
