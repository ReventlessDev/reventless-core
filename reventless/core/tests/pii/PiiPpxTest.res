// `@pii` as the PPX expands it: on an event the field reads `Pii.t`, and on a
// command it keeps its type; on both the schema carries the marker and
// `@sensitive`, and the JSON schema lists it.

open JestGlobals

module M = PiiMember

let encode = e => e->Reventless.Util_Sury.toJson(M.eventSchema)
let decode = json => json->Reventless.Util_Sury.fromJson(M.eventSchema)

let joined: M.event = MemberJoined({
  memberId: "m-1",
  name: Value("Ada"),
  bio: Value("mathematician"),
  nickname: None,
  address: Value(Reventless.Email.unsafe("ada@example.com")),
  photo: Value("/photos/m-1/0b1c.jpg"),
})

describe("@pii on an event", () => {
  testSync("a value is stored as the plain value with no provider, and reads back", () => {
    let json = encode(joined)
    expect(json->JSON.stringify->String.includes("\"Ada\""))->toBe(true)
    expect(decode(json))->toEqual(joined)
  })

  testSync("an erased value reads Erased, not a string", () => {
    let erased: M.event = MemberJoined({
      memberId: "m-1",
      name: Erased,
      nickname: None,
      address: Erased,
      photo: Forgotten,
    })
    expect(decode(encode(erased)))->toEqual(erased)
  })

  testSync("the marker names the subject, defaulting to the @owner field", () => {
    let fields =
      M.eventSchema->S.castToUnknown->Reventless.Pii.variantFields(~variant="MemberJoined")
    expect(fields->Array.map(((name, m)) => (name, m.subject, m.forgettable)))->toEqual([
      ("name", "memberId", false),
      ("bio", "memberId", false),
      ("nickname", "memberId", false),
      ("address", "memberId", false),
      ("photo", "memberId", true),
    ])
    let invited =
      M.eventSchema->S.castToUnknown->Reventless.Pii.variantFields(~variant="InvitationSent")
    expect(invited->Array.map(((name, m)) => (name, m.subject)))->toEqual([
      ("invitee", "invitationId"),
    ])
  })

  testSync("@pii implies @sensitive", () =>
    expect(
      M.eventSchema
      ->S.castToUnknown
      ->Reventless.Sensitive.variantFieldNames(~variant="MemberJoined")
      ->Array.includes("name"),
    )->toBe(true)
  )
})

describe("@pii on a command", () => {
  testSync("keeps the plain type and carries the marker", () => {
    let join: M.command = Join({
      memberId: "m-1",
      name: "Ada",
      address: Reventless.Email.unsafe("ada@example.com"),
    })
    let back =
      join
      ->Reventless.Util_Sury.toJson(M.commandSchema)
      ->Reventless.Util_Sury.fromJson(M.commandSchema)
    expect(back)->toEqual(join)
    let fields = M.commandSchema->S.castToUnknown->Reventless.Pii.variantFields(~variant="Join")
    expect(fields->Array.map(((name, _)) => name))->toEqual(["name", "address"])
  })
})

describe("the JSON schema", () => {
  testSync("lists the marker on the field", () => {
    let fields =
      M.eventSchema
      ->S.castToUnknown
      ->Reventless.Semantic.unionVariant(~variant="MemberJoined")
      ->Option.getOrThrow
    let json = SuryToJsonSchema.deriveObjectSchema(fields)->JSON.stringify
    expect(
      json->String.includes(
        "\"x-reventless-pii\":{\"subject\":\"memberId\",\"forgettable\":false}",
      ),
    )->toBe(true)
  })
})

describe("a log line of a @pii event or command", () => {
  testSync("holds no personal value, whichever formatter prints it", () => {
    let eventJson = encode(joined)
    let envelope =
      Dict.fromArray([
        ("id", JSON.Encode.string("m-1")),
        ("meta", Dict.fromArray([("ip", JSON.Encode.string("10.0.0.1"))])->JSON.Encode.object),
        ("event", eventJson),
      ])->JSON.Encode.object
    let lines = [LogFormat.eventDetail(envelope), LogFormat.eventFull(envelope)]
    lines->Array.forEach(
      line => {
        expect(line->String.includes("Ada"))->toBe(false)
        expect(line->String.includes("ada@example.com"))->toBe(false)
        expect(line->String.includes("mathematician"))->toBe(false)
        expect(line->String.includes("10.0.0.1"))->toBe(false)
        expect(line->String.includes("m-1"))->toBe(true)
      },
    )
    let join: M.command = Join({
      memberId: "m-1",
      name: "Ada",
      address: Reventless.Email.unsafe("ada@example.com"),
    })
    let commandJson = join->Reventless.Util_Sury.toJson(M.commandSchema)
    let label = LogFormat.cmdLabelOfJson(commandJson)
    expect(label->String.includes("Ada"))->toBe(false)
    expect(label->String.includes("m-1"))->toBe(true)
  })
})
