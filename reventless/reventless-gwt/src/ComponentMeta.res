// Pure helpers mapping a file path to its Reventless component {kind, name}
// using the folder-name convention (the same vocabulary the plugin generator
// classifies by). Shared by the discovery `item` annotation (FormatterVsCode)
// and the src/ component inventory (ComponentScan). No I/O — path strings only.

type component = {kind: string, name: string}

// The folder→kind vocabulary and body-file suffixes are the single source in
// `Reventless.ComponentKind` (shared with the plugin generator). Deriving from it
// means the gwt discovery recognises exactly the folder spellings the generator
// classifies — including the plural / short forms this file used to miss.
module Kind = Reventless.ComponentKind

// Strip a body-file suffix (longest first) to recover the spec stem, so spec and
// body files in one folder collapse to the same component name.
let stripBody = (stem: string) =>
  switch Kind.bodySuffixes->Array.find(suf => String.endsWith(stem, suf)) {
  | Some(suf) => String.slice(stem, ~start=0, ~end=String.length(stem) - String.length(suf))
  | None => stem
  }

// Strip the GWT test marker (`_GWT` / `GwtTest` / `Gwt`) — the three shapes
// `Discovery.isGwtTestFile` recognises.
let stripGwt = (stem: string) =>
  if String.endsWith(stem, "_GWT") {
    String.slice(stem, ~start=0, ~end=String.length(stem) - 4)
  } else if String.endsWith(stem, "GwtTest") {
    String.slice(stem, ~start=0, ~end=String.length(stem) - 7)
  } else if String.endsWith(stem, "Gwt") {
    String.slice(stem, ~start=0, ~end=String.length(stem) - 3)
  } else {
    stem
  }

// Last path segment (POSIX paths — the monorepo's tooling normalises to `/`).
let basename = (path: string) =>
  switch path->String.split("/")->Array.last {
  | Some(s) => s
  | None => path
  }

// Parent folder name (the segment before the filename), if any.
let parentFolder = (path: string) => {
  let segs = path->String.split("/")
  let n = segs->Array.length
  n >= 2 ? segs->Array.get(n - 2) : None
}

// Strip the compiled / source extension from a filename.
let stem = (filename: string) =>
  if String.endsWith(filename, ".res.mjs") {
    String.slice(filename, ~start=0, ~end=String.length(filename) - 8)
  } else if String.endsWith(filename, ".res.js") {
    String.slice(filename, ~start=0, ~end=String.length(filename) - 7)
  } else if String.endsWith(filename, ".resi") {
    String.slice(filename, ~start=0, ~end=String.length(filename) - 5)
  } else if String.endsWith(filename, ".res") {
    String.slice(filename, ~start=0, ~end=String.length(filename) - 4)
  } else {
    filename
  }

// {kind, name} for a discovered GWT test file, or None if it isn't inside a
// recognised kind folder. `kind` is the canonical folder name, so a plural
// folder (`Aggregates/`) reports the same kind as its singular form.
let componentOfTestFile = (path: string): option<component> =>
  switch parentFolder(path)->Option.flatMap(Kind.folderToKind) {
  | Some(kind) => Some({kind: Kind.folderName(kind), name: path->basename->stem->stripGwt->stripBody})
  | None => None
  }

// {kind, name} for a src/ component file (spec or body), or None.
let componentOfSrcFile = (path: string): option<component> =>
  switch parentFolder(path)->Option.flatMap(Kind.folderToKind) {
  | Some(kind) => Some({kind: Kind.folderName(kind), name: path->basename->stem->stripBody})
  | None => None
  }
