// Unit tests for the Postgres GraphQL-read Lambda dispatcher (B3.2a-2).
//
// `PgQueryResolver_Lambda.dispatch` is pure over a `binding`, so this exercises
// kind routing, arg extraction, spec-level authorization, the queryInterceptor
// hook, and the list push-down/fallback split with an IN-MEMORY mock binding —
// no Postgres. SQL correctness lives in QueryEnginePostgres and is covered by
// its PG_URL-gated parity test.

open JestGlobals
open ReventlessCore

@val external btoa: string => string = "btoa"

let mk = (id, status, name, owner) => {
  let o = Dict.make()
  o->Dict.set("id", JSON.Encode.string(id))
  o->Dict.set("status", JSON.Encode.string(status))
  o->Dict.set("name", JSON.Encode.string(name))
  o->Dict.set("owner", JSON.Encode.string(owner))
  JSON.Encode.object(o)
}

let store = Dict.fromArray([
  ("p-1", mk("p-1", "active", "Alpha", "u-a")),
  ("p-2", mk("p-2", "inactive", "Bravo", "u-b")),
  ("p-3", mk("p-3", "active", "Charlie", "u-a")),
])
let allItems = () => store->Dict.valuesToArray

let fieldEq = (item, field, value) =>
  item
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(field))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.mapOr(false, v => v == value)

// Records whether listPage was consulted, and what it returns (sentinel or None).
let listPageReturn: ref<option<JSON.t>> = ref(None)
// The `ownerScope` the dispatcher handed the push-down on the last list call.
// The push-down's own SQL is covered by the engine's parity harness; what this
// file has to establish is that the dispatcher computes the scope from the
// caller and actually passes it on.
let lastOwnerScope: ref<option<(string, string)>> = ref(None)

let ops: QueryDb_Adapter.operations = {
  load: async id => Ok(store->Dict.get(id)->Option.mapOr([], i => [i])),
  loadStream: Obj.magic(0), // never called by dispatch
  save: Obj.magic(0),
  saveBatch: Obj.magic(0),
  count: Obj.magic(0),
  delete: Obj.magic(0),
  deleteBatch: Obj.magic(0),
}

let lastRetiredScope: ref<option<Reventless.OwnerScope.retiredScope>> = ref(None)

let pushdowns: PgQueryResolver_Lambda.pushdowns = {
  indexLookup: async (~readModelName as _, field, value) =>
    allItems()->Array.filter(i => fieldEq(i, field, value)),
  byIds: async (~readModelName as _, ids) =>
    ids->Array.filterMap(id => store->Dict.get(id)),
  listPage: async (
    ~readModelName as _,
    ~argsDict as _,
    ~capability as _,
    ~labelField as _,
    ~ownerScope: option<(string, string)>=?,
    ~retiredScope: option<Reventless.OwnerScope.retiredScope>=?,
  ) => {
    lastOwnerScope := ownerScope
    lastRetiredScope := retiredScope
    listPageReturn.contents
  },
  itemsPage: async (
    ~readModelName as _,
    ~subIdField as _,
    ~id,
    ~argsDict as _,
    ~ownerScope as _=?,
    ~retiredScope as _=?,
  ) =>
    // Sentinel echoing the requested id, so the dispatch routing is observable.
    JSON.Encode.object(Dict.fromArray([("itemsFor", JSON.Encode.string(id))])),
  scanAll: async (~readModelName as _) => allItems(),
}

let capability: GraphQL_FragmentGenerator.serverCapability = {
  filterFields: [{name: "status", gqlType: "String", range: false}],
  sortFields: ["name", "status"],
}

let makeBinding = (
  ~authorization=Reventless.Authorization.AllowAnonymous,
  ~subIdField=None,
  ~ownerField=None,
  ~retiredField=None,
  ~retiredValues=None,
  (),
): PgQueryResolver_Lambda.binding => {
  ops,
  pushdowns,
  // "byStatus" index stored on the `status` field.
  indexes: [
    {index: "byStatus", type_: "S", idField: "status", projectionType: Reventless.ReadModel.ALL},
  ],
  subIdField,
  capability,
  labelField: "name",
  includeIdParam: true,
  authorization,
  ownerField,
  retiredField,
  retiredValues,
}

