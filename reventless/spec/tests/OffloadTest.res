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
    let json = value->Util_Sury.toJson(codec)
    let hasSentinel =
      json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(Offload.sentinelKey))->Option.isSome
    expect(hasSentinel)->toBe(false)
    expect(json->Util_Sury.fromJson(codec) == value)->toBe(true)
  })

  testSync("Offloaded round-trips and hides under the sentinel key", () => {
    let value = Offload.Offloaded({store: "pluginStructures", key: "sha256/abc", hash: "abc", bytes: 74000})
    let json = value->Util_Sury.toJson(codec)
    let hasSentinel =
      json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(Offload.sentinelKey))->Option.isSome
    expect(hasSentinel)->toBe(true)
    expect(json->Util_Sury.fromJson(codec) == value)->toBe(true)
  })

  testSync("legacy inline bytes (no wrapper) decode as Inline", () => {
    // How an event stored the field before `@offload` existed: the raw inner value.
    let legacyJson = {name: "legacy", count: 7}->Util_Sury.toJson(demoSchema)
    let decoded = legacyJson->Util_Sury.fromJson(codec)
    expect(decoded == Offload.Inline({name: "legacy", count: 7}))->toBe(true)
  })
})

// The optional field is where the codec's shape is load-bearing: an absent value
// and an offloaded one each broke on 11.0.0-rc.0 while the inline case — the one a
// test reaches for first — kept working. Both failures came from hand-written
// `S.transform` arms and went away when the arms became declared (`S.object` /
// `S.shape`); see docs/analysis/done/sury-rc0-optional-union-encode.md.
describe("Offload optional field:", () => {
  let optional = Offload.optionSchema(~store="pluginStructures", demoSchema)

  testSync("absent encodes to null, not a crash", () => {
    expect(None->Util_Sury.toJson(optional))->toEqual(JSON.Null)
    expect(None->Util_Sury.toJsonString(optional))->toBe("null")
  })

  testSync("offloaded encodes to a JSON string, not just to JSON", () => {
    // A json-typed union arm cannot chain into a non-JSON target, so this
    // succeeded through `toJson` and failed through `toJsonString`.
    let value = Some(
      Offload.Offloaded({store: "pluginStructures", key: "sha256/abc", hash: "abc", bytes: 74000}),
    )
    expect(value->Util_Sury.toJsonString(optional))->toBe(
      `{"$offload":{"store":"pluginStructures","key":"sha256/abc","hash":"abc","bytes":74000}}`,
    )
  })

  testSync("every value round-trips", () => {
    let values = [
      None,
      Some(Offload.Inline({name: "a", count: 3})),
      Some(Offload.Offloaded({store: "s", key: "sha256/abc", hash: "abc", bytes: 74000})),
    ]
    expect(values->Array.map(v => v->Util_Sury.toJson(optional)->Util_Sury.fromJson(optional)))->toEqual(
      values,
    )
  })

  testSync("the union still advertises null, which replay heals against", () => {
    // `Message.fillMissingDefaults` reads `has.null` to turn an absent field into
    // `None`. Lose it and an absent field resolves to the first object member instead.
    let has = (optional->S.castToUnknown->Obj.magic)["has"]
    expect(has["null"])->toBe(true)
  })
})

// An inline payload written before a field existed must heal *as inline*. The
// walker picks an anyOf's object member by how much of the value it declares;
// picking the reference member instead would invent a reference with an empty
// key, which then decodes cleanly — corruption rather than an error.
@schema
type envelope = {
  f: @s.matches(Offload.optionSchema(~store="pluginStructures", demoSchema))
  option<Offload.payload<demo>>,
}

describe("Offload healing on replay:", () => {
  testSync("a legacy inline payload missing a later field heals as Inline", () => {
    let legacy = `{"f":{"name":"legacy"}}`->JSON.parseOrThrow
    let fills = []
    let healed = Message.fillMissingDefaults(envelopeSchema, legacy, fills)
    expect(healed->Util_Sury.fromJson(envelopeSchema))->toEqual({
      f: Some(Offload.Inline({name: "legacy", count: 0})),
    })
    expect(fills)->toEqual([".f.count := 0"])
  })

  testSync("an offloaded payload still heals as Offloaded", () => {
    let stored = `{"f":{"$offload":{"store":"s","key":"sha256/abc","hash":"abc","bytes":74000}}}`->JSON.parseOrThrow
    let healed = Message.fillMissingDefaults(envelopeSchema, stored, [])
    expect(healed->Util_Sury.fromJson(envelopeSchema))->toEqual({
      f: Some(Offload.Offloaded({store: "s", key: "sha256/abc", hash: "abc", bytes: 74000})),
    })
  })

  testSync("an absent field heals to None", () => {
    let healed = Message.fillMissingDefaults(envelopeSchema, `{}`->JSON.parseOrThrow, [])
    expect(healed->Util_Sury.fromJson(envelopeSchema))->toEqual({f: None})
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

describe("Offload threshold:", () => {
  testSync("getThreshold reads the per-field marker, None when unset", () => {
    let withT = Offload.optionSchema(~store="s", ~threshold=4096, demoSchema)->Offload.getThreshold
    let without = Offload.optionSchema(~store="s", demoSchema)->Offload.getThreshold
    expect(withT == Some(4096) && without == None)->toBe(true)
  })

  testSync("effectiveThreshold resolves the precedence chain", () => {
    let marked = Offload.optionSchema(~store="s", ~threshold=4096, demoSchema)
    let unmarked = Offload.optionSchema(~store="s", demoSchema)
    // (1) per-field marker wins even when a platform default is supplied
    let perField = Offload.effectiveThreshold(marked, ~platformDefault=100, ())
    // (2) platform default when the field left it unset
    let platform = Offload.effectiveThreshold(unmarked, ~platformDefault=100, ())
    // (3) framework default (8 KB) when neither is set
    let fallback = Offload.effectiveThreshold(unmarked, ())
    expect(perField == 4096 && platform == 100 && fallback == Offload.defaultThreshold)->toBe(true)
  })

  test("declaration -> effectiveThreshold -> prepare splits at the declared cut", async () => {
    // The end-to-end a client drives: read the field's cut off its schema, then
    // hand it to prepare. A tiny threshold forces the value to offload; a huge one
    // keeps the identical value inline.
    let objects = Dict.make()
    let upload = (~key, ~bytes) => {
      objects->Dict.set(key, bytes)
      Promise.resolve()
    }
    let hash = s => "H" ++ Int.toString(String.length(s))
    let value = {name: "abcdefghij", count: 1}

    let lowField = Offload.optionSchema(~store="s", ~threshold=1, demoSchema)
    let lowP = await Offload.prepare(
      value,
      ~schema=demoSchema,
      ~store="s",
      ~threshold=Offload.effectiveThreshold(lowField, ()),
      ~hash,
      ~upload,
    )

    let highField = Offload.optionSchema(~store="s", ~threshold=100000, demoSchema)
    let highP = await Offload.prepare(
      value,
      ~schema=demoSchema,
      ~store="s",
      ~threshold=Offload.effectiveThreshold(highField, ()),
      ~hash,
      ~upload,
    )

    let offloaded = switch lowP {
    | Offloaded(_) => true
    | Inline(_) => false
    }
    expect(offloaded && highP->Offload.getInline->Option.isSome)->toBe(true)
  })
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
