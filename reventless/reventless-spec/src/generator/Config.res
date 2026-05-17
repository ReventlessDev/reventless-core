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
    if word === "" {
      ""
    } else {
      word->String.slice(~start=0, ~end=1)->String.toUpperCase ++
        word->String.slice(~start=1, ~end=word->String.length)
    }
  )
  ->Array.join("")
}

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
  // Derive plugin name from package.json in parent of srcDir
  let packageJsonPath = Generator_Node.join([Generator_Node.dirname(srcDir), "package.json"])
  let derivedName =
    readJson(packageJsonPath)
    ->Option.flatMap(j => getStrField(j, "name"))
    ->Option.map(packageNameToPluginName)
    ->Option.getOr("Plugin")

  // Read plugin.json from srcDir (optional)
  let pluginJsonPath = Generator_Node.join([srcDir, "plugin.json"])
  let pluginJson = if Generator_Node.existsSync(pluginJsonPath) {
    readJson(pluginJsonPath)
  } else {
    None
  }

  {
    name: pluginJson->Option.flatMap(j => getStrField(j, "name"))->Option.getOr(derivedName),
    heartbeatInterval: pluginJson
    ->Option.flatMap(j => getIntField(j, "heartbeatInterval"))
    ->Option.getOr(5),
    exclude: pluginJson->Option.flatMap(j => getStrArrayField(j, "exclude"))->Option.getOr([]),
    variant: Composition,
  }
}
