// Discovers the local-platform package(s) the runner can launch (features plan
// Phase 9). A platform package is one that (a) depends on
// `@reventlessdev/reventless-local` and (b) carries a compiled run entrypoint at
// `src/Main.res.mjs` (what `tsx`/`node` execute). This mirrors PackageScan's
// role for the watch session, but keys off the run entrypoint rather than test
// files. The matching predicate is pure so it can be unit-tested without a real
// workspace tree.

type platformPkg = {
  // Package name from package.json (may be "" if absent).
  name: string,
  // Absolute package directory (the one containing package.json + src/).
  dir: string,
  // Absolute path to the compiled run entrypoint (src/Main.res.mjs).
  mainPath: string,
  // The npm-script name to launch, preferring an in-memory variant: "serve:memory"
  // if declared, else "serve". None ⇒ no serve script (runner falls back to running
  // src/Main.res.mjs via tsx directly).
  serveScript: option<string>,
}

type dirent = {
  name: string,
  @as("isDirectory") _isDirectory: unit => bool,
}
type readdirOpts = {withFileTypes: bool}
@module("node:fs/promises")
external _readdir: (string, readdirOpts) => promise<array<dirent>> = "readdir"
@module("node:fs") external _existsSync: string => bool = "existsSync"
@module("node:fs") external _readFileSync: (string, string) => string = "readFileSync"
@module("node:path") external join: (string, string) => string = "join"

let localPlatformDep = "@reventlessdev/reventless-local"
let ignoreNames = ["node_modules", ".git", "dist", "lib", ".history"]

// Pure predicate: given a package.json's text and whether src/Main.res.mjs exists,
// decide whether this is a launchable platform package and surface its name +
// serve script. Depends on reventless-local appearing in any dependency block.
let matchPlatform = (
  ~pkgJsonText: string,
  ~mainExists: bool,
): option<(string, option<string>)> => {
  if !mainExists {
    None
  } else {
    switch JSON.parseOrThrow(pkgJsonText) {
    | exception _ => None
    | json =>
      switch json->JSON.Decode.object {
      | None => None
      | Some(obj) =>
        let name = switch obj->Dict.get("name") {
        | Some(String(n)) => n
        | _ => ""
        }
        let depsHave = key =>
          switch obj->Dict.get(key)->Option.flatMap(JSON.Decode.object) {
          | Some(deps) => deps->Dict.get(localPlatformDep)->Option.isSome
          | None => false
          }
        let dependsOnLocal =
          depsHave("dependencies") ||
          depsHave("devDependencies") ||
          depsHave("optionalDependencies")
        if dependsOnLocal {
          let serveScript =
            switch obj->Dict.get("scripts")->Option.flatMap(JSON.Decode.object) {
            | Some(scripts) =>
              if scripts->Dict.get("serve:memory")->Option.isSome {
                Some("serve:memory")
              } else if scripts->Dict.get("serve")->Option.isSome {
                Some("serve")
              } else {
                None
              }
            | None => None
            }
          Some((name, serveScript))
        } else {
          None
        }
      }
    }
  }
}

// Inspect a single directory: is it a platform package?
let inspectDir = (dir: string): option<platformPkg> => {
  let pkgJson = join(dir, "package.json")
  let mainPath = join(join(dir, "src"), "Main.res.mjs")
  if !_existsSync(pkgJson) {
    None
  } else {
    let text = try _readFileSync(pkgJson, "utf8") catch {
    | _ => ""
    }
    switch matchPlatform(~pkgJsonText=text, ~mainExists=_existsSync(mainPath)) {
    | Some((name, serveScript)) => Some({name, dir, mainPath, serveScript})
    | None => None
    }
  }
}

// Walk the roots, returning every platform package found (deduped by dir,
// declaration order preserved). Prunes node_modules/lib/.git like Discovery.
let rec walk = async (dir: string, acc: array<platformPkg>): array<platformPkg> => {
  switch inspectDir(dir) {
  | Some(pkg) => acc->Array.push(pkg) // a platform package — record, don't descend into its src
  | None => ()
  }
  let entries = try await _readdir(dir, {withFileTypes: true}) catch {
  | _ => []
  }
  for i in 0 to entries->Array.length - 1 {
    let entry = entries->Array.getUnsafe(i)
    if entry._isDirectory() && !Array.includes(ignoreNames, entry.name) {
      let _ = await walk(join(dir, entry.name), acc)
    }
  }
  acc
}

let scan = async (roots: array<string>): array<platformPkg> => {
  let seen = Dict.make()
  let out = []
  for i in 0 to roots->Array.length - 1 {
    let found = await walk(roots->Array.getUnsafe(i), [])
    found->Array.forEach(pkg =>
      switch seen->Dict.get(pkg.dir) {
      | Some(_) => ()
      | None =>
        seen->Dict.set(pkg.dir, true)
        out->Array.push(pkg)
      }
    )
  }
  out
}
