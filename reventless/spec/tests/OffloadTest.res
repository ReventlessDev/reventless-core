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
