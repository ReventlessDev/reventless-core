// Guards the read-path healing in Platform_ComponentDefinitions_Lambda_Ops.
//
// The handler serves a persisted plugin structure as raw JSON — it is never
// decoded through `pluginStructureSchema` — so a structure written before a
// required list field existed reaches the resolver without that key. Against the
// admin SDL's `[T!]!` the missing key resolves to null, GraphQL propagates the
// null up an unbroken non-null chain, and the entire query answers `data: null`.
// One plugin on an older structure therefore blackholes every other plugin.
//
// A plugin whose version never changes never re-runs the connect handshake, so it
// keeps its old structure indefinitely — the reason this is worth healing rather
// than waiting out.

open JestGlobals

let entry = (~filter, structure: JSON.t): option<dict<JSON.t>> =>
  Platform_ComponentDefinitions_Lambda_Ops.toEntryWith(
    ~filter,
    Dict.fromArray([("structure", structure)]),
    ~name="Ordering",
  )->Option.flatMap(JSON.Decode.object)

let members = (entry: dict<JSON.t>, collection: string): array<dict<JSON.t>> =>
  entry
  ->Dict.get(collection)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(JSON.Decode.object)

// A state-change slice as persisted before `errors` (and before `references` on a
// command) existed: every other required list is present.
let preErrorsSlice = JSON.parseOrThrow(`{
  "name": "PlaceOrder",
  "commands": [{"name": "PlaceOrder", "schema": "{}", "level": "Collection", "mutationField": "placeOrder"}],
  "linkedViews": [],
  "producedEventTypes": ["OrderPlaced"],
  "consumedEventTypes": [],
  "events": []
}`)

let preErrorsStructure = Dict.fromArray([
  ("stateChangeSlices", JSON.Encode.array([preErrorsSlice])),
])->JSON.Encode.object

