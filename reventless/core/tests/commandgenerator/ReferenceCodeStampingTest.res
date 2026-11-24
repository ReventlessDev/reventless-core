open JestGlobals

// A reference code's issued field, driven through `makeGenerateCommand` for the reason
// `OwnerStampingTest` gives: what passes here holds on every transport. Beside the stamp, the
// two places that let a caller leave the field out: the mutation's argument and the JSON
// Schema a form is built from.

@schema
type command =
  | SignUp({
      memberId: @s.matches(Reventless.DcbTag.string) string,
      token: @s.matches(Reventless.ReferenceCode.issued) Reventless.ReferenceCode.t,
      name: string,
    })
  | // The control: a command of the same union that makes nothing.
  Rename({
      memberId: @s.matches(Reventless.DcbTag.string) string,
      name: string,
    })

let published: ref<array<Message.commandJson>> = ref([])

let generate = CommandGenerator_Callback.makeGenerateCommand(
  ~publishJsons=async cmds => published := published.contents->Array.concat(cmds),
  ~serviceName="Members",
  ~commandSchema=commandSchema->S.castToUnknown,
  ~componentKind=CommandGenerator_Callback.StateChangeSlice,
  ~stripIdFromParams=false,
)

external asIdentity: 'a => Reventless.Identity.t = "%identity"

let cognito = (~userId, ~groups): Reventless.Identity.t =>
  asIdentity({"userId": userId, "username": userId, "groups": groups, "provider": "Cognito"})

let iam: Reventless.Identity.t = asIdentity({
  "userArn": "arn:aws:sts::1:assumed-role/Seeder",
  "accountId": "1",
  "username": "Seeder",
  "provider": "IAM",
})

let str = JSON.Encode.string

let signUp = (~token: option<string>, ~identity): CommandGenerator.payload =>
  Obj.magic({
    "command": "SignUp",
    "arguments": Dict.fromArray(
      [("memberId", str("m-1")), ("name", str("Ada"))]->Array.concat(
        token->Option.mapOr([], t => [("token", str(t))]),
      ),
    ),
    "meta": {"ip": ["127.0.0.1"], "user": "test", "info": ""},
    "identity": identity,
  })

let tokenOfLast = () =>
  published.contents
  ->Array.at(-1)
  ->Option.flatMap(c => c.commandJson->JSON.Decode.object)
  ->Option.flatMap(o => o->Dict.get("token"))
  ->Option.flatMap(JSON.Decode.string)

