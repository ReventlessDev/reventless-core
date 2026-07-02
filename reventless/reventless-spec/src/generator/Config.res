// Plugin configuration reader.
// Reads plugin.json from srcDir (optional) and derives defaults from package.json.

type variant = Composition | Aws({compositionNamespace: string})

type config = {
  name: string,
  heartbeatInterval: int,
  exclude: array<string>,
  variant: variant,
}

// Convert npm package name to PascalCase plugin name.
// "@scope/my-catalog" → "MyCatalog", "online-shop" → "OnlineShop"
// Single-sourced with reventless-gwt's LocalHost via `PluginName` so the two
// can't drift (a drift silently breaks graph plugin keys).
let packageNameToPluginName = PluginName.fromPackageName

let readJson = (path: string): option<JSON.t> =>
  try Some(Generator_Node.readFileSync(path)->JSON.parseOrThrow) catch {
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

let read = (~srcDir: string): config => {
  // Read package.json `name` from the parent of srcDir
  let packageJsonPath = Generator_Node.join([Generator_Node.dirname(srcDir), "package.json"])
  let packageJsonName = readJson(packageJsonPath)->Option.flatMap(j => getStrField(j, "name"))

  // Read plugin.json from srcDir (optional)
  let pluginJsonPath = Generator_Node.join([srcDir, "plugin.json"])
  let pluginJson = if Generator_Node.existsSync(pluginJsonPath) {
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
    variant: Composition,
  }
}
