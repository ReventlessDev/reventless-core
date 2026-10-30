// An outbound work item that carries personal data is stored as an event is: its
// marked fields sealed, its row keyed by a fingerprint of the key `collect`
// chose, opened before it is translated, and completed without a call once its
// subject is erased.

open JestGlobals

let sent: ref<array<string>> = ref([])

module VerifySpec = {
  let name = "VerifyAddress"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type consumedEvent = AddressGiven({customerId: string, email: string})

  @schema
  type outboundItem = {
    customerId: string,
    email: @s.matches(Reventless.Pii.mark(~subject="customerId", S.string)) string,
  }

  @schema
  type inboundCommand = unit

  // Keyed by the address, as the shop's translations are: a change is new work.
  let collect = (event, ~sourceId as _) =>
    switch event {
    | AddressGiven({customerId, email}) => [(`${customerId}:${email}`, {customerId, email})]
    }

  let translate = async (_id, item: outboundItem, ~capabilities as _) => {
    sent := sent.contents->Array.concat([item.email])
    Ok(None)
  }
  let onExhausted = (_id, _item, ~lastError as _) => None

  let maxRetries = 3
  let targetName = None
  let sourceNames: array<string> = []
  let externalSystem = None
  let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
  let traits: array<Reventless.Trait.t> = []
}
module VerifyTranslation = {
  let collect = VerifySpec.collect
  let translate = VerifySpec.translate
  let onExhausted = VerifySpec.onExhausted
  let moduleUrl = VerifySpec.moduleUrl
}
module Callback = ReventlessCore.OutboundTranslationSlice_Callback.Make(
  VerifySpec,
  VerifyTranslation,
)

let toBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "utf8")->NodeCrypto.bufferToString("base64")
let fromBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "base64")->NodeCrypto.bufferToString("utf8")

/** "Encrypts" by base64; `erased` makes every key gone, as an erasure does. */
let erased = ref(false)
let provider: Reventless.Pii.provider = {
  name: "fake",
  encrypts: true,
  seal: async (~subject, ~field as _, ~forgettable as _, json) => Ok(
    Reventless.Pii.wrap(`enc:v1:${subject}:fake:${json->JSON.stringify->toBase64}`),
  ),
  prefetch: async _ => Ok(),
  openNow: (~field, json) =>
    switch json->Reventless.Pii.unwrap->Option.flatMap(Reventless.Pii.parseStored) {
    | Some(Cipher(_)) if erased.contents => Ok(Reventless.Pii.wrap(Reventless.Pii.erasedMarker))
    | Some(Cipher({bytes})) => Ok(bytes->fromBase64->JSON.parseOrThrow)
    | _ => Error(Reventless.Pii.UnknownForm({field: field}))
    },
  release: async (~subject as _, ~ref as _) => Ok(),
}

let keyed: Reventless.Capabilities.t = {
  ...Reventless.Capabilities.none,
  secrets: Reventless.Secrets.fixed(
    ~token="t",
    ~hash=s => s,
    ~fingerprint=(~purpose, input) =>
      `fp(${purpose})#${input->toBase64->String.length->Int.toString}`,
  ),
}

let given = VerifySpec.AddressGiven({customerId: "c-1", email: "ada@example.org"})
let rows = () => Callback.todoItems->Dict.toArray
let publish: ReventlessInfra.CommandTopic.publishJsons = async _ => ()

@val external env: dict<string> = "process.env"

describe("an outbound work item with personal data", () => {
  beforeEach(() => {
    Callback.todoItems->Dict.keysToArray->Array.forEach(k => Callback.todoItems->Dict.delete(k))
    sent := []
    erased := false
    Reventless.Pii.Provider.install(provider)
  })
  afterEach(() => {
    Reventless.Pii.Provider.install(Reventless.Pii.plain)
    env->Dict.delete("REVENTLESS_PII_REQUIRE_ENCRYPTION")
  })

  testPromise("is stored sealed, under a key that holds no address", async () => {
    await Callback.phase1([("c-1", given)], ~capabilities=keyed)
    let stored = rows()->JSON.stringifyAny->Option.getOr("")
    expect(stored->String.includes("ada@example.org"))->toBe(false)
    switch rows() {
    | [(id, row)] =>
      expect(id->String.startsWith("fp(outboundWorkItem:VerifyAddress)"))->toBe(true)
      // A sealed string stays a string, so the work list still serves it as one.
      let email = row.item->JSON.Decode.object->Option.flatMap(d => d->Dict.get("email"))
      expect(
        email
        ->Option.flatMap(JSON.Decode.string)
        ->Option.mapOr(false, s => s->String.startsWith("enc:v1:c-1:")),
      )->toBe(true)
    | _ => fail("expected one row")
    }
  })

  testPromise("is collected once, however often its event arrives", async () => {
    await Callback.phase1([("c-1", given)], ~capabilities=keyed)
    await Callback.phase1([("c-1", given)], ~capabilities=keyed)
    expect(rows()->Array.length)->toBe(1)
  })

  testPromise("is opened before it is translated", async () => {
    await Callback.phase1([("c-1", given)], ~capabilities=keyed)
    await Callback.phase2(publish, ~capabilities=keyed)
    expect(sent.contents)->toEqual(["ada@example.org"])
  })

  testPromise("is completed without a call once its subject is erased", async () => {
    await Callback.phase1([("c-1", given)], ~capabilities=keyed)
    erased := true
    await Callback.phase2(publish, ~capabilities=keyed)
    expect(sent.contents)->toEqual([])
    expect(rows()->Array.map(((_, row)) => row.status))->toEqual([
      ReventlessCore.OutboundTranslationSlice_Callback.Completed,
    ])
  })

  testPromise("keeps the key it was given where nothing can fingerprint it", async () => {
    await Callback.phase1([("c-1", given)], ~capabilities=Reventless.Capabilities.none)
    expect(rows()->Array.map(Pair.first))->toEqual(["c-1:ada@example.org"])
  })

  testPromise(
    "is not stored at all where encryption is required and nothing can fingerprint it",
    async () => {
      env->Dict.set("REVENTLESS_PII_REQUIRE_ENCRYPTION", "true")
      await Callback.phase1([("c-1", given)], ~capabilities=Reventless.Capabilities.none)
      expect(rows())->toEqual([])
    },
  )
})
