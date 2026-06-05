// Derives the set of workspace packages that own GWT test files, so a watch
// session knows which packages to keep compiling (`pnpm run start` →
// `rescript build -w`). Given the absolute test-file paths from `Discovery`,
// each is mapped to its nearest ancestor `package.json` that declares a
// `start` script; results are deduplicated by directory.
//
// This is the input both the `packages` NDJSON event (FormatterVsCode) and the
// watch-mode build manager (ProcessManager) consume — computed fresh per run so
// it never drifts when a plugin is added or removed.

type pkg = {
  // Package name from package.json (may be "" if absent).
  name: string,
  // Absolute directory containing the owning package.json.
  dir: string,
  // The `start` script's command (the ReScript watch command), informational.
  build: string,
}

@module("node:fs") external _existsSync: string => bool = "existsSync"
@module("node:fs") external _readFileSync: (string, string) => string = "readFileSync"
@module("node:path") external dirname: string => string = "dirname"
@module("node:path") external join: (string, string) => string = "join"

// Reads name + `start` command from a package.json, if it declares one.
let readPackage = (pkgJsonPath: string): option<(string, string)> =>
  try {
    let json = JSON.parseOrThrow(_readFileSync(pkgJsonPath, "utf8"))
    switch json {
    | Object(obj) =>
      let name = switch obj->Dict.get("name") {
      | Some(String(n)) => n
      | _ => ""
      }
      switch obj->Dict.get("scripts") {
      | Some(Object(scripts)) =>
        switch scripts->Dict.get("start") {
        | Some(String(cmd)) => Some((name, cmd))
        | _ => None
        }
      | _ => None
      }
    | _ => None
    }
  } catch {
  | _ => None
  }

// Walks up from `dir` to the nearest package.json declaring a `start` script.
let rec findOwning = (dir: string): option<pkg> => {
  let pkgJson = join(dir, "package.json")
  let here = _existsSync(pkgJson) ? readPackage(pkgJson) : None
  switch here {
  | Some((name, build)) => Some({name, dir, build})
  | None => {
      let parent = dirname(dir)
      parent == dir ? None : findOwning(parent)
    }
  }
}

// Maps test files → deduplicated owning packages (declaration order preserved).
let scan = (testFiles: array<string>): array<pkg> => {
  let seen = Dict.make()
  let out = []
  testFiles->Array.forEach(file =>
    switch findOwning(dirname(file)) {
    | Some(pkg) =>
      switch seen->Dict.get(pkg.dir) {
      | Some(_) => ()
      | None => {
          seen->Dict.set(pkg.dir, true)
          out->Array.push(pkg)
        }
      }
    | None => ()
    }
  )
  out
}
