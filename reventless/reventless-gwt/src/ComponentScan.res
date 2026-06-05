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

let ignoreNames = ["node_modules", ".git", "dist", "lib", ".history"]
let shouldIgnore = (name: string) => Array.includes(ignoreNames, name)

// Source `.res` only — `.res.mjs` / `.res.js` end in `.mjs` / `.js`, and `.resi`
// in `.resi`, so a plain `.res` suffix test excludes compiled output + interfaces.
let isSrcResFile = (name: string) => String.endsWith(name, ".res")

let rec walk = async (dir: string, acc: array<string>): array<string> => {
  let entries = try {
    await _readdir(dir, {withFileTypes: true})
  } catch {
  | _ => []
  }
  let found = ref(acc)
  for i in 0 to entries->Array.length - 1 {
    let entry = entries->Array.getUnsafe(i)
    if !shouldIgnore(entry.name) {
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

// Enumerate components across the given package directories (deduplicated per
// dir+kind+name, declaration order preserved).
let scan = async (pkgDirs: array<string>): array<component> => {
  let seen = Dict.make()
  let out = []
  for i in 0 to pkgDirs->Array.length - 1 {
    let dir = pkgDirs->Array.getUnsafe(i)
    let srcDir = join(dir, "src")
    if _existsSync(srcDir) {
      let files = await walk(srcDir, [])
      files->Array.forEach(file =>
        switch ComponentMeta.componentOfSrcFile(file) {
        | Some(c) =>
          let key = dir ++ "::" ++ c.kind ++ "::" ++ c.name
          switch seen->Dict.get(key) {
          | Some(_) => ()
          | None => {
              seen->Dict.set(key, true)
              out->Array.push({dir, kind: c.kind, name: c.name})
            }
          }
        | None => ()
        }
      )
    }
  }
  out
}
