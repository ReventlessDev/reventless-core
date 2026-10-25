// Plugin configuration reader.
// Reads plugin.json from srcDir (optional) and derives defaults from package.json.

type variant = Composition | Aws({compositionNamespace: string})

// Per-component runtime resource hints, parsed from the optional `runtime`
// block in plugin.json and keyed by component name. Both fields are optional;
// an omitted field falls through to the per-kind builder default. See
// docs/plans/configurable-component-runtime-resources.md.
type runtimeHints = {
  memorySize?: int,
  timeout?: int,
}

/** A package whose slices the plugin composes as its own, from plugin.json's
    `slicesFrom`. `with` names the plugin's module that a functor-shaped body in
    the package is applied to (`Admission`, say), so the package reads the app's
    declaration without importing it. */
type sliceSource = {package: string, @as("with") with_?: string}

type config = {
  name: string,
  heartbeatInterval: int,
  exclude: array<string>,
  // Keyed by component name (e.g. "Customers", "PlaceOrder"). Empty when the
  // plugin.json has no `runtime` block.
  componentRuntime: dict<runtimeHints>,
  slicesFrom?: array<sliceSource>,
  variant: variant,
}

// Convert npm package name to PascalCase plugin name.
// "@scope/my-catalog" → "MyCatalog", "online-shop" → "OnlineShop"
// Single-sourced with reventless-gwt's LocalHost via `PluginName` so the two
// can't drift (a drift silently breaks graph plugin keys).
let packageNameToPluginName = PluginName.fromPackageName

let readJson = (path: string): option<JSON.t> =>
  try Some(NodeFs.readFileSync(path)->JSON.parseOrThrow) catch {
  | _ => None
  }

let getStrField = (json: JSON.t, key: string): option<string> =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(key))
  ->Option.flatMap(JSON.Decode.string)

let getIntField = (json: JSON.t, key: string): option<int> =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(key))
  ->Option.flatMap(JSON.Decode.float)
  ->Option.map(Float.toInt)

let getStrArrayField = (json: JSON.t, key: string): option<array<string>> =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(key))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.map(arr => arr->Array.filterMap(JSON.Decode.string))

// Parse the optional `runtime` object: each key is a component name, each value
// an object with optional `memorySize` / `timeout` ints. A missing block yields
// an empty dict; a non-object entry is skipped.
let getComponentRuntime = (json: JSON.t): dict<runtimeHints> => {
  let result: dict<runtimeHints> = Dict.make()
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("runtime"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.forEach(runtimeObj =>
    runtimeObj
    ->Dict.toArray
    ->Array.forEach(((componentName, entry)) =>
      result->Dict.set(
        componentName,
        {
          memorySize: ?getIntField(entry, "memorySize"),
          timeout: ?getIntField(entry, "timeout"),
        },
      )
    )
  )
  result
}

// Parse the optional `slicesFrom` array: `[{"package": "...", "with": "..."}]`.
// An entry without a package is refused rather than skipped: a slice the author
// listed and the generator silently left out would surface only as a missing
// door at run time.
let getSlicesFrom = (json: JSON.t): option<array<sliceSource>> =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("slicesFrom"))
  ->Option.map(value =>
    switch value->JSON.Decode.array {
    | None => JsError.throwWithMessage("plugin.json: `slicesFrom` is a list of packages")
    | Some(entries) =>
      entries->Array.map(entry =>
        switch getStrField(entry, "package") {
        | None | Some("") =>
          JsError.throwWithMessage(
            `plugin.json: each \`slicesFrom\` entry names a package, got ${JSON.stringify(entry)}`,
          )
        | Some(package) => {package, with_: ?getStrField(entry, "with")}
        }
      )
    }
  )

let read = (~srcDir: string): config => {
  // Read package.json `name` from the parent of srcDir
  let packageJsonPath = NodePath.join([NodePath.dirname(srcDir), "package.json"])
  let packageJsonName = readJson(packageJsonPath)->Option.flatMap(j => getStrField(j, "name"))

  // Read plugin.json from srcDir (optional)
  let pluginJsonPath = NodePath.join([srcDir, "plugin.json"])
  let pluginJson = if NodeFs.existsSync(pluginJsonPath) {
    readJson(pluginJsonPath)
  } else {
    None
  }

  {
    name: PluginName.resolve(
      ~pluginJsonName=pluginJson->Option.flatMap(j => getStrField(j, "name")),
      ~packageJsonName,
    ),
    heartbeatInterval: pluginJson
    ->Option.flatMap(j => getIntField(j, "heartbeatInterval"))
    ->Option.getOr(5),
    exclude: pluginJson->Option.flatMap(j => getStrArrayField(j, "exclude"))->Option.getOr([]),
    componentRuntime: pluginJson->Option.map(getComponentRuntime)->Option.getOr(Dict.make()),
    slicesFrom: ?(pluginJson->Option.flatMap(getSlicesFrom)),
    variant: Composition,
  }
}
