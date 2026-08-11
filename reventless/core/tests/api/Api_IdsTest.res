// The id contract: which form each door accepts, in one place.
//
// A row advertises a Relay global id (`btoa("<Type>:<localId>")`) while the
// storage key is the local id. Before this, the typed doors took only the local
// id, so the obvious `X(id: row.id)` returned null with no error. These pin the
// rule that makes either form work — and, just as importantly, the cases where a
// string must NOT be treated as a global id.

open JestGlobals

@val external btoa: string => string = "btoa"

describe("Api_Ids.encode / decode", () => {
  testSync("round-trips a type name and a local id", () => {
    let g = Api_Ids.encode(~typeName="Ordering_Customer", ~localId="cust-42")
    expect(g)->toEqual(btoa("Ordering_Customer:cust-42"))
    expect(Api_Ids.decode(g))->toEqual(Some(("Ordering_Customer", "cust-42")))
  })

  // Ids carrying a colon of their own: only the first one separates.
  testSync("a local id containing a colon survives the round trip", () => {
    let g = Api_Ids.encode(~typeName="Platform_Plugin", ~localId="Catalog@1.0.0:beta")
    expect(Api_Ids.decode(g))->toEqual(Some(("Platform_Plugin", "Catalog@1.0.0:beta")))
  })

  testSync("a plain storage key is not a global id", () =>
    expect(Api_Ids.decode("cust-42"))->toEqual(None)
  )

  // `atob` accepts this and yields text with no colon — decoding must still say no.
  testSync("valid base64 without a colon is not a global id", () =>
    expect(Api_Ids.decode(btoa("nocolonhere")))->toEqual(None)
  )

  // A leading colon would mean an empty type name — nothing `node` could resolve.
  testSync("a decoded value starting with the separator is not a global id", () =>
    expect(Api_Ids.decode(btoa(":cust-42")))->toEqual(None)
  )
})

describe("Api_Ids.alternateKey — the fallback a door tries on a miss", () => {
  testSync("a global id offers the storage key inside it", () =>
    expect(Api_Ids.alternateKey(Api_Ids.encode(~typeName="Catalog_Product", ~localId="p-1")))
    ->toEqual(Some("p-1"))
  )

  testSync("a plain key offers nothing, so the lookup is never retried", () =>
    expect(Api_Ids.alternateKey("p-1"))->toEqual(None)
  )

  // The reason doors try the raw key FIRST and only fall back here: a storage key
  // that happens to be valid base64 must keep resolving to its own row.
  testSync("a key that merely looks like base64 is not silently rewritten", () => {
    let looksBase64 = btoa("Type:inner")
    expect(Api_Ids.alternateKey(looksBase64))->toEqual(Some("inner"))
    // …but the door asks for `looksBase64` first, so a row stored under that exact
    // string wins. `alternateKey` only ever supplies the second attempt.
    expect(Api_Ids.alternateKey("cGxhaW4="))->toEqual(None)
  })
})

// A resolver that stamps the Relay `id` onto a row must not stamp it onto the
// *stored* row: `JSON.Decode.object` hands back the very object the in-memory
// QueryDb holds, so a `Dict.set` writes through. The symptom was a row whose
// advertised id depended on query history — a list answered the storage key
// until someone loaded the detail page, and the global id ever after.
describe("stamping an id onto a row leaves the stored row alone", () => {
  let storedRow = () => {
    let d = Dict.make()
    d->Dict.set("id", JSON.Encode.string("cust-42"))
    d->Dict.set("email", JSON.Encode.string("a@b.c"))
    JSON.Encode.object(d)
  }

  testSync("Dict.copy before set — the pattern the resolvers use", () => {
    let row = storedRow()
    let stamped = {
      let obj = row->JSON.Decode.object->Option.mapOr(Dict.make(), Dict.copy)
      obj->Dict.set(
        "id",
        Api_Ids.encode(~typeName="Ordering_Customer", ~localId="cust-42")->JSON.Encode.string,
      )
      JSON.Encode.object(obj)
    }
    let idOf = j =>
      j->JSON.Decode.object->Option.flatMap(d => d->Dict.get("id"))->Option.flatMap(JSON.Decode.string)
    expect(idOf(stamped))->toEqual(Some(Api_Ids.encode(~typeName="Ordering_Customer", ~localId="cust-42")))
    // The stored row still carries its storage key.
    expect(idOf(row))->toEqual(Some("cust-42"))
  })
})

// `filter.ids` is the door that has always taken either form. Which side needs
// decoding flipped when the typed doors stopped stamping global ids onto rows:
// the row now carries its storage key and the *argument* may be the global one.
describe("filter.ids matches whichever form each side holds", () => {
  let row = (id: string) => {
    let d = Dict.make()
    d->Dict.set("id", JSON.Encode.string(id))
    d->Dict.set("name", JSON.Encode.string("Alpha"))
    JSON.Encode.object(d)
  }
  let idsIn = (~rowId, ~filterIds) => {
    let args = Dict.make()
    args->Dict.set(
      "filter",
      JSON.Encode.object(
        Dict.fromArray([("ids", JSON.Encode.array(filterIds->Array.map(JSON.Encode.string)))]),
      ),
    )
    let conn = QueryDbListQuery.run(
      ~items=[row(rowId)],
      ~argsDict=args,
      ~capability=GraphQL_FragmentGenerator.emptyCapability,
      ~labelField="name",
    )
    conn
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("edges"))
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.length
  }
  let globalFor = localId => Api_Ids.encode(~typeName="Catalog_Product", ~localId)

  testSync("storage key row, storage key filter", () =>
    expect(idsIn(~rowId="p-1", ~filterIds=["p-1"]))->toBe(1)
  )

  // The case the flip fixes: a client passes back the global id it was given by
  // `node`, while the list rows carry storage keys.
  testSync("storage key row, global id filter", () =>
    expect(idsIn(~rowId="p-1", ~filterIds=[globalFor("p-1")]))->toBe(1)
  )

  testSync("global id row, storage key filter", () =>
    expect(idsIn(~rowId=globalFor("p-1"), ~filterIds=["p-1"]))->toBe(1)
  )

  testSync("a filter for another row still excludes it", () =>
    expect(idsIn(~rowId="p-1", ~filterIds=[globalFor("p-2")]))->toBe(0)
  )
})
