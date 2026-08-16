// LocalHost — Phase 4.5 cold local-host foundation (shared by Phases 5, 6, and
// the Phase 9 runner). Reflects the framework's own domain graph WITHOUT parsing
// .res: instantiate reventless-local's `Platform.Make()` once, build each compiled
// `Plugin.res.mjs` against it, read the resolved `pluginStructure` (a plain record
// — no Pulumi Output), and collect the per-plugin structures.
//
// Proven cold: `Make()` and `Plugin.Make(plat)` open no ports and start no timers —
// reading `pluginStructure` never touches the bus/scheduler/server wiring that the
// live `deployPlugin` / `startServers` path adds (that path is the runner's, not
// this). reventless-local is deliberately NOT a static dependency of reventless-gwt
// (gwt is upstream of it); the platform module is reached at runtime by absolute
// path via dynamic import, so a missing local platform is a caller concern, not a
// compile-time coupling.

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
  NodeUrl.pathToFileURL(absolutePath)["href"] ++ "?t=" ++ Int.toString(counter.contents)
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
// Single-sourced with the plugin generator (spec's `Config`) via
// `Reventless.PluginName` so the two can't drift — a drift silently breaks
// graph plugin keys (see the module for the full rationale). Re-exported here
// under the historical name the tests already pin.
let packageNameToPluginName = Reventless.PluginName.fromPackageName

let strField = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))->Option.flatMap(JSON.Decode.string)

let readJson = path =>
  try Some(NodeFs.readFileSync(path)->JSON.parseOrThrow) catch {
  | _ => None
  }

// plugin.json `name` → else PascalCase(package.json `name`) → else "Plugin".
// The precedence itself lives in `Reventless.PluginName.resolve`; this only
// reads the two raw fields with the local node bindings.
let derivePluginName = (~pluginSrcDir: string): string => {
  let pluginJson = NodePath.join([pluginSrcDir, "plugin.json"])
  let pluginJsonName =
    NodeFs.existsSync(pluginJson)
      ? readJson(pluginJson)->Option.flatMap(j => strField(j, "name"))
      : None
  let packageJsonName =
    readJson(NodePath.join([NodePath.dirname(pluginSrcDir), "package.json"]))
    ->Option.flatMap(j => strField(j, "name"))
  Reventless.PluginName.resolve(~pluginJsonName, ~packageJsonName)
}

// Given workspace package dirs (e.g. from PackageScan), keep those that carry a
// compiled composition root and pair each with its framework plugin name.
let discover = (~packageDirs: array<string>): array<pluginRef> =>
  packageDirs->Array.filterMap(dir => {
    let srcDir = NodePath.join([dir, "src"])
    let modulePath = NodePath.join([srcDir, "Plugin.res.mjs"])
    NodeFs.existsSync(modulePath)
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
  try Some(
    NodeModule.createRequire(NodePath.join([fromPackageDir, "package.json"]))
    ->NodeModule.requireResolve(localPlatformSpecifier),
  ) catch {
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
