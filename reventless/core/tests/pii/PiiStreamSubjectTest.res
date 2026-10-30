// In an aggregate's spec a `@pii` field that names no subject is about the
// aggregate: the PPX marks it with the stream subject, and the seal pass seals it
// under the stream id the event log passes.

open JestGlobals

module C = PiiCustomer

let subjects = variant =>
  C.eventSchema
  ->S.castToUnknown
  ->Reventless.Pii.variantFields(~variant)
  ->Array.map(((name, m)) => (name, m.subject))

let sealedUnder: ref<array<string>> = ref([])
let recording: Reventless.Pii.provider = {
  ...Reventless.Pii.plain,
  name: "recording",
  encrypts: true,
  seal: async (~subject, ~field as _, ~forgettable as _, _json) => {
    sealedUnder := sealedUnder.contents->Array.concat([subject])
    Ok(Reventless.Pii.wrap(`enc:v1:${subject}:fake:AAAA`))
  },
}

let registered = () =>
  Dict.fromArray([
    ("email", JSON.Encode.string("ada@example.org")),
    ("address", JSON.Encode.string("1 Analytical St")),
  ])

describe("@pii in an aggregate's spec", () => {
  afterEach(() => {
    Reventless.Pii.Provider.install(Reventless.Pii.plain)
    sealedUnder := []
  })

  testSync("a field naming no subject is about the aggregate", () =>
    expect(subjects("Registered"))->toEqual([
      ("email", Reventless.Pii.streamSubject),
      ("address", Reventless.Pii.streamSubject),
    ])
  )

  testSync("a field naming a subject keeps it", () =>
    expect(subjects("ReferralSent"))->toEqual([("friendEmail", "friendId")])
  )

  testPromise("is sealed under the stream id the event log passes", async () => {
    Reventless.Pii.Provider.install(recording)
    let sealed = await Reventless.Pii.sealData(
      C.eventSchema,
      ~eventType="Registered",
      ~streamId="c-7",
      registered(),
    )
    expect(sealed->Result.isOk)->toBe(true)
    expect(sealedUnder.contents)->toEqual(["c-7", "c-7"])
  })

  testPromise("is refused when no stream id is passed", async () => {
    Reventless.Pii.Provider.install(recording)
    switch await Reventless.Pii.sealData(C.eventSchema, ~eventType="Registered", registered()) {
    | Ok(_) => fail("expected a refusal")
    | Error(e) =>
      expect(e->Reventless.Pii.errorMessage->String.includes("no stream id"))->toBe(true)
    }
  })
})
