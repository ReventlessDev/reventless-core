// Runtime handler for the `Platform_ComponentDefinitions` admin GraphQL resolver
// — compiled, type-checked ReScript (replaces the inline JS `makeHandlerCode`
// string in Platform_ComponentDefinitions_Lambda.res). Runtime-pure (see
// Platform_AdminScan_Ops); the deploy-time module bundles this into an
// EntryPoint archive and re-exports `handler`.
//
// Scans the Plugin read model for Connected plugins carrying a `structure`,
// collapses to the highest version per plugin name, re-applies the
// `isPublicQueryable` filter (the persisted structure is PRE-filter — it still
// carries Internal ReadModels / StateViewSlices for developer tooling), and
// prepends the built-in Platform_Admin entry. The persisted structure is
// sury-encoded with the same shape as the in-memory adapter's
// encodePluginStructureEntry, so it is wrapped with `pluginId` without decoding.

@val @scope("process") external processEnv: dict<string> = "env"

let str = (item: dict<JSON.t>, key: string): option<string> =>
  item->Dict.get(key)->Option.flatMap(JSON.Decode.string)

// Mirror ReventlessCore.Platform_ComponentDefinitionsApi.isPublicQueryable on
// the read path: a component is public unless its visibility is "Internal".
let isPublicQueryable = (q: JSON.t): bool =>
  switch q->JSON.Decode.object->Option.flatMap(o => o->Dict.get("visibility"))->Option.flatMap(JSON.Decode.string) {
  | Some("Internal") => false
  | _ => true
  }

// Drop Internal ReadModels / StateViewSlices from a persisted structure. A
// missing/non-array field defaults to `[]` (mirrors the JS `?? []`).
let filterStructure = (structure: JSON.t): option<dict<JSON.t>> =>
  switch structure->JSON.Decode.object {
  | None => None
  | Some(obj) =>
    let out = Dict.fromArray(obj->Dict.toArray)
    let filterArr = key =>
      out
      ->Dict.get(key)
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filter(isPublicQueryable)
      ->JSON.Encode.array
    out->Dict.set("readModels", filterArr("readModels"))
    out->Dict.set("stateViewSlices", filterArr("stateViewSlices"))
    Some(out)
  }

// `{pluginId: name, ...filterStructure(structure)}` — pluginId first so the
// structure's fields win on the (never-expected) key collision, matching the JS
// spread. Drops a row with no decodable structure (former `!item.structure`).
let toEntry = (item: dict<JSON.t>, ~name: string): option<JSON.t> =>
  switch item->Dict.get("structure")->Option.flatMap(filterStructure) {
  | None => None
  | Some(structureObj) =>
    let entry = Dict.make()
    entry->Dict.set("pluginId", JSON.Encode.string(name))
    structureObj->Dict.toArray->Array.forEach(((k, v)) => entry->Dict.set(k, v))
    Some(JSON.Encode.object(entry))
  }

// The built-in Platform_Admin entry, injected at deploy time as the
// ADMIN_ENTRY_JSON env var (the admin never Connects to itself, so its structure
// never enters the Plugin read model).
let adminEntry: option<JSON.t> =
  switch processEnv->Dict.get("ADMIN_ENTRY_JSON") {
  | Some(s) if s != "" => Some(JSON.parseOrThrow(s))
  | _ => None
  }

let handler = async (_event: JSON.t): array<JSON.t> => {
  let admin = adminEntry->Option.mapOr([], e => [e])
  switch processEnv->Dict.get("PLUGIN_RM_TABLE") {
  | None | Some("") =>
    Console.error("Platform_ComponentDefinitions: PLUGIN_RM_TABLE env var not set")
    admin
  | Some(table) =>
    let items = await Platform_AdminScan_Ops.scanAll(
      ~tableName=table,
      ~filterExpression="contains(#status, :connected)",
      ~expressionAttributeNames=Dict.fromArray([("#status", "status")]),
      ~expressionAttributeValues=Dict.fromArray([(":connected", JSON.Encode.string("Connected"))]),
    )
    let userEntries =
      Platform_AdminScan_Ops.latestByName(items, ~nameVersionOf=item => item->str("name"), ~toEntry)
    Array.concat(admin, userEntries)
  }
}
