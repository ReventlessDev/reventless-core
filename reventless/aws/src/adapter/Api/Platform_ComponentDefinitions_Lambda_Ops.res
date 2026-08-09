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


let str = (item: dict<JSON.t>, key: string): option<string> =>
  item->Dict.get(key)->Option.flatMap(JSON.Decode.string)

// Which list fields each entry collection's members must carry to satisfy the
// `[T!]!` shape the admin SDL declares, plus the nested member lists one level
// down (`references` on a command / event / error).
//
// This handler serves the persisted structure as raw JSON — nothing on the read
// path decodes it through `pluginStructureSchema` — so a component written by a
// deploy that predates one of these fields simply has no key for it. Absent
// resolves to null against a non-null list, GraphQL propagates that null up the
// unbroken non-null chain to the root, and the whole query answers `data: null`:
// ONE plugin still carrying an older structure blackholes every other plugin's
// components. A plugin whose version never changes (a private, unpublished stack)
// stays on its old structure indefinitely, so this is not a transient window.
//
// `[]` is what an absent array already means on every one of these fields — the
// structure is re-derived on every build, so it never encodes "cannot say" — which
// makes filling it in the honest read rather than a guess.
type healSpec = {lists: array<string>, nested: array<(string, array<string>)>}

let refLists = ["references"]

let writeSideHeal = {
  lists: ["commands", "linkedViews", "producedEventTypes", "consumedEventTypes", "events", "errors"],
  nested: [("commands", refLists), ("events", refLists), ("errors", refLists)],
}

let readSideHeal = {
  lists: ["consumedEventTypes", "linkedWriteSide", "searchableFields"],
  nested: [],
}

let healByCollection: array<(string, healSpec)> = [
  ("readModels", readSideHeal),
  ("stateViewSlices", readSideHeal),
  ("stateChangeSlices", writeSideHeal),
  ("aggregates", writeSideHeal),
  ("automationSlices", {lists: ["consumedEventTypes", "producedCommandTypes"], nested: []}),
  (
    "outboundTranslationSlices",
    {lists: ["consumedEventTypes", "inboundCommandTypes"], nested: []},
  ),
  ("inboundTranslationSlices", {lists: ["commandTypes"], nested: []}),
  ("extensions", {lists: ["delegateNames", "eventTypes", "commandTypes"], nested: []}),
]

// Anything that is not already an array — missing, null, or a scalar written by a
// structure this handler cannot make sense of — becomes `[]`.
let fillLists = (obj: dict<JSON.t>, keys: array<string>): unit =>
  keys->Array.forEach(k =>
    switch obj->Dict.get(k) {
    | Some(JSON.Array(_)) => ()
    | _ => obj->Dict.set(k, JSON.Encode.array([]))
    }
  )

let mapMembers = (obj: dict<JSON.t>, key: string, f: dict<JSON.t> => unit): unit =>
  switch obj->Dict.get(key)->Option.flatMap(JSON.Decode.array) {
  | None => ()
  | Some(members) =>
    obj->Dict.set(
      key,
      members
      ->Array.map(m =>
        switch m->JSON.Decode.object {
        | None => m
        | Some(mo) =>
          let out = Dict.fromArray(mo->Dict.toArray)
          f(out)
          JSON.Encode.object(out)
        }
      )
      ->JSON.Encode.array,
    )
  }

let healStructure = (structure: dict<JSON.t>): dict<JSON.t> => {
  let out = Dict.fromArray(structure->Dict.toArray)
  // The collections themselves are `[T!]!` too, so an absent one is the same
  // failure a scale smaller.
  out->fillLists(healByCollection->Array.map(((collection, _)) => collection))
  healByCollection->Array.forEach(((collection, spec)) =>
    out->mapMembers(collection, component => {
      component->fillLists(spec.lists)
      spec.nested->Array.forEach(((key, keys)) =>
        component->mapMembers(key, member => member->fillLists(keys))
      )
    })
  )
  out
}

// Mirror ReventlessCore.Platform_ComponentDefinitionsApi.isPublicQueryable on
// the read path: a component is public unless its visibility is "Internal".
let isPublicQueryable = (q: JSON.t): bool =>
  switch q->JSON.Decode.object->Option.flatMap(o => o->Dict.get("visibility"))->Option.flatMap(JSON.Decode.string) {
  | Some("Internal") => false
  | _ => true
  }

// Drop Internal ReadModels / StateViewSlices from a persisted structure. A
// missing/non-array field defaults to `[]` (mirrors the JS `?? []`).
let filterStructure = (structure: dict<JSON.t>): dict<JSON.t> => {
  let out = Dict.fromArray(structure->Dict.toArray)
  let filterArr = key =>
    out
    ->Dict.get(key)
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filter(isPublicQueryable)
    ->JSON.Encode.array
  out->Dict.set("readModels", filterArr("readModels"))
  out->Dict.set("stateViewSlices", filterArr("stateViewSlices"))
  out
}