describe("toEntryWith heals a structure persisted before a required list existed", () => {
  testSync("fills the absent list on the component", () => {
    let slice =
      entry(~filter=false, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
    expect(slice->Option.flatMap(s => s->Dict.get("errors")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("fills the absent list one level down, on a command's references", () => {
    let command =
      entry(~filter=false, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
      ->Option.flatMap(s => s->Dict.get("commands"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.flatMap(Array.get(_, 0))
      ->Option.flatMap(JSON.Decode.object)
    expect(command->Option.flatMap(c => c->Dict.get("references")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("fills an absent collection, which is a non-null list of its own", () => {
    let e = entry(~filter=false, preErrorsStructure)
    expect(e->Option.flatMap(o => o->Dict.get("aggregates")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("leaves a present list untouched", () => {
    let slice =
      entry(~filter=false, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
    expect(slice->Option.flatMap(s => s->Dict.get("producedEventTypes")))->toEqual(
      Some(JSON.Encode.array([JSON.Encode.string("OrderPlaced")])),
    )
  })

  testSync("heals the filtered field too — both fields share the component types", () => {
    let slice =
      entry(~filter=true, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
    expect(slice->Option.flatMap(s => s->Dict.get("errors")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("still drops Internal read models when filtering", () => {
    let structure = Dict.fromArray([
      (
        "readModels",
        JSON.Encode.array([
          JSON.parseOrThrow(`{"name": "Orders", "visibility": "Internal"}`),
          JSON.parseOrThrow(`{"name": "Products"}`),
        ]),
      ),
    ])->JSON.Encode.object
    let names =
      entry(~filter=true, structure)
      ->Option.map(members(_, "readModels"))
      ->Option.getOr([])
      ->Array.filterMap(m => m->Dict.get("name")->Option.flatMap(JSON.Decode.string))
    expect(names)->toEqual(["Products"])
  })
})

// The persisted structure is pre-filter, so this handler is a twin of the
// in-memory `encodePluginStructureEntry` rather than a consequence of it. A shell
// reading `internalQueryables` against a platform that emits it on only one
// transport gets working pickers locally and silent text inputs when deployed —
// which is why the split is asserted here as well as in core.
describe("toEntryWith carries Internal queryables on the filtered field", () => {
  let mixed = Dict.fromArray([
    (
      "readModels",
      JSON.Encode.array([
        JSON.parseOrThrow(`{"name": "AvailableProducts", "visibility": "Internal"}`),
        JSON.parseOrThrow(`{"name": "Products"}`),
      ]),
    ),
    (
      "stateViewSlices",
      JSON.Encode.array([
        JSON.parseOrThrow(`{"name": "PendingShipments", "visibility": "Internal"}`),
      ]),
    ),
  ])->JSON.Encode.object

  let namesAt = (~filter, collection) =>
    entry(~filter, mixed)
    ->Option.map(members(_, collection))
    ->Option.getOr([])
    ->Array.filterMap(m => m->Dict.get("name")->Option.flatMap(JSON.Decode.string))

  testSync("emits the complement of the filter, fed by both source arrays", () =>
    expect(namesAt(~filter=true, "internalQueryables"))->toEqual([
      "AvailableProducts",
      "PendingShipments",
    ])
  )

  testSync("keeps the surface lists public-only", () => {
    expect(namesAt(~filter=true, "readModels"))->toEqual(["Products"])
    expect(namesAt(~filter=true, "stateViewSlices"))->toEqual([])
  })

  // Platform_PluginStructures serves Internal components inline; a duplicate list
  // there would be a second answer to a question that already has one.
  testSync("adds nothing to the complete field", () =>
    expect(
      entry(~filter=false, mixed)->Option.flatMap(o => o->Dict.get("internalQueryables")),
    )->toEqual(None)
  )

  // A structure persisted before the field existed has no key for it, and must not
  // grow one from its own contents — the complement is always recomputed.
  testSync("computes the complement rather than reading it off the structure", () => {
    let stale = Dict.fromArray([
      ("internalQueryables", JSON.parseOrThrow(`[{"name": "Stale"}]`)),
      ("readModels", JSON.parseOrThrow(`[{"name": "Products"}]`)),
    ])->JSON.Encode.object
    let names =
      entry(~filter=true, stale)
      ->Option.map(members(_, "internalQueryables"))
      ->Option.getOr([])
      ->Array.filterMap(m => m->Dict.get("name")->Option.flatMap(JSON.Decode.string))
    expect(names)->toEqual([])
  })
})

// ── Bake mode ────────────────────────────────────────────────────────────────
// The same scan, written out instead of answered with. Two inputs decide what a
// bake does and neither is checkable at deploy time: the include-list the
// platform put in the environment, and the target its caller supplied. Both are
// pure, so both are assertable without a Lambda.

describe("bakeTargetOf", () => {
  let target = raw => Platform_ComponentDefinitions_Lambda_Ops.bakeTargetOf(JSON.parseOrThrow(raw))

  // The read paths must stay read paths: an AppSync resolver invokes with
  // `{}` or `{complete: true}`, and neither may write an object.
  testSync("a query invocation is not a bake", () => {
    expect(target(`{}`)->Option.isNone)->toBe(true)
    expect(target(`{"complete": true}`)->Option.isNone)->toBe(true)
  })

  // No bucket, no default. Guessing one would write the manifest somewhere
  // nothing serves it, which reads as a bake that worked.
  testSync("a bake without a target is not a bake", () =>
    expect(target(`{"bake": true}`)->Option.isNone)->toBe(true)
  )

  testSync("defaults the key to the one the deploy tells the shell to fetch", () =>
    expect(target(`{"bake": true, "bucket": "host-ui"}`)->Option.map(t => t.key))->toEqual(
      Some("component-manifest.json"),
    )
  )

  testSync("takes an explicit key", () =>
    expect(
      target(`{"bake": true, "bucket": "host-ui", "key": "storefront.json"}`)->Option.map(t => (
        t.bucket,
        t.key,
      )),
    )->toEqual(Some(("host-ui", "storefront.json")))
  )
})

describe("bakeSelection", () => {
  let sel = raw => Platform_ComponentDefinitions_Lambda_Ops.bakeSelection(JSON.parseOrThrow(raw))

  // Absent is not empty. `views` absent means every public component of that
  // plugin; `views: []` means none of them, and a decoder that collapsed the two
  // would silently bake an empty section.
  testSync("keeps absent and empty apart", () => {
    expect(sel(`{"plugin": "Catalog"}`)->Option.flatMap(s => s.views))->toEqual(None)
    expect(sel(`{"plugin": "Catalog", "views": []}`)->Option.flatMap(s => s.views))->toEqual(
      Some([]),
    )
  })

  testSync("reads the named components", () =>
    expect(
      sel(`{"plugin": "Ordering", "views": ["Orders"], "commands": ["PlaceOrder"]}`)->Option.map(
        s => (s.plugin, s.views, s.commands),
      ),
    )->toEqual(Some(("Ordering", Some(["Orders"]), Some(["PlaceOrder"]))))
  )

  testSync("refuses an entry naming no plugin", () =>
    expect(sel(`{"views": ["Orders"]}`)->Option.isNone)->toBe(true)
  )
})

// The bake reads a read model the deploy updates asynchronously, so "is this the
// deployment I was asked to bake" is a question it has to be able to answer. The
// answer is an equality check against the key each plugin stack just wrote.
describe("pendingRegistrations", () => {
  let row = (~name, ~key=?, ()) => {
    let item = Dict.fromArray([("name", JSON.Encode.string(name))])
    key->Option.forEach(k =>
      item->Dict.set(
        "structure",
        JSON.parseOrThrow(`{"$offload": {"store": "pluginStructures", "key": "${k}"}}`),
      )
    )
    item
  }

  let pending = (rows, expect) =>
    Platform_ComponentDefinitions_Lambda_Ops.pendingRegistrations(
      rows,
      ~expect=Dict.fromArray(expect),
    )

  testSync("nothing is pending when every row carries the key the deploy wrote", () =>
    expect(
      pending(
        [row(~name="Catalog", ~key="sha256/a", ()), row(~name="Ordering", ~key="sha256/b", ())],
        [("Catalog", "sha256/a"), ("Ordering", "sha256/b")],
      ),
    )->toEqual([])
  )

  // The window this exists for: the stack wrote a new structure, the row still
  // points at the one before it.
  testSync("names a plugin still carrying the previous structure", () =>
    expect(
      pending(
        [row(~name="Catalog", ~key="sha256/a", ()), row(~name="Ordering", ~key="sha256/old", ())],
        [("Catalog", "sha256/a"), ("Ordering", "sha256/new")],
      ),
    )->toEqual(["Ordering"])
  )

  // A plugin that has never registered is behind, not absent — baking without it
  // would ship a shop missing a section.
  testSync("names a plugin with no row at all", () =>
    expect(pending([], [("Ordering", "sha256/new")]))->toEqual(["Ordering"])
  )

  // Deployed before the stack exported its key, or invoked by hand: bake what is
  // current rather than wait for an expectation nobody stated.
  testSync("waits for nothing when the caller expects nothing", () =>
    expect(pending([row(~name="Ordering", ~key="sha256/old", ())], []))->toEqual([])
  )

  testSync("reads the expectations off the invocation payload", () =>
    expect(
      Platform_ComponentDefinitions_Lambda_Ops.bakeExpectations(
        JSON.parseOrThrow(`{"bake": true, "expect": {"Ordering": "sha256/b"}}`),
      )->Dict.get("Ordering"),
    )->toEqual(Some("sha256/b"))
  )
})

describe("resolveStructure", () => {
  let item = (structure: string) =>
    Dict.fromArray([
      ("name", JSON.Encode.string("Ordering")),
      ("structure", JSON.parseOrThrow(structure)),
    ])

  let offloaded = `{"$offload": {"store": "pluginStructures", "key": "sha256/abc", "bytes": 4}}`

  test("substitutes the fetched bytes for the reference", async () => {
    let resolved = await Platform_ComponentDefinitions_Lambda_Ops.resolveStructure(
      _ => Promise.resolve(`{"aggregates": []}`),
      item(offloaded),
    )
    expect(resolved->Dict.get("structure")->Option.map(j => JSON.stringify(j)))->toEqual(
      Some(`{"aggregates":[]}`),
    )
  })

  // One offload bucket serves every plugin, so the S3 error names only the key —
  // which plugin's row carries the unreadable reference is the part worth having.
  // A missing object is the shape a deploy leaves behind while the read model
  // still points at the previous structure.
  test("names the plugin whose reference cannot be read", async () => {
    let failed = await Platform_ComponentDefinitions_Lambda_Ops.resolveStructure(
      _ => Promise.reject(JsExn.anyToExnInternal(JsError.make("AccessDenied"))),
      item(offloaded),
    )
    ->Promise.thenResolve(_ => None)
    ->Promise.catch(e =>
      Promise.resolve(e->JsExn.fromException->Option.flatMap(JsExn.message))
    )
    expect(failed)->toEqual(
      Some("offloaded structure for plugin Ordering is unreadable at sha256/abc: AccessDenied"),
    )
  })

  test("passes an inline structure through untouched", async () => {
    let resolved = await Platform_ComponentDefinitions_Lambda_Ops.resolveStructure(
      _ => Promise.reject(JsExn.anyToExnInternal(JsError.make("must not fetch"))),
      item(`{"aggregates": []}`),
    )
    expect(resolved->Dict.get("structure")->Option.map(j => JSON.stringify(j)))->toEqual(
      Some(`{"aggregates":[]}`),
    )
  })
})
