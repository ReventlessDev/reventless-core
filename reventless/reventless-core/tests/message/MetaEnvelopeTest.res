// Regression tests for the post-Plan envelope:
// - Message.meta optional fields (ip/user absent by default; causationId,
//   traceparent, schemaVersion, headers round-trip when set)
// - Message.deriveMeta semantics (causation propagation)
// - StoredEvent encode/decode round-trip + the flat-dict bridge
// - generateMeta omits ip/user when not supplied (no `""`/`"unknown"` sentinels)
//
// `open Jest; open Expect` returns `Jest.assertion` from each `->toBe`/`->toEqual`,
// so intermediate assertions are piped to `->ignore`; the trailing one supplies
// the implicit `unit` return of the test body.

open Jest
open Expect
open Message

describe("Message.meta optional fields:", () => {
  test("generateMeta() with no ~ip/~user omits those keys from JSON", () => {
    let meta = generateMeta(~service="svc")
    let json = meta->Reventless.Util_Sury.toJson(metaSchema)
    let obj = json->JSON.Decode.object->Option.getOrThrow
    expect(obj->Dict.get("ip"))->toEqual(None)->ignore
    expect(obj->Dict.get("user"))->toEqual(None)->ignore
    expect(obj->Dict.get("causationId"))->toEqual(None)->ignore
    expect(obj->Dict.get("traceparent"))->toEqual(None)->ignore
    expect(obj->Dict.get("schemaVersion"))->toEqual(None)->ignore
    expect(obj->Dict.get("headers"))->toEqual(None)->ignore
    // Required keys are present:
    expect(obj->Dict.get("service")->Option.isSome)->toBe(true)->ignore
    expect(obj->Dict.get("time")->Option.isSome)->toBe(true)->ignore
    expect(obj->Dict.get("msgId")->Option.isSome)->toBe(true)->ignore
    expect(obj->Dict.get("correlationId")->Option.isSome)->toBe(true)
  })

  test("generateMeta() correlationId defaults to msgId", () => {
    let meta = generateMeta(~service="svc")
    expect(meta.correlationId)->toBe(meta.msgId)
  })

  test("generateMeta(~user=alice) round-trips Some(alice)", () => {
    let meta = generateMeta(~service="svc", ~user="alice")
    let json = meta->Reventless.Util_Sury.toJson(metaSchema)
    let decoded = json->Reventless.Util_Sury.fromJson(metaSchema)
    expect(decoded.user)->toEqual(Some("alice"))
  })

  test("all new optional fields round-trip when set", () => {
    let headers = Dict.fromArray([("tenantId", "t1"), ("feature.x", "on")])
    let meta = generateMeta(
      ~service="svc",
      ~ip="10.0.0.1",
      ~user="bob",
      ~causationId="parent-msg-id",
      ~traceparent="00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
      ~correlationId="root-msg-id",
      ~schemaVersion="1.2.0",
      ~headers,
    )
    let json = meta->Reventless.Util_Sury.toJson(metaSchema)
    let decoded = json->Reventless.Util_Sury.fromJson(metaSchema)
    expect(decoded.ip)->toEqual(Some("10.0.0.1"))->ignore
    expect(decoded.user)->toEqual(Some("bob"))->ignore
    expect(decoded.causationId)->toEqual(Some("parent-msg-id"))->ignore
    expect(decoded.traceparent)
    ->toEqual(Some("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"))
    ->ignore
    expect(decoded.correlationId)->toBe("root-msg-id")->ignore
    expect(decoded.schemaVersion)->toEqual(Some("1.2.0"))->ignore
    expect(
      decoded.headers
      ->Option.getOr(Dict.make())
      ->Dict.get("tenantId"),
    )->toEqual(Some("t1"))
  })
})

describe("Message.deriveMeta:", () => {
  test("emits a new msgId distinct from the parent", () => {
    let parent = generateMeta(~service="svc")
    let child = deriveMeta(~parent)
    expect(child.msgId == parent.msgId)->toBe(false)
  })

  test("sets causationId = parent.msgId", () => {
    let parent = generateMeta(~service="svc")
    let child = deriveMeta(~parent)
    expect(child.causationId)->toEqual(Some(parent.msgId))
  })

  test("inherits correlationId (chain-root id stays stable)", () => {
    let root = generateMeta(~service="svc") // correlationId = msgId here
    let mid = deriveMeta(~parent=root)
    let leaf = deriveMeta(~parent=mid)
    expect(mid.correlationId)->toBe(root.correlationId)->ignore
    expect(leaf.correlationId)->toBe(root.correlationId)->ignore
    // causation chain is one hop, not the root
    expect(leaf.causationId)->toEqual(Some(mid.msgId))
  })

  test("inherits ip/user/traceparent/schemaVersion/headers from parent", () => {
    let parent = generateMeta(
      ~service="svc",
      ~ip="10.0.0.1",
      ~user="alice",
      ~traceparent="tp",
      ~schemaVersion="1",
      ~headers=Dict.fromArray([("k", "v")]),
    )
    let child = deriveMeta(~parent)
    expect(child.ip)->toEqual(Some("10.0.0.1"))->ignore
    expect(child.user)->toEqual(Some("alice"))->ignore
    expect(child.traceparent)->toEqual(Some("tp"))->ignore
    expect(child.schemaVersion)->toEqual(Some("1"))->ignore
    expect(child.headers->Option.getOr(Dict.make())->Dict.get("k"))->toEqual(Some("v"))
  })

  test("~service overrides parent's service; defaults to parent's service", () => {
    let parent = generateMeta(~service="parent-svc")
    let inherited = deriveMeta(~parent)
    let overridden = deriveMeta(~parent, ~service="child-svc")
    expect(inherited.service)->toBe("parent-svc")->ignore
    expect(overridden.service)->toBe("child-svc")
  })
})