let mkPayload = (
  ~kind,
  ~index=?,
  ~args=JSON.Encode.object(Dict.make()),
  ~identity=Reventless.Identity.anonymous,
  (),
): PgQueryResolver_Lambda.payload => {
  readModelName: "Things",
  kind,
  ?index,
  arguments: args,
  identity,
}

external asIdentity: 'a => Reventless.Identity.t = "%identity"

let cognito = (~userId, ~groups): Reventless.Identity.t =>
  asIdentity({"userId": userId, "username": userId, "groups": groups, "provider": "Cognito"})

let objArgs = pairs => JSON.Encode.object(Dict.fromArray(pairs))
let field = (j, k) => j->JSON.Decode.object->Option.flatMap(d => d->Dict.get(k))
let str = (j, k) => j->field(k)->Option.flatMap(JSON.Decode.string)
let ids = (arr: JSON.t) =>
  arr
  ->JSON.Decode.array
  ->Option.getOr([])
  ->Array.filterMap(i => i->str("id"))
  ->Array.toSorted(String.compare)

describe("PgQueryResolver_Lambda.dispatch", () => {
  testPromise("getById returns the item (id-carrying)", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(~kind="getById", ~args=objArgs([("id", JSON.Encode.string("p-2"))]), ()),
    )
    expect(r->str("id"))->toEqual(Some("p-2"))
    expect(r->str("name"))->toEqual(Some("Bravo"))
  })

  testPromise("getById miss → null", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(~kind="getById", ~args=objArgs([("id", JSON.Encode.string("absent"))]), ()),
    )
    expect(r)->toBe(JSON.Encode.null)
  })

  testPromise("byIds returns matches, drops missing", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(
        ~kind="byIds",
        ~args=objArgs([
          ("ids", JSON.Encode.array(["p-1", "absent", "p-3"]->Array.map(JSON.Encode.string))),
        ]),
        (),
      ),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  testPromise("index routes to indexLookup on the idField", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(
        ~kind="index",
        ~index="byStatus",
        // arg name is the index name; value looked up against idField `status`
        ~args=objArgs([("byStatus", JSON.Encode.string("active"))]),
        (),
      ),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  testPromise("list with push-down → returns the connection listPage gives", async () => {
    listPageReturn := Some(JSON.Encode.string("PUSHED"))
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(~kind="list", ()),
    )
    listPageReturn := None
    expect(r)->toEqual(JSON.Encode.string("PUSHED"))
  })

  testPromise("list without push-down → falls back to the shared spec", async () => {
    listPageReturn := None
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(~kind="list", ()),
    )
    // A connection object: edges present, all 3 items, sorted by id.
    let edgeIds =
      r
      ->field("edges")
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(e => e->field("node")->Option.flatMap(n => n->str("id")))
    expect(edgeIds)->toEqual(["p-1", "p-2", "p-3"])
  })

  testPromise("items with subId routes to itemsPage (id echoed)", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(~subIdField=Some("seq"), ()),
      ~payload=mkPayload(~kind="items", ~args=objArgs([("id", JSON.Encode.string("p-2"))]), ()),
    )
    expect(r->str("itemsFor"))->toEqual(Some("p-2"))
  })

  testPromise("items without subId → empty connection", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(~kind="items", ~args=objArgs([("id", JSON.Encode.string("p-2"))]), ()),
    )
    expect(r->field("edges")->Option.flatMap(JSON.Decode.array)->Option.getOr([])->Array.length)->toBe(0)
  })

  testPromise("authorization DenyAll → empty shape per kind", async () => {
    let b = makeBinding(~authorization=DenyAll, ())
    let single = await PgQueryResolver_Lambda.dispatch(
      ~binding=b,
      ~payload=mkPayload(~kind="getById", ~args=objArgs([("id", JSON.Encode.string("p-1"))]), ()),
    )
    expect(single)->toBe(JSON.Encode.null)
    let list = await PgQueryResolver_Lambda.dispatch(~binding=b, ~payload=mkPayload(~kind="list", ()))
    expect(list->field("edges")->Option.flatMap(JSON.Decode.array)->Option.getOr([])->Array.length)->toBe(0)
    let byIds = await PgQueryResolver_Lambda.dispatch(
      ~binding=b,
      ~payload=mkPayload(~kind="byIds", ~args=objArgs([("ids", JSON.Encode.array([]))]), ()),
    )
    expect(byIds->JSON.Decode.array->Option.getOr([])->Array.length)->toBe(0)
  })

  testPromise("queryInterceptor hook Deny → empty shape (auth allowed)", async () => {
    QueryDb_Callback.registerQueryInterceptor(async (~identity as _, ~readModelName as _, ~args as _) =>
      Deny("nope")
    )
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(~kind="getById", ~args=objArgs([("id", JSON.Encode.string("p-1"))]), ()),
    )
    QueryDb_Callback.clearQueryInterceptor()
    expect(r)->toBe(JSON.Encode.null)
  })

  // ── cross-table (@resolves / @resolvesMany / node) ────────────────────────
  // For resolveOne/resolveMany the dispatch binding IS the target binding
  // (the handler selects it); source carries the parent object's key(s).
  testPromise("resolveOne loads target by parent's id field", async () => {
    let payload: PgQueryResolver_Lambda.payload = {
      readModelName: "Things",
      kind: "resolveOne",
      target: "Things",
      source: objArgs([("ref", JSON.Encode.string("p-2"))]),
      sourceIdField: "ref",
      multi: false,
      arguments: objArgs([]),
      identity: Reventless.Identity.anonymous,
    }
    let r = await PgQueryResolver_Lambda.dispatch(~binding=makeBinding(), ~payload)
    expect(r->str("id"))->toEqual(Some("p-2"))
  })

  testPromise("resolveOne multi via target index → array", async () => {
    let payload: PgQueryResolver_Lambda.payload = {
      readModelName: "Things",
      kind: "resolveOne",
      target: "Things",
      source: objArgs([("st", JSON.Encode.string("active"))]),
      sourceIdField: "st",
      targetIndex: "byStatus",
      targetIndexIdField: "status",
      multi: true,
      arguments: objArgs([]),
      identity: Reventless.Identity.anonymous,
    }
    let r = await PgQueryResolver_Lambda.dispatch(~binding=makeBinding(), ~payload)
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  testPromise("resolveMany batch-loads target by parent's ids field", async () => {
    let payload: PgQueryResolver_Lambda.payload = {
      readModelName: "Things",
      kind: "resolveMany",
      target: "Things",
      source: objArgs([
        ("refs", JSON.Encode.array(["p-1", "x", "p-3"]->Array.map(JSON.Encode.string))),
      ]),
      sourceIdsField: "refs",
      arguments: objArgs([]),
      identity: Reventless.Identity.anonymous,
    }
    let r = await PgQueryResolver_Lambda.dispatch(~binding=makeBinding(), ~payload)
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  testPromise("node decodes global id → __typename + item", async () => {
    // Register a binding + node type in the module-level registries.
    PgQueryResolver_Lambda.register(~readModelName="Things", makeBinding())
    PgQueryResolver_Lambda.registerNodeType(~typeName="Thing", ~readModelName="Things")
    let payload: PgQueryResolver_Lambda.payload = {
      readModelName: "",
      kind: "node",
      arguments: objArgs([("id", JSON.Encode.string(btoa("Thing:p-2")))]),
      identity: Reventless.Identity.anonymous,
    }
    let r = await PgQueryResolver_Lambda.handler(payload, Obj.magic(Nullable.null))
    expect(r->str("__typename"))->toEqual(Some("Thing"))
    expect(r->str("name"))->toEqual(Some("Bravo"))
  })

  testPromise("node with unknown type → null", async () => {
    let payload: PgQueryResolver_Lambda.payload = {
      readModelName: "",
      kind: "node",
      arguments: objArgs([("id", JSON.Encode.string(btoa("Nope:p-1")))]),
      identity: Reventless.Identity.anonymous,
    }
    let r = await PgQueryResolver_Lambda.handler(payload, Obj.magic(Nullable.null))
    expect(r)->toBe(JSON.Encode.null)
  })

  // ── auth-table pipeline (group-restricted index) ──────────────────────────
  // Auth table (another read model) maps index value → { ownerId: <username> }.
  let authStore = Dict.fromArray([
    ("active", JSON.Encode.object(Dict.fromArray([("ownerId", JSON.Encode.string("alice"))]))),
  ])
  let authOps: QueryDb_Adapter.operations = {
    load: async id => Ok(authStore->Dict.get(id)->Option.mapOr([], r => [r])),
    loadStream: Obj.magic(0),
    save: Obj.magic(0),
    saveBatch: Obj.magic(0),
    count: Obj.magic(0),
    delete: Obj.magic(0),
    deleteBatch: Obj.magic(0),
  }
  let authBinding = {...makeBinding(), PgQueryResolver_Lambda.ops: authOps}
  let lookupAuth = name => name == "AuthTable" ? Some(authBinding) : None
  let ident = (~username, ~groups): Reventless.Identity.t => {
    userId: username,
    username,
    groups,
    provider: InMemory,
  }
  let authIndexPayload = (~username, ~groups): PgQueryResolver_Lambda.payload => {
    readModelName: "Things",
    kind: "index",
    index: "byStatus",
    authTable: "AuthTable",
    authGroup: "Owner",
    arguments: objArgs([("byStatus", JSON.Encode.string("active"))]),
    identity: ident(~username, ~groups),
  }

  testPromise("auth index: group member who owns → results", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~lookupBinding=lookupAuth,
      ~payload=authIndexPayload(~username="alice", ~groups=["Owner"]),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  testPromise("auth index: group member who does NOT own → empty", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~lookupBinding=lookupAuth,
      ~payload=authIndexPayload(~username="bob", ~groups=["Owner"]),
    )
    expect(r->JSON.Decode.array->Option.getOr([])->Array.length)->toBe(0)
  })

  testPromise("auth index: non-member passes through → results", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~lookupBinding=lookupAuth,
      ~payload=authIndexPayload(~username="bob", ~groups=[]),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  testPromise("unmapped kind throws", async () => {
    let threw = try {
      let _ = await PgQueryResolver_Lambda.dispatch(
        ~binding=makeBinding(),
        ~payload=mkPayload(~kind="frobnicate", ()),
      )
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)
  })
})

// A client holding a row reads its `id` and passes it back. On the local platform
// that `id` is a Relay global id; the typed doors used to take only the storage
// key and answered null, with no error to point at. These pin the either-form
// rule at the door, so the same client call works whichever form it holds.
describe("id form — the typed doors take either", () => {
  let globalIdFor = localId => ReventlessCore.Api_Ids.encode(~typeName="Thing", ~localId)

  testPromise("getById resolves a Relay global id", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(
        ~kind="getById",
        ~args=objArgs([("id", JSON.Encode.string(globalIdFor("p-2")))]),
        (),
      ),
    )
    expect(r->str("name"))->toEqual(Some("Bravo"))
  })

  // The row's `id` must come back as the storage key it was found under — echoing
  // the argument would hand back an id nothing else accepts.
  testPromise("getById reports the storage key it resolved to", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(
        ~kind="getById",
        ~args=objArgs([("id", JSON.Encode.string(globalIdFor("p-2")))]),
        (),
      ),
    )
    expect(r->str("id"))->toEqual(Some("p-2"))
  })

  testPromise("getById still resolves a plain storage key", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(~kind="getById", ~args=objArgs([("id", JSON.Encode.string("p-2"))]), ()),
    )
    expect(r->str("name"))->toEqual(Some("Bravo"))
  })

  testPromise("getById on a global id for a row that does not exist is still null", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(
        ~kind="getById",
        ~args=objArgs([("id", JSON.Encode.string(globalIdFor("absent")))]),
        (),
      ),
    )
    expect(r)->toBe(JSON.Encode.null)
  })

  testPromise("byIds accepts the two forms mixed in one call", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(
        ~kind="byIds",
        ~args=objArgs([
          (
            "ids",
            JSON.Encode.array([
              JSON.Encode.string("p-1"),
              JSON.Encode.string(globalIdFor("p-3")),
            ]),
          ),
        ]),
        (),
      ),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  // The fallback lookup must not fire when the first pass already answered — an
  // all-raw call is the common path and pays for one round trip, not two.
  testPromise("byIds with every id found does not double-count", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=makeBinding(),
      ~payload=mkPayload(
        ~kind="byIds",
        ~args=objArgs([
          ("ids", JSON.Encode.array(["p-1", "p-3"]->Array.map(JSON.Encode.string))),
        ]),
        (),
      ),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })
})

