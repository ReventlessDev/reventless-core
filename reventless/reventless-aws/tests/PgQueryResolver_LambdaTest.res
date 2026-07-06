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

let mk = (id, status, name) => {
  let o = Dict.make()
  o->Dict.set("id", JSON.Encode.string(id))
  o->Dict.set("status", JSON.Encode.string(status))
  o->Dict.set("name", JSON.Encode.string(name))
  JSON.Encode.object(o)
}

let store = Dict.fromArray([
  ("p-1", mk("p-1", "active", "Alpha")),
  ("p-2", mk("p-2", "inactive", "Bravo")),
  ("p-3", mk("p-3", "active", "Charlie")),
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

let ops: QueryDb_Adapter.operations = {
  load: async id => Ok(store->Dict.get(id)->Option.mapOr([], i => [i])),
  loadStream: Obj.magic(0), // never called by dispatch
  save: Obj.magic(0),
  saveBatch: Obj.magic(0),
  count: Obj.magic(0),
  delete: Obj.magic(0),
  deleteBatch: Obj.magic(0),
}

let pushdowns: PgQueryResolver_Lambda.pushdowns = {
  indexLookup: async (~readModelName as _, field, value) =>
    allItems()->Array.filter(i => fieldEq(i, field, value)),
  byIds: async (~readModelName as _, ids) =>
    ids->Array.filterMap(id => store->Dict.get(id)),
  listPage: async (~readModelName as _, ~argsDict as _, ~capability as _, ~labelField as _) =>
    listPageReturn.contents,
  itemsPage: async (~readModelName as _, ~subIdField as _, ~id, ~argsDict as _) =>
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
}

let mkPayload = (~kind, ~index=?, ~args=JSON.Encode.object(Dict.make()), ()): PgQueryResolver_Lambda.payload => {
  readModelName: "Things",
  kind,
  ?index,
  arguments: args,
  identity: Reventless.Identity.anonymous,
}

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
