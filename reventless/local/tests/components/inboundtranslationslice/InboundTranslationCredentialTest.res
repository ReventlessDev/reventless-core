// An inbound door that takes a credential: `translate` reaches a capability with
// it, and the audit row never holds it. The shape a registration's
// set-a-password step has.

open JestGlobals

module SignUpSpec = {
  let name = "SignUp"
  let moduleUrl = "test://sign-up"

  // Hand-written marker: this inline module has no `@@reventless.spec` pass.
  @schema
  type externalInput = {
    email: string,
    password: @s.matches(Reventless.Sensitive.string) string,
  }

  @schema
  type command = AccountOpened({email: string, principal: string})

  let targetName = "Accounts"
  let externalSystem = None
  let capabilityNeeds = [Reventless.CapabilityNeed.IdentityProvider]
  let endpoint = None
  type role = Reventless.Role.name
  let authorizationOf = (_: string): Reventless.Authorization.rule<role> => AllowAnonymous
}

module SignUpTranslation = {
  let moduleUrl = SignUpSpec.moduleUrl
  let translate = async (
    input: SignUpSpec.externalInput,
    ~capabilities: Reventless.Capabilities.t,
  ) =>
    switch await capabilities.identityProvider.createPrincipal(
      ~contact=ToEmail(Reventless.Email.unsafe(input.email)),
      ~credential=Password(input.password),
      ~groups=[],
    ) {
    | Ok({providerId}) =>
      Ok([(input.email, SignUpSpec.AccountOpened({email: input.email, principal: providerId}))])
    | Error(Conflict) => Error("taken")
    | Error(Unavailable(why) | Refused(why)) => Error(why)
    }
}

module Callback = ReventlessCore.InboundTranslationSlice_Callback.Make(
  SignUpSpec,
  SignUpTranslation,
)

let input = (~password) =>
  JSON.Encode.object(
    Dict.fromArray([
      ("email", JSON.Encode.string("new@example.com")),
      ("password", JSON.Encode.string(password)),
    ]),
  )

let auditOf = result =>
  Callback.auditLog->Dict.get(result->ReventlessCore.InboundTranslationSlice_Callback.requestIdOf)

let publishNothing: ReventlessInfra.CommandTopic.publishJsons = async _ => ()

describe("an inbound door taking a credential", () => {
  testPromise("translate is handed the platform's capabilities", async () => {
    let created = ref(None)
    let fakes = ReventlessGwt.Capabilities_Fake.make(
      ~createPrincipal=async (~contact as _, ~credential, ~groups as _) => {
        created := Some(credential)
        Ok({Reventless.IdentityProvider.providerId: "p-1"})
      },
      (),
    )
    let result = await Callback.receive(
      publishNothing,
      input(~password="correct horse"),
      ~capabilities=fakes.capabilities,
    )
    expect(result->Result.isOk)->toBe(true)
    expect(created.contents)->toEqual(Some(Reventless.IdentityProvider.Password("correct horse")))
  })

  testPromise("the audit row withholds the credential on success", async () => {
    let result = await Callback.receive(
      publishNothing,
      input(~password="correct horse"),
      ~capabilities=ReventlessGwt.Capabilities_Fake.make().capabilities,
    )
    let row = auditOf(result)->Option.map(r => r.input)->Option.getOr("")
    expect(row->String.includes("correct horse"))->toBe(false)
    expect(row->String.includes("[withheld]"))->toBe(true)
    expect(row->String.includes("new@example.com"))->toBe(true)
  })

  // The refusal path writes its own row, and a refused request is the one most
  // likely to be read by an operator chasing a complaint.
  testPromise("the audit row withholds the credential on a refusal too", async () => {
    let result = await Callback.receive(
      publishNothing,
      input(~password="correct horse"),
      ~capabilities=Reventless.Capabilities.none,
    )
    expect(result->Result.isError)->toBe(true)
    let row = auditOf(result)->Option.map(r => r.input)->Option.getOr("")
    expect(row->String.includes("correct horse"))->toBe(false)
  })

  testSync("a webhook body that cannot be read keeps none of itself", () => {
    let result = Callback.refuse(
      ~body=`{"email": "new@example.com", "password": "correct horse"`,
      ~errorCode="InvalidSignature",
      "unsigned",
    )
    let row = auditOf(result)->Option.map(r => r.input)->Option.getOr("")
    expect(row->String.includes("correct horse"))->toBe(false)
  })

  testSync("a webhook body that can be read keeps everything but the credential", () => {
    let result = Callback.refuse(
      ~body=`{"email": "new@example.com", "password": "correct horse"}`,
      ~errorCode="InvalidSignature",
      "unsigned",
    )
    let row = auditOf(result)->Option.map(r => r.input)->Option.getOr("")
    expect(row->String.includes("correct horse"))->toBe(false)
    expect(row->String.includes("new@example.com"))->toBe(true)
  })

  testSync("a slice with no sensitive field keeps its body as received", () =>
    expect(
      ReventlessCore.InboundTranslationSlice_Callback.redactBody("not json", ~sensitive=[]),
    )->toBe("not json")
  )
})
