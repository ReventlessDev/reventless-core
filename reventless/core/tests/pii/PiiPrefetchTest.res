// The decoders open sealed fields with the keys a batch prepared, and fail rather
// than drop an event whose key is not at hand.

open JestGlobals

module Spec = {
  @schema
  type event =
    | MemberNamed({
        memberId: string,
        name: @s.matches(Reventless.Pii.marked(~subject="memberId", S.string))
        Reventless.Pii.t<string>,
      })
}

let toBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "utf8")->NodeCrypto.bufferToString("base64")
let fromBase64 = (s: string) =>
  NodeCrypto.bufferFromString(s, "base64")->NodeCrypto.bufferToString("utf8")

// Opens only what a prefetch made available, as a key store with a cache would.
let fetched: ref<array<string>> = ref([])
let asked: ref<array<array<string>>> = ref([])
let provider: Reventless.Pii.provider = {
  name: "prefetching",
  encrypts: true,
  seal: async (~subject, ~field as _, ~forgettable as _, json) => Ok(
    Reventless.Pii.wrap(`enc:v1:${subject}:fake:${json->JSON.stringify->toBase64}`),
  ),
  prefetch: async keyIds => {
    asked := asked.contents->Array.concat([keyIds])
    fetched := fetched.contents->Array.concat(keyIds)
    Ok()
  },
  openNow: (~field, json) =>
    switch json->Reventless.Pii.unwrap->Option.flatMap(Reventless.Pii.parseStored) {
    | Some(Cipher({keyId, bytes})) =>
      fetched.contents->Array.includes(keyId)
        ? Ok(bytes->fromBase64->JSON.parseOrThrow)
        : Error(Reventless.Pii.KeyUnavailable({subject: keyId}))
    | _ => Error(Reventless.Pii.UnknownForm({field: field}))
    },
  release: async (~subject as _, ~ref as _) => Ok(),
}

let sealedData = () =>
  Dict.fromArray([
    ("memberId", JSON.Encode.string("m-1")),
    ("name", Reventless.Pii.wrap(`enc:v1:m-1:fake:${"\"Ada\""->toBase64}`)),
  ])

let envelope = () =>
  Dict.fromArray([
    ("id", JSON.Encode.string("m-1")),
    (
      "meta",
      Message.generateMeta(~service="Members")->Reventless.Util_Sury.toJson(Message.metaSchema),
    ),
    (
      "event",
      {
        let d = sealedData()
        d->Dict.set("TAG", JSON.Encode.string("MemberNamed"))
        JSON.Object(d)
      },
    ),
  ])->JSON.Encode.object

let threw = f =>
  switch f() {
  | _ => false
  | exception _ => true
  }

describe("decoding sealed fields with prepared keys", () => {
  beforeEach(() => {
    fetched := []
    asked := []
    Reventless.Pii.Provider.install(provider)
  })
  afterEach(() => Reventless.Pii.Provider.install(Reventless.Pii.plain))

  let decoder = Reventless.DcbDecode.makeDecoder(Spec.eventSchema)

  testSync("an unprepared key fails the read, it does not drop the event", () =>
    expect(threw(() => decoder.decode(~eventType="MemberNamed", ~data=sealedData())))->toBe(true)
  )

  testPromise("after prepare the DCB decoder reads the value", async () => {
    await Reventless.Pii.prepareOrThrow([JSON.Object(sealedData())])
    expect(decoder.decode(~eventType="MemberNamed", ~data=sealedData()))->toEqual(
      Some(Spec.MemberNamed({memberId: "m-1", name: Value("Ada")})),
    )
  })

  testPromise("after prepare an envelope decodes through decodeEvent'", async () => {
    expect(
      threw(
        () => envelope()->Message.decodeEvent'(Reventless.Id.StringPure.schema, Spec.eventSchema),
      ),
    )->toBe(true)
    await Reventless.Pii.prepareOrThrow([envelope()])
    let decoded =
      envelope()->Message.decodeEvent'(Reventless.Id.StringPure.schema, Spec.eventSchema)
    expect(decoded.event)->toEqual(Spec.MemberNamed({memberId: "m-1", name: Value("Ada")}))
  })

  testPromise(
    "prepare asks for the keys a batch names, once each, and nothing for none",
    async () => {
      await Reventless.Pii.prepareOrThrow([envelope(), envelope()])
      await Reventless.Pii.prepareOrThrow([JSON.Encode.string("nothing sealed")])
      expect(asked.contents)->toEqual([["m-1"]])
    },
  )
})
