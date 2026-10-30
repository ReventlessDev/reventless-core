// The event log seals a personal field once, stores and publishes that one form,
// opens it on replay, and refuses an append whose field comes out unsealed.

open JestGlobals
open EventLogFixtures

module TestOps: EventLog_Operations.Ops with module Spec = ItemEventLogSpec = {
  module Spec = ItemEventLogSpec
  module EventTopic = MockEventTopic
  let eventTopic = mockEventTopicOps
  let storage = mockStorage
}

module Log = EventLog_Operations.Make(ItemEventLogSpec, TestOps)

let toBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "utf8")->NodeCrypto.bufferToString("base64")
let fromBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "base64")->NodeCrypto.bufferToString("utf8")

/** A provider that "encrypts" by base64: enough to see the form, the subject and
    the round trip, with nothing to fetch. */
let fakeProvider = (~seals=true): Reventless.Pii.provider => {
  name: "fake",
  encrypts: true,
  seal: async (~subject, ~field as _, ~forgettable as _, json) =>
    seals
      ? Ok(Reventless.Pii.wrap(`enc:v1:${subject}:fake:${json->JSON.stringify->toBase64}`))
      : Ok(json),
  prefetch: async _ => Ok(),
  openNow: (~field, json) =>
    switch json->Reventless.Pii.unwrap->Option.flatMap(Reventless.Pii.parseStored) {
    | Some(Cipher({bytes})) => Ok(bytes->fromBase64->JSON.parseOrThrow)
    | _ => Error(Reventless.Pii.UnknownForm({field: field}))
    },
  release: async (~subject as _, ~ref as _) => Ok(),
}

let named: ItemEventLogSpec.event = PersonNamed({personId: "p-1", name: Value("Ada Lovelace")})

let storedName = id =>
  storedEvents.contents
  ->Dict.get(id)
  ->Option.flatMap(a => a->Array.get(0))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("data"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("name"))

let publishedName = () =>
  capturedPublishes.contents
  ->Array.get(0)
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("event"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("name"))

describe("EventLog with a personal-data provider", () => {
  beforeEach(() => reset())
  afterEach(() => Reventless.Pii.Provider.install(Reventless.Pii.plain))

  testPromise("stores and publishes one sealed form, and replays the value", async () => {
    Reventless.Pii.Provider.install(fakeProvider())
    let result = await Log.append(0, "p-1", [makeEvent'("p-1", named)])
    expect(result)->toEqual(Ok())
    let stored = storedName("p-1")
    expect(stored->Option.flatMap(Reventless.Pii.unwrap)->Option.isSome)->toBe(true)
    expect(
      stored->Option.map(j => j->JSON.stringify)->Option.getOr("")->String.includes("Ada"),
    )->toBe(false)
    expect(publishedName())->toEqual(stored)
    let replayed = await Log.replay("p-1")
    expect(replayed)->toEqual([named])
  })

  testPromise("seals a field that names no subject under the aggregate's id", async () => {
    Reventless.Pii.Provider.install(fakeProvider())
    let emailed: ItemEventLogSpec.event = PersonEmailed({email: Value("ada@example.org")})
    let result = await Log.append(0, "p-9", [makeEvent'("p-9", emailed)])
    expect(result)->toEqual(Ok())
    let stored =
      storedEvents.contents
      ->Dict.get("p-9")
      ->Option.flatMap(a => a->Array.get(0))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(d => d->Dict.get("data"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(d => d->Dict.get("email"))
      ->Option.flatMap(Reventless.Pii.unwrap)
    expect(stored->Option.mapOr(false, s => s->String.startsWith("enc:v1:p-9:")))->toBe(true)
    expect(await Log.replay("p-9"))->toEqual([emailed])
  })

  testPromise("refuses an append whose personal field comes out unsealed", async () => {
    Reventless.Pii.Provider.install(fakeProvider(~seals=false))
    let result = await Log.append(0, "p-1", [makeEvent'("p-1", named)])
    switch result {
    | Error(EventLog.StorageFailure(msg)) =>
      expect(msg->String.includes("name is not sealed"))->toBe(true)
      expect(msg->String.includes("Ada"))->toBe(false)
    | _ => fail("expected a refusal")
    }
    expect(storedEvents.contents->Dict.get("p-1"))->toEqual(None)
    expect(capturedPublishes.contents)->toEqual([])
  })

  testPromise("with the plain provider the value is stored as it is", async () => {
    let _ = await Log.append(0, "p-1", [makeEvent'("p-1", named)])
    expect(storedName("p-1"))->toEqual(Some(JSON.Encode.string("Ada Lovelace")))
    expect(await Log.replay("p-1"))->toEqual([named])
  })

  testPromise("a value whose key is gone replays as Erased", async () => {
    let _ = await Log.append(0, "p-1", [makeEvent'("p-1", named)])
    // A masking sweep or a provider left the erased form in place of the value.
    let item = storedEvents.contents->Dict.get("p-1")->Option.getOrThrow->Array.getUnsafe(0)
    switch item {
    | Object(d) =>
      d->Dict.set(
        "data",
        Dict.fromArray([
          ("personId", JSON.Encode.string("p-1")),
          ("name", Reventless.Pii.wrap("erased:v1")),
        ])->JSON.Encode.object,
      )
    | _ => ()
    }
    expect(await Log.replay("p-1"))->toEqual([
      ItemEventLogSpec.PersonNamed({personId: "p-1", name: Erased}),
    ])
  })
})
