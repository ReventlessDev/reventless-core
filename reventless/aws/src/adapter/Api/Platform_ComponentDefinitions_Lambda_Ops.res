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

// Drop Internal ReadModels / StateViewSlices from a persisted structure, and
// carry what was dropped on `internalQueryables` — the complement, so a client
// can resolve a reference to an Internal view without any enumeration site
// being able to see it. A missing/non-array field defaults to `[]` (mirrors the
// JS `?? []`), which also covers a structure persisted before this field
// existed: the complement is recomputed here, never read off the structure.
//
// The `~filter=false` path (Platform_PluginStructures) deliberately does not go
// through here — it serves Internal components inline and must not grow a
// duplicate list.
let filterStructure = (structure: dict<JSON.t>): dict<JSON.t> => {
  let out = Dict.fromArray(structure->Dict.toArray)
  let arrAt = key =>
    out->Dict.get(key)->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  let readModels = arrAt("readModels")
  let stateViewSlices = arrAt("stateViewSlices")
  out->Dict.set("readModels", readModels->Array.filter(isPublicQueryable)->JSON.Encode.array)
  out->Dict.set(
    "stateViewSlices",
    stateViewSlices->Array.filter(isPublicQueryable)->JSON.Encode.array,
  )
  out->Dict.set(
    "internalQueryables",
    Array.concat(readModels, stateViewSlices)
    ->Array.filter(q => !isPublicQueryable(q))
    ->JSON.Encode.array,
  )
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
      fetch(key)
      // The bucket answers for the whole platform, so a failure here says which
      // plugin's ref could not be read — otherwise the S3 error names the key
      // and the bucket, and finding the row it came from is a table scan by hand.
      ->Promise.catch(e => {
        let plugin = item->str("name")->Option.getOr("<unnamed>")
        JsError.throwWithMessage(
          `offloaded structure for plugin ${plugin} is unreadable at ${key}: ` ++
          e->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error"),
        )
      })
      ->Promise.then(bytes => {
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

// ── Bake mode ────────────────────────────────────────────────────────────────
// The third thing this function does with the same scan: write the curated
// manifest as a static object instead of answering a query with it.
//
// It belongs here rather than in a tool of its own for the reason the two GraphQL
// fields already share a data source — there is one place that decides what a
// deployed plugin's structure is, and the scan, the offload resolution and the
// version collapse are that decision. A separate reader would be a second copy of
// all three, free to drift about which version of a plugin is deployed.
//
// Invoked directly, after every plugin stack is up: the manifest describes the
// whole deployment, and no single stack's deploy is the moment that is settled.

// The persisted structure is served raw on the query paths — nothing decodes it —
// but curation filters the RECORD and re-encodes through the shared encoder,
// which is what makes an include-list naming everything produce the bytes the
// query returns. So the bake decodes, and heals first: healing fills the list
// fields an older persisted structure simply has no key for, and those are
// exactly the fields the schema requires.
//
// A structure that still fails to decode fails the bake, naming the plugin. The
// alternative — skipping it — ships a shop silently missing a section.
let structureOf = (item: dict<JSON.t>, ~name as _: string): option<(
  string,
  Reventless.Plugin.pluginStructure,
)> =>
  switch (item->str("name"), item->Dict.get("structure")->Option.flatMap(JSON.Decode.object)) {
  | (Some(pluginId), Some(structure)) =>
    let healed = structure->healStructure->JSON.Encode.object
    switch healed->S.parseJsonOrThrow(Reventless.Plugin.pluginStructureSchema) {
    | decoded => Some((pluginId, decoded))
    | exception _ =>
      JsError.throwWithMessage(
        `baked manifest: the structure persisted for "${pluginId}" cannot be decoded — ` ++
        `it was written by a framework version this platform can no longer read. ` ++
        `Redeploy that plugin, or drop it from the include-list.`,
      )
    }
  | _ => None
  }

// One curated surface per audience, beside the default one. Only what the write
// needs travels: the file's key, resolved by the deploy so that the grant, the
// URL in `config.json` and the object written here are one string, and the
// include-list that decides its contents. The group the journey serves is
// carried too, purely so the invocation's report names the audience a file was
// written for.
type journey = {
  group: string,
  key: string,
  selections: array<ReventlessCore.Platform_BakedManifest.selection>,
}

let bakeSelection = (json: JSON.t): option<ReventlessCore.Platform_BakedManifest.selection> => {
  let strings = (o, key) =>
    o
    ->Dict.get(key)
    ->Option.flatMap(JSON.Decode.array)
    ->Option.map(a => a->Array.filterMap(JSON.Decode.string))
  json
  ->JSON.Decode.object
  ->Option.flatMap(o =>
    o
    ->Dict.get("plugin")
    ->Option.flatMap(JSON.Decode.string)
    ->Option.map(plugin => {
      ReventlessCore.Platform_BakedManifest.plugin,
      views: strings(o, "views"),
      commands: strings(o, "commands"),
      derived: strings(o, "derived"),
    })
  )
}

let decodeSelections = (json: JSON.t): array<ReventlessCore.Platform_BakedManifest.selection> =>
  json->JSON.Decode.array->Option.getOr([])->Array.filterMap(bakeSelection)

// The declaration travels as an env var because it is deploy input — stated once
// in the platform program, beside the bucket it is written to. The target travels
// in the invocation payload instead: the bucket only exists inside the host-UI
// half of the deploy, long after this function is built, and a caller that had to
// know the include-list as well would be free to bake something the deployment
// never declared.
let bakeSelections = (): array<ReventlessCore.Platform_BakedManifest.selection> =>
  switch NodeProcess.env->Dict.get("BAKE_SELECTIONS") {
  | None | Some("") => []
  | Some(raw) =>
    switch raw->JSON.parseOrThrow {
    | json => json->decodeSelections
    | exception _ =>
      JsError.throwWithMessage("baked manifest: BAKE_SELECTIONS is not a JSON array")
    }
  }

let bakeJourney = (json: JSON.t): option<journey> =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(o =>
    switch (
      o->Dict.get("group")->Option.flatMap(JSON.Decode.string),
      o->Dict.get("key")->Option.flatMap(JSON.Decode.string),
    ) {
    | (Some(group), Some(key)) =>
      Some({
        group,
        key,
        selections: o->Dict.get("components")->Option.mapOr([], decodeSelections),
      })
    | _ => None
    }
  )

// Absent for every deployment that declares one audience, which is what the
// declaration meant before journeys existed and what it still means.
let bakeJourneys = (): array<journey> =>
  switch NodeProcess.env->Dict.get("BAKE_JOURNEYS") {
  | None | Some("") => []
  | Some(raw) =>
    switch raw->JSON.parseOrThrow->JSON.Decode.array {
    | Some(entries) => entries->Array.filterMap(bakeJourney)
    | None => []
    | exception _ => JsError.throwWithMessage("baked manifest: BAKE_JOURNEYS is not a JSON array")
    }
  }

type bakeTarget = {bucket: string, key: string}

let bakeTargetOf = (event: JSON.t): option<bakeTarget> =>
  event
  ->JSON.Decode.object
  ->Option.flatMap(o =>
    switch (
      o->Dict.get("bake")->Option.flatMap(JSON.Decode.bool),
      o->Dict.get("bucket")->Option.flatMap(JSON.Decode.string),
    ) {
    | (Some(true), Some(bucket)) =>
      Some({
        bucket,
        key: o
        ->Dict.get("key")
        ->Option.flatMap(JSON.Decode.string)
        ->Option.getOr(ReventlessCore.Platform_BakedManifest.defaultKey),
      })
    | _ => None
    }
  )

// ── Registration freshness ───────────────────────────────────────────────────
// The read model this bake scans is updated asynchronously: the plugin stack
// publishes a re-detect, the plugin answers with its definition, the projection
// lands. Invoked seconds after the last stack finished, the scan can still
// describe the deploy before it — and a manifest baked from that is wrong in the
// one way nothing downstream can detect, because it is a perfectly well-formed
// description of the wrong deployment.
//
// So the invocation carries the structure key each plugin stack just wrote. That
// is an equality check rather than an inference from timestamps, and it costs
// nothing for a plugin that was not redeployed: its key already matches. A caller
// that supplies no expectations bakes whatever is current — the query paths never
// send any, and a hand-run bake should not need to.
let bakeExpectations = (event: JSON.t): dict<string> =>
  event
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("expect"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.mapOr(Dict.make(), o =>
    o
    ->Dict.toArray
    ->Array.filterMap(((plugin, key)) => key->JSON.Decode.string->Option.map(k => (plugin, k)))
    ->Dict.fromArray
  )

// The offload key a scanned row carries. None for a structure held inline, which
// on a deployed platform means the row predates offloading — it cannot match an
// expectation, and saying so beats baking it.
let structureRefKey = (item: dict<JSON.t>): option<string> =>
  item
  ->Dict.get("structure")
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(o => o->Dict.get(Reventless.Offload.sentinelKey))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(r => r->Dict.get("key"))
  ->Option.flatMap(JSON.Decode.string)

// Compared against the collapsed latest version per plugin, the same view the
// bake itself takes — an older version's row lingering on the table is not the
// registration anyone is waiting for.
let pendingRegistrations = (items: array<dict<JSON.t>>, ~expect: dict<string>): array<string> => {
  let current =
    Platform_AdminScan_Ops.latestByName(
      items,
      ~nameVersionOf=item => item->str("name"),
      ~toEntry=(item, ~name) => item->structureRefKey->Option.map(key => (name, key)),
    )->Dict.fromArray
  expect
  ->Dict.toArray
  ->Array.filterMap(((plugin, key)) => current->Dict.get(plugin) == Some(key) ? None : Some(plugin))
}

// Every failure mode here is the deployment's own mistake — a name matching no
// component, a structure too old to read, a bucket the function may not write —
// and every one of them produces the same symptom if swallowed: a shop that
// renders nothing, with no line anywhere saying why. So the bake throws, and the
// pipeline step that invoked it fails.
let runBake = async (
  ~target: bakeTarget,
  ~structures: array<(string, Reventless.Plugin.pluginStructure)>,
): array<JSON.t> => {
  let selections = bakeSelections()
  if selections->Array.length == 0 {
    JsError.throwWithMessage(
      "baked manifest: BAKE_SELECTIONS is empty — this platform declares no bake, " ++
      "so there is nothing to write and a shell pointed at the file would find none.",
    )
  }
  // The default journey first and always — the caller supplies its key, because
  // the caller is what knows where the shell it configured fetches from — then
  // one file per declared journey, under the key the deploy resolved.
  let files = Array.concat(
    [(None, target.key, selections)],
    bakeJourneys()->Array.map(j => (Some(j.group), j.key, j.selections)),
  )

  // Every file is curated before any is written, for the reason the in-memory
  // platform curates before it writes: a declaration naming a component that
  // does not exist fails the bake, and failing it halfway would leave the bucket
  // serving one audience's file beside a stale copy of another's.
  let curated = files->Array.map(((group, key, selections)) => (
    group,
    key,
    selections,
    switch ReventlessCore.Platform_BakedManifest.curate(~structures, ~selections) {
    | Error(e) => JsError.throwWithMessage(ReventlessCore.Platform_BakedManifest.describe(e))
    | Ok(manifest) => JSON.stringify(manifest, ~space=2)
    },
  ))

  await Promise.all(
    curated->Array.map(async ((group, key, selections, body)) => {
      let _ = await AwsSdk.S3.PutObjectCommand.make({
        bucket: target.bucket,
        key,
        body: AwsSdk.S3.PutObjectCommand.bodyFromString(body),
        contentType: "application/json",
      })->AwsSdk.S3.PutObjectCommand.send
      let report = Dict.fromArray([
        ("baked", JSON.Encode.bool(true)),
        ("bucket", JSON.Encode.string(target.bucket)),
        ("key", JSON.Encode.string(key)),
        ("plugins", JSON.Encode.int(selections->Array.length)),
        ("bytes", JSON.Encode.int(body->String.length)),
      ])
      // Only a journey's entry carries the audience it was written for, so the
      // default one reports exactly what it reported before journeys existed.
      group->Option.forEach(g => report->Dict.set("group", JSON.Encode.string(g)))
      report->JSON.Encode.object
    }),
  )
}

let handler = async (event: JSON.t): array<JSON.t> => {
  let complete = isComplete(event)
  let bakeTarget = bakeTargetOf(event)
  let toEntry = (item, ~name) => toEntryWith(~filter=!complete, item, ~name)
  let admin = adminEntry->Option.mapOr([], e => [e])
  switch NodeProcess.env->Dict.get("PLUGIN_RM_TABLE") {
  | None | Some("") =>
    Console.error("Platform_ComponentDefinitions: PLUGIN_RM_TABLE env var not set")
    switch bakeTarget {
    | Some(_) =>
      JsError.throwWithMessage(
        "baked manifest: PLUGIN_RM_TABLE env var not set — the bake would write an " ++
        "empty shop rather than fail.",
      )
    | None => admin
    }
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
    let resolveAll = () => Promise.all(rawItems->Array.map(item => resolveStructure(fetch, item)))
    switch bakeTarget {
    | Some(target) =>
      // Checked on the raw rows: the refs are what the deploy can predict, and a
      // row that is behind should not have its structure fetched at all.
      switch pendingRegistrations(rawItems, ~expect=bakeExpectations(event)) {
      | [] =>
        // The built-in admin entry is deliberately absent: it never enters the
        // Plugin read model, and the in-memory bake curates the composed plugins
        // only. A deployment naming it gets `UnknownPlugin`, on both platforms.
        let structures = Platform_AdminScan_Ops.latestByName(
          await resolveAll(),
          ~nameVersionOf=item => item->str("name"),
          ~toEntry=structureOf,
        )
        await runBake(~target, ~structures)
      | pending =>
        // Not an error — the deploy just has not finished arriving. Reported so the
        // caller can invoke again rather than bake the previous deployment.
        [
          Dict.fromArray([
            ("baked", JSON.Encode.bool(false)),
            ("pending", pending->Array.map(JSON.Encode.string)->JSON.Encode.array),
          ])->JSON.Encode.object,
        ]
      }
    | None =>
      let userEntries =
        Platform_AdminScan_Ops.latestByName(
          await resolveAll(),
          ~nameVersionOf=item => item->str("name"),
          ~toEntry,
        )
      Array.concat(admin, userEntries)
    }
  }
}