describe("StoredEvent encode/decode round-trip:", () => {
  test("aggregate-style record (no tags) round-trips through the flat-dict bridge", () => {
    let meta = generateMeta(~service="catalog")
    let stored: Reventless.StoredEvent.storedEvent<string> = {
      id: "agg-1",
      position: "000000001",
      event: "ItemCreated",
      data: JSON.Object(
        Dict.fromArray([
          ("itemId", JSON.String("agg-1")),
          ("name", JSON.String("Widget")),
        ]),
      ),
      meta,
      recordedAt: "2026-05-13T10:00:00.000Z",
    }
    let flat = stored->storedEventToFlatJson(S.string)
    let roundTrip = flat->flatJsonToStoredEvent(S.string)
    expect(roundTrip.id)->toBe("agg-1")->ignore
    expect(roundTrip.position)->toBe("000000001")->ignore
    expect(roundTrip.event)->toBe("ItemCreated")->ignore
    expect(roundTrip.recordedAt)->toBe("2026-05-13T10:00:00.000Z")->ignore
    expect(roundTrip.meta.msgId)->toBe(meta.msgId)->ignore
    expect(roundTrip.meta.correlationId)->toBe(meta.correlationId)->ignore
    expect(roundTrip.tags)->toEqual(None)
  })

  test("DCB-style record (with tags) round-trips and preserves the tag list", () => {
    let meta = generateMeta(~service="catalog", ~causationId="cmd-1")
    let stored: Reventless.StoredEvent.storedEvent<string> = {
      id: "productId:p-1",
      position: "1736782800000-abc-uuid",
      event: "ProductAdded",
      data: JSON.Object(Dict.fromArray([("productId", JSON.String("p-1"))])),
      meta,
      recordedAt: "2026-05-13T10:00:00.000Z",
      tags: [
        {key: "productId", value: "p-1"},
        {key: "categoryId", value: "c-1"},
      ],
    }
    let flat = stored->storedEventToFlatJson(S.string)
    let roundTrip = flat->flatJsonToStoredEvent(S.string)
    expect(roundTrip.id)->toBe("productId:p-1")->ignore
    expect(roundTrip.position)->toBe("1736782800000-abc-uuid")->ignore
    expect(roundTrip.event)->toBe("ProductAdded")->ignore
    expect(roundTrip.meta.causationId)->toEqual(Some("cmd-1"))->ignore
    let tags = roundTrip.tags->Option.getOrThrow
    expect(tags->Array.length)->toBe(2)->ignore
    let first = tags->Array.getUnsafe(0)
    expect(first.key)->toBe("productId")->ignore
    expect(first.value)->toBe("p-1")
  })

  test("meta is flattened to top-level keys in the on-disk JSON (DynamoDB GSI projectability)", () => {
    let meta = generateMeta(~service="catalog")
    let stored: Reventless.StoredEvent.storedEvent<string> = {
      id: "agg-1",
      position: "000000001",
      event: "ItemCreated",
      data: JSON.Object(Dict.make()),
      meta,
      recordedAt: "2026-05-13T10:00:00.000Z",
    }
    let flat = stored->storedEventToFlatJson(S.string)
    let obj = flat->JSON.Decode.object->Option.getOrThrow
    // meta.* should be top-level (not nested under "meta")
    expect(obj->Dict.get("meta"))->toEqual(None)->ignore
    expect(obj->Dict.get("service"))->toEqual(Some(JSON.String("catalog")))->ignore
    expect(obj->Dict.get("msgId")->Option.isSome)->toBe(true)->ignore
    // envelope fields are also top-level
    expect(obj->Dict.get("position"))->toEqual(Some(JSON.String("000000001")))->ignore
    expect(obj->Dict.get("event"))->toEqual(Some(JSON.String("ItemCreated")))->ignore
    expect(obj->Dict.get("recordedAt"))
    ->toEqual(Some(JSON.String("2026-05-13T10:00:00.000Z")))
  })
})
