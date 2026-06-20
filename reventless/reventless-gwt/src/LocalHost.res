// LocalHost — Phase 4.5 cold local-host foundation (shared by Phases 5, 6, and
// the Phase 9 runner). Reflects the framework's own domain graph WITHOUT parsing
// .res: instantiate reventless-local's `Platform.Make()` once, build each compiled
// `Plugin.res.mjs` against it, read the resolved `pluginStructure` (a plain record
// — no Pulumi Output), and collect the per-plugin structures.
//
// Proven cold (docs/analysis/reventless-vscode-domain-graph-design.md "Spike
// result"): `Make()` and `Plugin.Make(plat)` open no ports and start no timers —
// reading `pluginStructure` never touches the bus/scheduler/server wiring that the
// live `deployPlugin` / `startServers` path adds (that path is the runner's, not
// this). reventless-local is deliberately NOT a static dependency of reventless-gwt
// (gwt is upstream of it); the platform module is reached at runtime by absolute
// path via dynamic import, so a missing local platform is a caller concern, not a
// compile-time coupling.

@module("node:url") external pathToFileURL: string => {"href": string} = "pathToFileURL"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") external join: (string, string) => string = "join"
@module("node:path") external dirname: string => string = "dirname"

type nodeRequire
@module("node:module") external createRequire: string => nodeRequire = "createRequire"
@send external requireResolve: (nodeRequire, string) => string = "resolve"

let dynamicImport: string => promise<'a> = %raw(`(u) => import(u)`)

// Monotonic cache-buster so repeated loads in one process (a watch session
// re-reading the graph after a recompile) re-execute the composition root rather
// than hit Node's URL-keyed ESM cache — same rationale as Loader.res. NOTE: only
// the directly-imported modules are busted; transitively-cached component modules
// stay warm, so a recompiled *component spec* is not picked up until the next load
// of the composition root re-imports it. Full transitive invalidation is deferred
// to the live-update work (Phase 6).
let counter = ref(0)
let bustedUrl = (absolutePath: string): string => {
  counter := counter.contents + 1
  pathToFileURL(absolutePath)["href"] ++ "?t=" ++ Int.toString(counter.contents)
}

type pluginRef = {name: string, modulePath: string, packageDir: string}

type graph = {
  structures: array<(string, Reventless.Plugin.pluginStructure)>,
}

// Dynamic-import shapes. Untyped at the boundary; reventless-local's Platform and
// every generated Plugin emit these exact exports.
type platform
type localPlatformExports = {"Make": unit => platform}
type builtPlugin = {"pluginStructure": Reventless.Plugin.pluginStructure}
type pluginExports = {"Make": platform => builtPlugin}

// ── Plugin name derivation — mirrors generator/Config.read exactly so the graph's
//    plugin keys match the names the framework itself bakes into Plugin.res. ──

// "@scope/my-catalog" → "MyCatalog", "online-shop" → "OnlineShop".
let packageNameToPluginName = (packageName: string): string => {
  let base = switch packageName->String.split("/") {
  | [_scope, local] => local
  | [local] => local
  | parts => parts->Array.getUnsafe(parts->Array.length - 1)
  }
  base
  ->String.split("-")
  ->Array.flatMap(part => part->String.split("_"))
  ->Array.map(word =>
    word === ""
      ? ""
      : word->String.slice(~start=0, ~end=1)->String.toUpperCase ++
          word->String.slice(~start=1, ~end=word->String.length)
  )
  ->Array.join("")
}

let strField = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))->Option.flatMap(JSON.Decode.string)

let readJson = path =>
  try Some(readFileSync(path, "utf8")->JSON.parseOrThrow) catch {
  | _ => None
  }

// plugin.json `name` → else PascalCase(package.json `name`) → else "Plugin".
let derivePluginName = (~pluginSrcDir: string): string => {
  let pluginJson = join(pluginSrcDir, "plugin.json")
  let fromPluginJson =
    existsSync(pluginJson) ? readJson(pluginJson)->Option.flatMap(j => strField(j, "name")) : None
  switch fromPluginJson {
  | Some(name) => name
  | None =>
    let pkgJson = join(dirname(pluginSrcDir), "package.json")
    readJson(pkgJson)
    ->Option.flatMap(j => strField(j, "name"))
    ->Option.map(packageNameToPluginName)
    ->Option.getOr("Plugin")
  }
}

// Given workspace package dirs (e.g. from PackageScan), keep those that carry a
// compiled composition root and pair each with its framework plugin name.
let discover = (~packageDirs: array<string>): array<pluginRef> =>
  packageDirs->Array.filterMap(dir => {
    let srcDir = join(dir, "src")
    let modulePath = join(srcDir, "Plugin.res.mjs")
    existsSync(modulePath)
      ? Some({name: derivePluginName(~pluginSrcDir=srcDir), modulePath, packageDir: dir})
      : None
  })

// Resolve reventless-local's compiled Platform module from a plugin package's
// node_modules. reventless-gwt is upstream of reventless-local (no static dep), but
// every plugin depends on it (`@reventlessdev/reventless-local`), so we resolve the
// specifier relative to the plugin's package.json. `None` when it isn't installed
// there — callers then skip platform-dependent features (dead-code / graph).
let localPlatformSpecifier = "@reventlessdev/reventless-local/src/Platform.res.mjs"
let resolveLocalPlatform = (~fromPackageDir: string): option<string> =>
  try Some(createRequire(join(fromPackageDir, "package.json"))->requireResolve(localPlatformSpecifier)) catch {
  | _ => None
  }

// Cold-load: instantiate the local platform once, build each plugin against it,
// and read its (already-resolved) pluginStructure.
let loadGraph = async (~platformModulePath: string, ~plugins: array<pluginRef>): graph => {
  let platMod: localPlatformExports = await dynamicImport(bustedUrl(platformModulePath))
  let plat = platMod["Make"]()
  let structures = []
  for i in 0 to plugins->Array.length - 1 {
    let plugin = plugins->Array.getUnsafe(i)
    let pluginMod: pluginExports = await dynamicImport(bustedUrl(plugin.modulePath))
    let built = pluginMod["Make"](plat)
    structures->Array.push((plugin.name, built["pluginStructure"]))
  }
  {structures: structures}
}
