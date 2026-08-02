open JestGlobals

// The load-bearing property is the untagged decode: a value stored the way every
// pre-`@offload` event stored it — a bare record, no wrapper — must still decode,
// now as `Inline`. If that regresses, the frozen plugin-lifecycle corpus stops
// decoding and history becomes unreadable. So the backward-compat case builds its
// "legacy" bytes through the *plain inner schema* (exactly what the old code did)
// and asserts the offload codec reads them back as `Inline`.

@schema
type demo = {name: string, count: int}

let codec = Offload.schema(demoSchema)

describe("Offload codec:", () => {
  testSync("Inline round-trips and encodes with no wrapper key", () => {
    let value = Offload.Inline({name: "a", count: 3})
    let json = value->S.reverseConvertToJsonOrThrow(codec)
    let hasSentinel =
      json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(Offload.sentinelKey))->Option.isSome
    expect(hasSentinel)->toBe(false)
    expect(json->S.parseJsonOrThrow(codec) == value)->toBe(true)
  })

  testSync("Offloaded round-trips and hides under the sentinel key", () => {
    let value = Offload.Offloaded({store: "pluginStructures", key: "sha256/abc", hash: "abc", bytes: 74000})
    let json = value->S.reverseConvertToJsonOrThrow(codec)
    let hasSentinel =
      json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(Offload.sentinelKey))->Option.isSome
    expect(hasSentinel)->toBe(true)
    expect(json->S.parseJsonOrThrow(codec) == value)->toBe(true)
  })

  testSync("legacy inline bytes (no wrapper) decode as Inline", () => {
    // How an event stored the field before `@offload` existed: the raw inner value.
    let legacyJson = {name: "legacy", count: 7}->S.reverseConvertToJsonOrThrow(demoSchema)
    let decoded = legacyJson->S.parseJsonOrThrow(codec)
    expect(decoded == Offload.Inline({name: "legacy", count: 7}))->toBe(true)
  })
})

describe("Offload marker:", () => {
  testSync("optionSchema carries the offload semantic", () =>
    expect(
      Offload.optionSchema(~store="pluginStructures", demoSchema)
      ->S.castToUnknown
      ->Semantic.has(~id=Semantic.Id.offload),
    )->toBe(true)
  )

  testSync("optionSchema declares its store, unqualified for this plugin", () => {
    let target = Offload.optionSchema(~store="pluginStructures", demoSchema)->Offload.getStore
    expect(target->Option.mapOr(false, t => t.store == "pluginStructures" && t.plugin == None))->toBe(
      true,
    )
  })

  testSync("forStore qualifies a cross-plugin store", () => {
    let target = Offload.forStore(~plugin="catalog", ~store="images", demoSchema)->Offload.getStore
    expect(
      target->Option.mapOr(false, t => t.store == "images" && t.plugin == Some("catalog")),
    )->toBe(true)
  })

  testSync("id string matches the wire vocabulary", () => expect(Semantic.Id.offload)->toBe("offload"))
})

describe("Offload client helpers:", () => {
  // Deterministic content hash (same bytes -> same key) and an in-memory transport
  // sharing one dict between upload and fetch, with call counters.
  let hash = s => "H" ++ Int.toString(String.length(s))
  let makeStore = () => {
    let objects = Dict.make()
    let uploads = ref(0)
    let fetches = ref(0)
    let upload = (~key, ~bytes) => {
      uploads := uploads.contents + 1
      objects->Dict.set(key, bytes)
      Promise.resolve()
    }
    let fetch = key => {
      fetches := fetches.contents + 1
      Promise.resolve(objects->Dict.getUnsafe(key))
    }
    (objects, upload, fetch, uploads, fetches)
  }
  let keyOf = (p: Offload.payload<demo>) =>
    switch p {
    | Offloaded({key}) => key
    | Inline(_) => ""
    }

  test("prepare keeps small values inline, no upload", async () => {
    let (_, upload, _, uploads, _) = makeStore()
    let p = await Offload.prepare(
      {name: "a", count: 1},
      ~schema=demoSchema,
      ~store="s",
      ~threshold=10000,
      ~hash,
      ~upload,
    )
    expect(p->Offload.getInline->Option.isSome && uploads.contents == 0)->toBe(true)
  })

  test("prepare offloads large values under a content-addressed key", async () => {
    let (objects, upload, _, uploads, _) = makeStore()
    let p = await Offload.prepare(
      {name: "abcdefghijklmnop", count: 1},
      ~schema=demoSchema,
      ~store="pluginStructures",
      ~threshold=10,
      ~hash,
      ~upload,
    )
    switch p {
    | Offloaded({store, key}) =>
      expect(
        store == "pluginStructures" &&
        key->String.startsWith("sha256/") &&
        uploads.contents == 1 &&
        objects->Dict.get(key)->Option.isSome,
      )->toBe(true)
    | Inline(_) => expect("inline")->toBe("offloaded")
    }
  })

  test("prepare dedupes identical content to the same key", async () => {
    let (_, upload, _, _, _) = makeStore()
    let mk = () =>
      Offload.prepare(
        {name: "abcdefghij", count: 2},
        ~schema=demoSchema,
        ~store="s",
        ~threshold=10,
        ~hash,
        ~upload,
      )
    let a = await mk()
    let b = await mk()
    expect(keyOf(a) == keyOf(b) && keyOf(a) != "")->toBe(true)
  })

  test("resolve: inline needs no fetch, offloaded round-trips", async () => {
    let (_, upload, fetch, _, fetches) = makeStore()
    let inlineBack = await Offload.resolve(Inline({name: "a", count: 1}), ~schema=demoSchema, ~fetch)
    expect(inlineBack.name == "a" && fetches.contents == 0)->toBe(true)
    let big = {name: "abcdefghij", count: 5}
    let p = await Offload.prepare(
      big,
      ~schema=demoSchema,
      ~store="s",
      ~threshold=10,
      ~hash,
      ~upload,
    )
    let back = await Offload.resolve(p, ~schema=demoSchema, ~fetch)
    expect(back == big)->toBe(true)
  })

  test("cachedFetch fetches each key at most once", async () => {
    let (_, upload, fetch, _, fetches) = makeStore()
    let p = await Offload.prepare(
      {name: "abcdefghij", count: 9},
      ~schema=demoSchema,
      ~store="s",
      ~threshold=10,
      ~hash,
      ~upload,
    )
    let cf = Offload.cachedFetch(fetch)
    let _ = await cf(keyOf(p))
    let _ = await cf(keyOf(p))
    expect(fetches.contents)->toBe(1)
  })
})
