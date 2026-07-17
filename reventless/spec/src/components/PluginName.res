// Single source of truth for deriving a plugin's PascalCase name from its npm
// package name, and for resolving the final plugin name from the (optional)
// plugin.json `name` and package.json `name`. The plugin generator
// (`generator/Config`) and the external tooling that reconstructs the domain
// graph (`reventless-gwt`'s `LocalHost`) both derive from this, so the two can't
// drift — a drift here silently breaks graph plugin keys (the graph would key
// plugins under names that don't match the ones the generator bakes into
// `Plugin.res`). See [[reference_ppx_spec_name_single_strip]] for the sibling
// spec-name derivation.

// "@scope/my-catalog" → "MyCatalog", "online-shop" → "OnlineShop".
let fromPackageName = (packageName: string): string => {
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

// plugin.json `name` wins; else PascalCase(package.json `name`); else "Plugin".
// The two callers each read the raw fields with their own node bindings, then
// share this precedence so the resolution can never diverge.
let resolve = (~pluginJsonName: option<string>, ~packageJsonName: option<string>): string =>
  switch pluginJsonName {
  | Some(name) => name
  | None => packageJsonName->Option.map(fromPackageName)->Option.getOr("Plugin")
  }