// `{pluginId: name, ...structure}` — pluginId first so the structure's fields win
// on the (never-expected) key collision, matching the JS spread. Drops a row with
// no decodable structure (former `!item.structure`).
//
// `~filter` is what separates the two fields this handler serves: AutoUI
// (`Platform_ComponentDefinitions`) gets the public-queryable subset, developer
// tooling (`Platform_PluginStructures`) gets the structure exactly as persisted,
// including Internal components and the producer-side `extensionPoints` that the
// AutoUI entry type does not declare. Both are healed first — the SDL's non-null
// lists are the same on either field, so an unhealed structure breaks both.
let toEntryWith = (~filter: bool, item: dict<JSON.t>, ~name: string): option<JSON.t> => {
  let structure =
    item
    ->Dict.get("structure")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.map(healStructure)
    ->Option.map(s => filter ? filterStructure(s) : s)
  switch structure {
  | None => None
  | Some(structureObj) =>
    let entry = Dict.make()
    entry->Dict.set("pluginId", JSON.Encode.string(name))
    structureObj->Dict.toArray->Array.forEach(((k, v)) => entry->Dict.set(k, v))
    Some(JSON.Encode.object(entry))
  }
}


// The built-in Platform_Admin entry, written at deploy time as an asset file in
// the code archive (the admin never Connects to itself, so its structure never
// enters the Plugin read model). It rides the archive rather than an env var
// because it alone is ~3 KB and the function's variables must fit AWS's 4096-byte
// UpdateFunctionConfiguration limit. process.cwd() is /var/task in Lambda, where
// the archive is extracted.
//
// Shared by both fields. The admin structure has no Internal components and no
// extension points, so its filtered and complete encodings carry the same
// components; the structure-level fields the complete entry adds are absent from
// this JSON and resolve to null, which is what `extensionPoints: None` means.
let adminEntry: option<JSON.t> =
  try {
    switch NodePath.join([NodeProcess.cwd(), "adminEntry.json"])
    ->NodeFs.readFileSync
    ->JSON.parseOrThrow {
    | JSON.Null => None
    | json => Some(json)
    }
  } catch {
  | _ => None
  }

// Resolve an offloaded `structure`: a large structure is content-addressed to the
// offload bucket at deploy time and persisted as an `{$offload: {...}}` reference,
// so fetch the object's bytes and substitute the real structure JSON before it is
// filtered. Inline (or absent) structures pass through untouched. The `fetch` is
// per-hash cached, so an identical structure shared across versions is read once.
let resolveStructure = (
  fetch: string => promise<string>,
  item: dict<JSON.t>,
): promise<dict<JSON.t>> =>
  switch item
  ->Dict.get("structure")
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(o => o->Dict.get(Reventless.Offload.sentinelKey)) {
  | None => Promise.resolve(item)
  | Some(refJson) =>
    switch refJson
    ->JSON.Decode.object
    ->Option.flatMap(r => r->Dict.get("key"))
    ->Option.flatMap(JSON.Decode.string) {
    | None => Promise.resolve(item)
    | Some(key) =>
      fetch(key)->Promise.then(bytes => {
        let resolved = Dict.fromArray(item->Dict.toArray)
        resolved->Dict.set("structure", JSON.parseOrThrow(bytes))
        Promise.resolve(resolved)
      })
    }
  }

// One Lambda serves both fields — the scan, the offload resolution and the
// latest-version-per-plugin collapse are identical work, and duplicating them into
// a second function would mean a second cold start and a second chance for the two
// to disagree about what "the deployed structure" is. The resolver for
// `Platform_PluginStructures` invokes with `{complete: true}`.
let isComplete = (event: JSON.t): bool =>
  event
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("complete"))
  ->Option.flatMap(JSON.Decode.bool)
  ->Option.getOr(false)

let handler = async (event: JSON.t): array<JSON.t> => {
  let complete = isComplete(event)
  let toEntry = (item, ~name) => toEntryWith(~filter=!complete, item, ~name)
  let admin = adminEntry->Option.mapOr([], e => [e])
  switch NodeProcess.env->Dict.get("PLUGIN_RM_TABLE") {
  | None | Some("") =>
    Console.error("Platform_ComponentDefinitions: PLUGIN_RM_TABLE env var not set")
    admin
  | Some(table) =>
    let rawItems = await Platform_AdminScan_Ops.scanAll(
      ~tableName=table,
      ~filterExpression="contains(#status, :connected)",
      ~expressionAttributeNames=Dict.fromArray([("#status", "status")]),
      ~expressionAttributeValues=Dict.fromArray([(":connected", JSON.Encode.string("Connected"))]),
    )
    // Substitute any offloaded structure references with their bytes before filtering.
    let bucket = NodeProcess.env->Dict.get("OFFLOAD_BUCKET")->Option.getOr("")
    let fetch = Reventless.Offload.cachedFetch(key =>
      AwsSdk.S3.GetObjectCommand.getString(~bucket, ~key)
    )
    let items = await Promise.all(rawItems->Array.map(item => resolveStructure(fetch, item)))
    let userEntries =
      Platform_AdminScan_Ops.latestByName(items, ~nameVersionOf=item => item->str("name"), ~toEntry)
    Array.concat(admin, userEntries)
  }
}
