open JestGlobals

// What a log line may print of a payload: nothing a schema marks as personal or
// sensitive, at any depth, and no sealed value at all.

module Spec = {
  @schema
  type event =
    | PersonJoined({
        personId: string,
        name: @s.matches(Pii.marked(~subject="personId", S.string)) Pii.t<string>,
        token: @s.matches(Sensitive.string) string,
        contact: Email.t,
        city: string,
      })
    | Unrelated({city: string})
}

let joined: Spec.event = PersonJoined({
  personId: "p-1",
  name: Value("Ada Lovelace"),
  token: "t-secret",
  contact: Email.unsafe("ada@example.com"),
  city: "London",
})

describe("LogRedaction", () => {
  testSync("a payload that went through its schema prints no personal value", () => {
    let printed =
      joined->Util_Sury.toJson(Spec.eventSchema)->LogRedaction.redactJson->JSON.stringify
    expect(printed->String.includes("Ada"))->toBe(false)
    expect(printed->String.includes("t-secret"))->toBe(false)
    // An email is a way of reaching a person whether or not anybody marked it.
    expect(printed->String.includes("ada@example.com"))->toBe(false)
    expect(printed->String.includes("London"))->toBe(true)
    expect(printed->String.includes(LogRedaction.placeholder))->toBe(true)
  })

  testSync("a variant without marked fields prints in full", () => {
    let printed =
      Spec.Unrelated({city: "Paris"})
      ->Util_Sury.toJson(Spec.eventSchema)
      ->LogRedaction.redactJson
      ->JSON.stringify
    expect(printed->String.includes("Paris"))->toBe(true)
  })

  testSync("nested in an envelope, it is still withheld", () => {
    let envelope =
      Dict.fromArray([
        ("id", JSON.Encode.string("p-1")),
        ("event", joined->Util_Sury.toJson(Spec.eventSchema)),
      ])->JSON.Encode.object
    expect(envelope->LogRedaction.redactJson->JSON.stringify->String.includes("Ada"))->toBe(false)
  })

  testSync("a sealed value is withheld whatever registered", () => {
    let json = Dict.fromArray([("x", Pii.wrap("enc:v1:k:a:b"))])->JSON.Encode.object
    expect(json->LogRedaction.redactJson->JSON.stringify->String.includes("enc:"))->toBe(false)
  })

  testSync("forLog prints a value through its schema", () =>
    expect(LogRedaction.forLog(joined, Spec.eventSchema)->String.includes("Ada"))->toBe(false)
  )

  testSync("a decode error names no received value", () => {
    let message = try {
      let _ = JSON.Encode.string("Ada Lovelace")->Util_Sury.fromJson(S.int)
      ""
    } catch {
    | exn => exn->Util_Sury.exnMessage
    }
    expect(message->String.includes("Ada"))->toBe(false)
    expect(message != "")->toBe(true)
  })
})