let shape = /^[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$/

let _ = beforeEach(() => {
  published := []
  Reventless.OwnerScope.setElevatedGroups(["Admin"])
})

describe("an issued field on the command path:", () => {
  testPromise("an omitted field is filled with a new code", async () => {
    let _ = await generate(
      signUp(~token=None, ~identity=cognito(~userId="m-1", ~groups=["User"])),
    )->Effect.runPromise
    expect(tokenOfLast()->Option.mapOr(false, t => shape->RegExp.test(t)))->toBe(true)
  })

  // The decisive case: a caller who picks their own code gets one made for them anyway.
  testPromise("a value a caller sends is replaced", async () => {
    let _ = await generate(
      signUp(~token=Some("AAAA-AAAA-AAAA"), ~identity=cognito(~userId="m-1", ~groups=["User"])),
    )->Effect.runPromise
    expect(tokenOfLast()->Option.mapOr(false, t => t != "AAAA-AAAA-AAAA"))->toBe(true)
  })

  testPromise("an anonymous caller's command gets one too", async () => {
    let _ = await generate(
      signUp(~token=None, ~identity=Reventless.Identity.anonymous),
    )->Effect.runPromise
    expect(tokenOfLast()->Option.isSome)->toBe(true)
  })

  testPromise("two commands get two codes", async () => {
    let identity = cognito(~userId="m-1", ~groups=["User"])
    let _ = await generate(signUp(~token=None, ~identity))->Effect.runPromise
    let first = tokenOfLast()
    let _ = await generate(signUp(~token=None, ~identity))->Effect.runPromise
    expect(first == tokenOfLast())->toBe(false)
  })

  // Example data and migrations carry codes of their own.
  testPromise("an exempt caller keeps the value it sends", async () => {
    let _ = await generate(
      signUp(~token=Some("AMP-0001"), ~identity=cognito(~userId="ops", ~groups=["Admin"])),
    )->Effect.runPromise
    let elevated = tokenOfLast()
    let _ = await generate(signUp(~token=Some("AMP-0002"), ~identity=iam))->Effect.runPromise
    expect((elevated, tokenOfLast()))->toEqual((Some("AMP-0001"), Some("AMP-0002")))
  })

  testPromise("an exempt caller that sends none gets one made", async () => {
    let _ = await generate(signUp(~token=None, ~identity=iam))->Effect.runPromise
    expect(tokenOfLast()->Option.mapOr(false, t => shape->RegExp.test(t)))->toBe(true)
  })

  testPromise("a command of the same union that makes nothing gets nothing", async () => {
    let _ = await generate(
      Obj.magic({
        "command": "Rename",
        "arguments": Dict.fromArray([("memberId", str("m-1")), ("name", str("Ada"))]),
        "meta": {"ip": ["127.0.0.1"], "user": "test", "info": ""},
        "identity": cognito(~userId="m-1", ~groups=["User"]),
      }),
    )->Effect.runPromise
    expect(tokenOfLast())->toEqual(None)
  })
})

describe("the code comes from the platform's secret source:", () => {
  let withSecrets = secrets =>
    CommandGenerator_Callback.makeGenerateCommand(
      ~publishJsons=async cmds => published := published.contents->Array.concat(cmds),
      ~serviceName="Members",
      ~commandSchema=commandSchema->S.castToUnknown,
      ~componentKind=CommandGenerator_Callback.StateChangeSlice,
      ~stripIdFromParams=false,
      ~secrets,
    )

  testPromise("a source a test pins gives the code, in groups of four", async () => {
    let pinned = withSecrets(Reventless.Secrets.fixed(~token="7KQ3X9MD4TPA", ~hash=h => h))
    let _ = await pinned(
      signUp(~token=None, ~identity=cognito(~userId="m-1", ~groups=["User"])),
    )->Effect.runPromise
    expect(tokenOfLast())->toEqual(Some("7KQ3-X9MD-4TPA"))
  })

  testPromise("a source that cannot draw refuses the command", async () => {
    let none = withSecrets(Reventless.Secrets.unavailable(~reason="no source"))
    let refused = switch await none(
      signUp(~token=None, ~identity=cognito(~userId="m-1", ~groups=["User"])),
    )->Effect.runPromise {
    | _ => false
    | exception _ => true
    }
    expect((refused, published.contents->Array.length))->toEqual((true, 0))
  })
})

describe("a caller may leave an issued field out:", () => {
  let variant = S.schema(s =>
    {
      "memberId": s.matches(S.string),
      "token": s.matches(Reventless.ReferenceCode.issued),
      "name": s.matches(S.string),
    }
  )->S.castToUnknown

  testSync("its mutation argument is optional", () => {
    let types =
      GraphQL_FragmentGenerator.mutationArgTypes(
        ~fieldName="Members_SignUp",
        variant,
      )->Option.getOr(Dict.make())
    expect((types->Dict.get("token"), types->Dict.get("name")))->toEqual((
      Some("String"),
      Some("String!"),
    ))
  })

  testSync("the JSON Schema marks it and does not require it", () => {
    let json = SuryToJsonSchema.deriveObjectSchema(variant)->JSON.Decode.object->Option.getOrThrow
    let marked =
      json
      ->Dict.get("properties")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(p => p->Dict.get("token"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(t => t->Dict.get("x-reventless-issued"))
    let required =
      json
      ->Dict.get("required")
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(JSON.Decode.string)
    expect((marked, required->Array.includes("token"), required->Array.includes("name")))->toEqual((
      Some(JSON.Encode.bool(true)),
      false,
      true,
    ))
  })
})

describe("a reference code in the JSON Schema:", () => {
  let propertyOf = (schema, name) =>
    SuryToJsonSchema.deriveObjectSchema(schema)
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("properties"))
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(p => p->Dict.get(name))
    ->Option.flatMap(JSON.Decode.object)

  testSync("every field of the type says what it is; only the issued one says it is made", () => {
    let schema = S.schema(
      s =>
        {
          "made": s.matches(Reventless.ReferenceCode.issued),
          "presented": s.matches(Reventless.ReferenceCode.schema),
        },
    )->S.castToUnknown
    let keys = name =>
      propertyOf(schema, name)->Option.mapOr(
        (None, None),
        p => (p->Dict.get("x-reventless-semantic"), p->Dict.get("x-reventless-issued")),
      )
    expect((keys("made"), keys("presented")))->toEqual((
      (Some(str("referenceCode")), Some(JSON.Encode.bool(true))),
      (Some(str("referenceCode")), None),
    ))
  })
})
