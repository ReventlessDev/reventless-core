// Directory scanner: walks src/, classifies .res files by parent folder name.

// Re-export the single-source `ComponentKind.t` (same constructors, so the bare
// pattern matches in `Pairing` keep resolving via type inference) and derive the
// folder classifier from it — one vocabulary shared with the gwt discovery.
type componentType = ComponentKind.t =
  | StateChangeSlice
  | StateViewSlice
  | StateViewSliceStream
  | AutomationSlice
  | InboundTranslationSlice
  | OutboundTranslationSlice
  | Aggregate
  | ReadModel
  | ReadModelStream
  | Task
  | ExtensionPoint
  | Extension

// relPath: path relative to srcDir (e.g. "ReadModel/ProductsProjections.res")
type discoveredFile = {stem: string, componentType: componentType, epGroup: option<string>, relPath: string}

let folderToComponentType = ComponentKind.folderToKind

// The intra-plugin grouping band ("chapter") a file belongs to, derived from its
// path relative to `src/`: the first directory segment that is not a recognised
// kind-folder. `src/<Chapter>/<Kind>/<Component>.res` → `Some("<Chapter>")`; a file
// directly under a kind-folder (`src/<Kind>/<Component>.res`) or at the src root →
// `None`. Uses the single-source `ComponentKind.isKindFolder`, so a chapter read
// here (build time, disk) agrees with the authoring tool's identical heuristic and
// with a chapter reflected off the deployed plugin structure. See
// docs/plans/deployed-chapter-grouping.md.
let chapterOf = (relPath: string): option<string> => {
  let segments = relPath->String.split("/")
  // Need at least one directory segment before the filename.
  if segments->Array.length < 2 {
    None
  } else {
    switch segments->Array.get(0) {
    | Some(first) if !ComponentKind.isKindFolder(first) => Some(first)
    | _ => None
    }
  }
}

// Deduplicated (stem → chapter) pairs across the discovered files, sorted by stem
// for deterministic codegen. Only files that carry a chapter are included; stems are
// unique within a plugin (validated), so keying by stem cannot collide. Body files
// (`_Behavior`, `_Projections`, …) share their component's chapter but are never
// looked up by `Spec.name`, so their presence is harmless.
let chaptersByStem = (discovered: array<discoveredFile>): array<(string, string)> => {
  let byStem: Dict.t<string> = Dict.make()
  discovered->Array.forEach(d =>
    switch chapterOf(d.relPath) {
    | Some(ch) => byStem->Dict.set(d.stem, ch)
    | None => ()
    }
  )
  byStem
  ->Dict.toArray
  ->Array.toSorted(((a, _), (b, _)) =>
    if a < b {
      -1.0
    } else if a > b {
      1.0
    } else {
      0.0
    }
  )
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
