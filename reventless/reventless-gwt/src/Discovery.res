// Walks a directory tree and returns absolute paths of compiled GWT test
// files (`*_GWT.res.mjs` plus `*GwtTest.res.mjs` — the two shapes used in
// the monorepo today). Respects a minimal ignore set (`node_modules`,
// `lib`, `.git`, `dist`, `.history`). Pruning `lib` covers compiled
// `lib/bs` / `lib/ocaml` outputs. Full `.gitignore` parsing is out of scope;
// the ignore set is enough to make a bare cwd scan (the auto-discovery
// default) cheap and correct across a multi-package workspace.

type dirent = {
  name: string,
  @as("isDirectory") _isDirectory: unit => bool,
  @as("isFile") _isFile: unit => bool,
}

type readdirOpts = {withFileTypes: bool}

@module("node:fs/promises")
external _readdir: (string, readdirOpts) => promise<array<dirent>> = "readdir"

type stats = {
  @as("isDirectory") _isDirectory: unit => bool,
  @as("isFile") _isFile: unit => bool,
}

@module("node:fs/promises") external _stat: string => promise<stats> = "stat"

@module("node:path") external join: (string, string) => string = "join"
@module("node:path") external isAbsolute: string => bool = "isAbsolute"
@module("node:path") external resolve: string => string = "resolve"

let ignoreNames = ["node_modules", ".git", "dist", "lib", ".history"]
let shouldIgnore = (name: string) => Array.includes(ignoreNames, name)

// A directory carrying this sentinel file — and its whole subtree — is pruned
// from discovery. Unlike the `ignoreNames` dir-name list, this is filesystem
// state, so it excludes generated/vendored trees (e.g. codegen golden fixtures)
// even when compiled `*_GWT.res.mjs` are present on disk.
let gwtIgnoreFile = ".gwtignore"
let isPruned = (entries: array<dirent>) => entries->Array.some(e => e.name == gwtIgnoreFile)

let isGwtTestFile = (name: string) =>
  String.endsWith(name, "_GWT.res.mjs") ||
  String.endsWith(name, "GwtTest.res.mjs") ||
  String.endsWith(name, "Gwt.res.mjs")

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
    if !shouldIgnore(entry.name) {
      let full = join(dir, entry.name)
      if entry._isDirectory() {
        let nested = await walk(full, [])
        found := Array.concat(found.contents, nested)
      } else if entry._isFile() && isGwtTestFile(entry.name) {
        found := Array.concat(found.contents, [full])
      }
    }
  }
  found.contents
  }
}

// Returns absolute paths of `*GWT*.res.mjs` test files reachable from the
// supplied roots. A root may be a directory or a single file.
let discover = async (roots: array<string>): array<string> => {
  let found = ref([])
  for i in 0 to roots->Array.length - 1 {
    let root = roots->Array.getUnsafe(i)
    let absolute = isAbsolute(root) ? root : resolve(root)
    let isDir = try {
      let s = await _stat(absolute)
      s._isDirectory()
    } catch {
    | _ => false
    }
    if isDir {
      let collected = await walk(absolute, [])
      found := Array.concat(found.contents, collected)
    } else if isGwtTestFile(absolute) {
      found := Array.concat(found.contents, [absolute])
    }
  }
  // Deduplicate (if roots overlap).
  let seen = Dict.make()
  let unique = []
  found.contents->Array.forEach(path =>
    switch seen->Dict.get(path) {
    | Some(_) => ()
    | None => {
        seen->Dict.set(path, true)
        unique->Array.push(path)
      }
    }
  )
  unique
}
