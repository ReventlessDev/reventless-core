// A provider installed while it is still being built is waited for, a failed one
// refuses, and a deployment that requires encryption never stores a marked field
// as it is.

open JestGlobals

module Spec = {
  @schema
  type event =
    | MemberNamed({
        memberId: string,
        name: @s.matches(Reventless.Pii.marked(~subject="memberId", S.string))
        Reventless.Pii.t<string>,
      })
    | MemberLeft({memberId: string})
}

let sealing: Reventless.Pii.provider = {
  ...Reventless.Pii.plain,
  name: "sealing",
  encrypts: true,
  seal: async (~subject, ~field as _, ~forgettable as _, _json) => Ok(
    Reventless.Pii.wrap(`enc:v1:${subject}:fake:AAAA`),
  ),
}

let named = () =>
  Dict.fromArray([("memberId", JSON.Encode.string("m-1")), ("name", JSON.Encode.string("Ada"))])

let seal = data => Reventless.Pii.sealData(Spec.eventSchema, ~eventType="MemberNamed", data)

@val external env: dict<string> = "process.env"
let variable = "REVENTLESS_PII_REQUIRE_ENCRYPTION"

describe("Pii.Provider.installWhen", () => {
  afterEach(() => {
    Reventless.Pii.Provider.install(Reventless.Pii.plain)
    env->Dict.delete(variable)
  })

  test("a write waits for a provider still being built, then seals with it", async () => {
    let (building, finish) = {
      let finish = ref(_ => ())
      let p = Promise.make((resolve, _) => finish := resolve)
      (p, finish)
    }
    Reventless.Pii.Provider.installWhen(building)
    let sealed = seal(named())
    finish.contents(Ok(sealing))
    switch await sealed {
    | Ok(data) =>
      expect(data->Dict.get("name")->Option.flatMap(Reventless.Pii.unwrap))->toEqual(
        Some("enc:v1:m-1:fake:AAAA"),
      )
    | Error(e) => JsError.throwWithMessage(e->Reventless.Pii.errorMessage)
    }
  })

  test("a failed install refuses the write with its reason", async () => {
    Reventless.Pii.Provider.installWhen(Promise.resolve(Error("KMS is unreachable")))
    switch await seal(named()) {
    | Ok(_) => JsError.throwWithMessage("expected a refusal")
    | Error(e) =>
      expect(e->Reventless.Pii.errorMessage->String.includes("KMS is unreachable"))->toBe(true)
    }
  })

  test("a failed install refuses a batch that needs keys", async () => {
    Reventless.Pii.Provider.installWhen(Promise.resolve(Error("KMS is unreachable")))
    let batch = [Reventless.Pii.wrap("enc:v1:k-1:A256GCM:AAAA")]
    expect((await Reventless.Pii.prepare(batch))->Result.isError)->toBe(true)
  })

  test("a later install replaces one still in flight", async () => {
    let (building, finish) = {
      let finish = ref(_ => ())
      let p = Promise.make((resolve, _) => finish := resolve)
      (p, finish)
    }
    Reventless.Pii.Provider.installWhen(building)
    Reventless.Pii.Provider.install(sealing)
    finish.contents(Error("too late"))
    await Promise.resolve()
    expect((await seal(named()))->Result.isOk)->toBe(true)
    expect(Reventless.Pii.Provider.get().name)->toBe("sealing")
  })

  test("a type without personal fields does not wait", async () => {
    Reventless.Pii.Provider.installWhen(Promise.make((_, _) => ()))
    let data = Dict.fromArray([("memberId", JSON.Encode.string("m-1"))])
    expect(await Reventless.Pii.sealData(Spec.eventSchema, ~eventType="MemberLeft", data))->toEqual(
      Ok(data),
    )
  })
})

describe("REVENTLESS_PII_REQUIRE_ENCRYPTION", () => {
  afterEach(() => {
    Reventless.Pii.Provider.install(Reventless.Pii.plain)
    env->Dict.delete(variable)
  })

  test("refuses a marked field when no encrypting provider is installed", async () => {
    env->Dict.set(variable, "true")
    switch await seal(named()) {
    | Ok(_) => JsError.throwWithMessage("expected a refusal")
    | Error(e) =>
      expect(e->Reventless.Pii.errorMessage->String.includes("requires an encrypting"))->toBe(true)
    }
  })

  test("seals when an encrypting provider is installed", async () => {
    env->Dict.set(variable, "true")
    Reventless.Pii.Provider.install(sealing)
    expect((await seal(named()))->Result.isOk)->toBe(true)
  })

  test("leaves a deployment that does not require it storing as it is", async () => {
    expect(await seal(named()))->toEqual(Ok(named()))
  })
})