// ── Owner scoping ───────────────────────────────────────────────────────────
// The push-down's SQL is the engine's business and is covered by its parity
// harness. What has to hold HERE is that the dispatcher derives the scope from
// the caller and hands it on — a push-down that supports scoping and a
// dispatcher that never passes one produces a fully unscoped deployment while
// every SQL test stays green.
describe("owner scoping", () => {
  let ownedBinding = () => makeBinding(~ownerField=Some("owner"), ())
  let shopper = cognito(~userId="u-a", ~groups=["User"])

  let listWith = async (~binding, ~identity) => {
    lastOwnerScope := None
    listPageReturn := Some(JSON.Encode.string("pushed"))
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding,
      ~payload=mkPayload(~kind="list", ~identity, ()),
    )
    (r, lastOwnerScope.contents)
  }

  testPromise("a shopper's list is scoped to their own id", async () => {
    let (_, scope) = await listWith(~binding=ownedBinding(), ~identity=shopper)
    expect(scope)->toEqual(Some(("owner", "u-a")))
  })

  testPromise("an elevated caller's list is not scoped", async () => {
    Reventless.OwnerScope.setElevatedGroups(["Admin"])
    let (_, scope) = await listWith(
      ~binding=ownedBinding(),
      ~identity=cognito(~userId="ops-1", ~groups=["Admin"]),
    )
    Reventless.OwnerScope.setElevatedGroups([])
    expect(scope)->toBe(None)
  })

  // The control that keeps this from being vacuous: a view with no `@owner`
  // field must reach the push-down with no scope at all, for every caller.
  testPromise("a view with no owner field is never scoped", async () => {
    let (_, scope) = await listWith(~binding=makeBinding(), ~identity=shopper)
    expect(scope)->toBe(None)
  })

  testPromise("an unidentified caller is refused before the push-down runs", async () => {
    lastOwnerScope := None
    listPageReturn := Some(JSON.Encode.string("pushed"))
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=ownedBinding(),
      ~payload=mkPayload(~kind="list", ~identity=Reventless.Identity.anonymous, ()),
    )
    // Not the sentinel, and the push-down was never consulted — the refusal
    // happens above it rather than by handing it a value nobody holds.
    expect((r->field("edges"), lastOwnerScope.contents))->toEqual((
      Some(JSON.Encode.array([])),
      None,
    ))
  })

  testPromise("getById hides a row the caller does not own", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=ownedBinding(),
      ~payload=mkPayload(
        ~kind="getById",
        ~args=objArgs([("id", JSON.Encode.string("p-2"))]),
        ~identity=shopper,
        (),
      ),
    )
    expect(r)->toBe(JSON.Encode.null)
  })

  testPromise("getById still returns a row the caller does own", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=ownedBinding(),
      ~payload=mkPayload(
        ~kind="getById",
        ~args=objArgs([("id", JSON.Encode.string("p-1"))]),
        ~identity=shopper,
        (),
      ),
    )
    expect(r->str("id"))->toEqual(Some("p-1"))
  })

  testPromise("byIds drops rows the caller does not own", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=ownedBinding(),
      ~payload=mkPayload(
        ~kind="byIds",
        ~args=objArgs([
          ("ids", JSON.Encode.array(["p-1", "p-2", "p-3"]->Array.map(JSON.Encode.string))),
        ]),
        ~identity=shopper,
        (),
      ),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })

  testPromise("an index query drops rows the caller does not own", async () => {
    let r = await PgQueryResolver_Lambda.dispatch(
      ~binding=ownedBinding(),
      ~payload=mkPayload(
        ~kind="index",
        ~index="byStatus",
        ~args=objArgs([("byStatus", JSON.Encode.string("active"))]),
        ~identity=shopper,
        (),
      ),
    )
    expect(r->ids)->toEqual(["p-1", "p-3"])
  })
})
