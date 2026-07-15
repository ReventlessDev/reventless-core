// Walks each owning package's src/ tree and enumerates its Reventless
// components by folder convention — including components with no GWT tests.
// This is the inventory the `components` NDJSON event carries: the basis for
// the activity-bar Plugin→kind→component tree and "untested slice" coverage.
// Computed fresh per discovery so it never drifts as components are added.

type component = {
  // Absolute directory of the owning package (matches the `dir` in `packages`).
  dir: string,
  kind: string,
  name: string,
  // Absolute paths of the component's `src/` files (spec + body files like
  // `*_Behavior.res` / `*_Mappings.res`), in walk order. Lets the client list
  // spec / implementation files under each component node.
  files: array<string>,
}

type dirent = {
  name: string,
  @as("isDirectory") _isDirectory: unit => bool,
  @as("isFile") _isFile: unit => bool,
}
type readdirOpts = {withFileTypes: bool}
@module("node:fs/promises")
external _readdir: (string, readdirOpts) => promise<array<dirent>> = "readdir"
@module("node:fs") external _existsSync: string => bool = "existsSync"
@module("node:path") external join: (string, string) => string = "join"


// A directory carrying this sentinel file — and its whole subtree — is pruned
// from the component scan, matching `Discovery`'s `.gwtignore` convention so
// the domain tree and the test tree exclude the same generated/vendored trees.
let gwtIgnoreFile = ".gwtignore"
let isPruned = (entries: array<dirent>) => entries->Array.some(e => e.name == gwtIgnoreFile)

// Source `.res` only — `.res.mjs` / `.res.js` end in `.mjs` / `.js`, and `.resi`
// in `.resi`, so a plain `.res` suffix test excludes compiled output + interfaces.
let isSrcResFile = (name: string) => String.endsWith(name, ".res")

let rec walk = async (dir: string, acc: array<string>): array<string> => {
  let entries = try {
    await _readdir(dir, {withFileTypes: true})
  } catch {
  | _ => []
  }
  if isPruned(entries) {
    acc
  } else {
  let found = ref(acc)
  for i in 0 to entries->Array.length - 1 {
    let entry = entries->Array.getUnsafe(i)
    if !ScanIgnore.shouldIgnore(entry.name) {
      let full = join(dir, entry.name)
      if entry._isDirectory() {
        let nested = await walk(full, [])
        found := Array.concat(found.contents, nested)
      } else if entry._isFile() && isSrcResFile(entry.name) {
        found := Array.concat(found.contents, [full])
      }
    }
  }
  found.contents
  }
}

// Enumerate components across the given package directories (deduplicated per
// dir+kind+name, declaration order preserved). Each component accumulates the
// source files that map to it (spec + body files).
type orderEntry = {dir: string, kind: string, name: string, key: string}

let scan = async (pkgDirs: array<string>): array<component> => {
  let order = []
  let filesByKey = Dict.make()
  for i in 0 to pkgDirs->Array.length - 1 {
    let dir = pkgDirs->Array.getUnsafe(i)
    let srcDir = join(dir, "src")
    if _existsSync(srcDir) {
      let files = await walk(srcDir, [])
      files->Array.forEach(file =>
        switch ComponentMeta.componentOfSrcFile(file) {
        | Some(c) =>
          let key = dir ++ "::" ++ c.kind ++ "::" ++ c.name
          switch filesByKey->Dict.get(key) {
          | Some(existing) => filesByKey->Dict.set(key, Array.concat(existing, [file]))
          | None => {
              filesByKey->Dict.set(key, [file])
              order->Array.push({dir, kind: c.kind, name: c.name, key})
            }
          }
        | None => ()
        }
      )
    }
  }
  order->Array.map(o => {
    dir: o.dir,
    kind: o.kind,
    name: o.name,
    files: filesByKey->Dict.get(o.key)->Option.getOr([]),
  })
}
