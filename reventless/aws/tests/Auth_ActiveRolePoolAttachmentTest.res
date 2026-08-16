open JestGlobals

// 🚨 The test §6 of the plan asks for, and the one that matters most in this
// feature: `UpdateUserPool` requires "a value for all parameters that you don't
// want set to a default value". An attach that sends only `LambdaConfig`
// silently returns every other setting on the pool to its default — on a pool
// the framework did not create and whose configuration it never described.
//
// So the assertions below are all the same assertion: a pool carrying
// non-default settings still carries them afterwards. The merge is a pure
// function precisely so this is checkable against a pool the test did not
// create, which is the case the merge exists for.

module Attachment = Auth_ActiveRolePoolAttachment

let str = JSON.Encode.string

// A pool that is nothing like a fresh one: MFA on, a deletion guard, a custom
// verification message, two triggers already attached, tags, and a paid tier.
//
// The key set mirrors what `DescribeUserPool` actually returns for a live pool,
// including `IssuerConfiguration` / `KeyConfiguration` — informational fields
// that are *not* members of `UpdateUserPool`. The merge carries them and the SDK
// drops them during serialisation, which is why they are harmless; they are here
// so a future edit that starts filtering on this list has a real shape to filter.
let describedPool = () =>
  Dict.fromArray([
    ("Id", str("eu-west-1_abc123")),
    ("Name", str("CustomerPool")),
    ("Arn", str("arn:aws:cognito-idp:eu-west-1:1:userpool/eu-west-1_abc123")),
    ("Status", str("Enabled")),
    ("CreationDate", str("2020-01-01T00:00:00Z")),
    ("LastModifiedDate", str("2024-01-01T00:00:00Z")),
    ("SchemaAttributes", JSON.Encode.array([str("email")])),
    ("UsernameAttributes", JSON.Encode.array([str("email")])),
    ("EstimatedNumberOfUsers", JSON.Encode.int(4200)),
    ("IssuerConfiguration", Dict.fromArray([("IssuerUri", str("https://x"))])->JSON.Encode.object),
    ("KeyConfiguration", Dict.fromArray([("KmsKeyId", str("k-1"))])->JSON.Encode.object),
    // A paid tier silently reverting to Lite would be a billing- and
    // capability-level regression, and one nothing in the deploy would report.
    ("UserPoolTier", str("PLUS")),
    ("MfaConfiguration", str("ON")),
    ("DeletionProtection", str("ACTIVE")),
    ("EmailVerificationMessage", str("Your code is {####}, do not share it")),
    (
      "Policies",
      Dict.fromArray([
        (
          "PasswordPolicy",
          Dict.fromArray([("MinimumLength", JSON.Encode.int(24))])->JSON.Encode.object,
        ),
      ])->JSON.Encode.object,
    ),
    (
      "UserPoolTags",
      Dict.fromArray([("CostCentre", str("identity"))])->JSON.Encode.object,
    ),
    (
      "LambdaConfig",
      Dict.fromArray([
        ("PreSignUp", str("arn:aws:lambda:eu-west-1:1:function:TheirPreSignUp")),
        ("CustomMessage", str("arn:aws:lambda:eu-west-1:1:function:TheirCustomMessage")),
      ])->JSON.Encode.object,
    ),
  ])

let merged = (~preTokenGenerationArn) =>
  Attachment.mergedUpdateInput(
    ~described=describedPool(),
    ~userPoolId="eu-west-1_abc123",
    ~preTokenGenerationArn,
  )

let triggerArn = "arn:aws:lambda:eu-west-1:1:function:ActiveRoleTrigger"

let lambdaConfigOf = input =>
  input->Dict.get("LambdaConfig")->Option.flatMap(JSON.Decode.object)

/** The `PreTokenGenerationConfig` an attach is expected to write: our ARN, at the
    only version the trigger handler implements. */
let v1Config = arn =>
  Dict.fromArray([("LambdaArn", str(arn)), ("LambdaVersion", str("V1_0"))])->JSON.Encode.object

describe("Auth_ActiveRolePoolAttachment.mergedUpdateInput — settings survive the attach", () => {
  let input = merged(~preTokenGenerationArn=Some(triggerArn))

  testSync("MFA stays on rather than defaulting off", () =>
    expect(input->Dict.get("MfaConfiguration"))->toEqual(Some(str("ON")))
  )

  testSync("deletion protection stays active", () =>
    expect(input->Dict.get("DeletionProtection"))->toEqual(Some(str("ACTIVE")))
  )

  testSync("a customised verification message is not reset", () =>
    expect(input->Dict.get("EmailVerificationMessage"))->toEqual(
      Some(str("Your code is {####}, do not share it")),
    )
  )

  testSync("the password policy travels whole", () =>
    expect(
      input
      ->Dict.get("Policies")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(p => p->Dict.get("PasswordPolicy"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(p => p->Dict.get("MinimumLength")),
    )->toEqual(Some(JSON.Encode.int(24)))
  )

  testSync("tags are not dropped", () =>
    expect(
      input
      ->Dict.get("UserPoolTags")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(t => t->Dict.get("CostCentre")),
    )->toEqual(Some(str("identity")))
  )

  testSync("a paid tier is not reverted to Lite", () =>
    expect(input->Dict.get("UserPoolTier"))->toEqual(Some(str("PLUS")))
  )

  // The reset hazard one level down: replacing the whole `LambdaConfig` with a
  // single-key object would silently detach every trigger the customer had.
  testSync("the pool's existing triggers stay attached", () =>
    expect((
      lambdaConfigOf(input)->Option.flatMap(c => c->Dict.get("PreSignUp")),
      lambdaConfigOf(input)->Option.flatMap(c => c->Dict.get("CustomMessage")),
    ))->toEqual((
      Some(str("arn:aws:lambda:eu-west-1:1:function:TheirPreSignUp")),
      Some(str("arn:aws:lambda:eu-west-1:1:function:TheirCustomMessage")),
    ))
  )

  testSync("and ours is added beside them", () =>
    expect(lambdaConfigOf(input)->Option.flatMap(c => c->Dict.get("PreTokenGeneration")))->toEqual(
      Some(str(triggerArn)),
    )
  )
})

describe("Auth_ActiveRolePoolAttachment.mergedUpdateInput — shaping for the API", () => {
  let input = merged(~preTokenGenerationArn=Some(triggerArn))

  testSync("UserPoolId names the pool being updated", () =>
    expect(input->Dict.get("UserPoolId"))->toEqual(Some(str("eu-west-1_abc123")))
  )

  // DescribeUserPool returns `Name`; UpdateUserPool takes `PoolName`. Sending
  // `Name` is rejected, and omitting the rename would rename the pool by default.
  testSync("Name is renamed to PoolName rather than dropped", () =>
    expect((input->Dict.get("PoolName"), input->Dict.get("Name")))->toEqual((
      Some(str("CustomerPool")),
      None,
    ))
  )

  testSync("read-only fields UpdateUserPool rejects are not sent", () =>
    expect(
      ["Id", "Arn", "Status", "CreationDate", "LastModifiedDate", "SchemaAttributes",
       "UsernameAttributes", "EstimatedNumberOfUsers"]->Array.filter(k =>
        input->Dict.get(k)->Option.isSome
      ),
    )->toEqual([])
  )
})

describe("Auth_ActiveRolePoolAttachment.mergedUpdateInput — detaching", () => {
  let input = merged(~preTokenGenerationArn=None)

  // Destroy has to detach, or the pool is left pointing at a deleted function and
  // every sign-in fails — on a pool nothing in this deployment would ever fix.
  testSync("clearing removes our trigger", () =>
    expect(lambdaConfigOf(input)->Option.flatMap(c => c->Dict.get("PreTokenGeneration")))->toEqual(
      None,
    )
  )

  testSync("clearing leaves the customer's own triggers alone", () =>
    expect(lambdaConfigOf(input)->Option.flatMap(c => c->Dict.get("PreSignUp")))->toEqual(
      Some(str("arn:aws:lambda:eu-west-1:1:function:TheirPreSignUp")),
    )
  )

  testSync("clearing still sends the rest of the pool back whole", () =>
    expect(input->Dict.get("MfaConfiguration"))->toEqual(Some(str("ON")))
  )
})

describe("Auth_ActiveRolePoolAttachment.mergedUpdateInput — a pool with nothing set", () => {
  testSync("a pool with no LambdaConfig gains one holding only our trigger", () => {
    let input = Attachment.mergedUpdateInput(
      ~described=Dict.fromArray([("Name", str("Bare"))]),
      ~userPoolId="eu-west-1_bare",
      ~preTokenGenerationArn=Some(triggerArn),
    )
    expect(lambdaConfigOf(input))->toEqual(
      Some(
        Dict.fromArray([
          ("PreTokenGeneration", str(triggerArn)),
          ("PreTokenGenerationConfig", v1Config(triggerArn)),
        ]),
      ),
    )
  })
})

// 🚨 The pool shape that took the deploy down. Cognito carries this one trigger
// in two fields, and `UpdateUserPool` rejects the call when both are present
// naming different functions. Nothing in this suite carried a
// `PreTokenGenerationConfig` before, which is exactly why it shipped.
describe("Auth_ActiveRolePoolAttachment.mergedUpdateInput — a pool already on the V2 field", () => {
  let theirArn = "arn:aws:lambda:eu-west-1:1:function:TheirOwnPreToken"

  let describedWithConfig = (~version) =>
    Dict.fromArray([
      ("Name", str("CustomerPool")),
      (
        "LambdaConfig",
        Dict.fromArray([
          ("PreSignUp", str("arn:aws:lambda:eu-west-1:1:function:TheirPreSignUp")),
          ("PreTokenGeneration", str(theirArn)),
          (
            "PreTokenGenerationConfig",
            Dict.fromArray([
              ("LambdaArn", str(theirArn)),
              ("LambdaVersion", str(version)),
            ])->JSON.Encode.object,
          ),
        ])->JSON.Encode.object,
      ),
    ])

  let attachOnto = (~version) =>
    Attachment.mergedUpdateInput(
      ~described=describedWithConfig(~version),
      ~userPoolId="eu-west-1_abc123",
      ~preTokenGenerationArn=Some(triggerArn),
    )

  // The property AWS enforces, asserted directly rather than through its error
  // text: the two fields must name the same function.
  testSync("both fields name our trigger, and the same one", () => {
    let config = lambdaConfigOf(attachOnto(~version="V1_0"))
    expect((
      config->Option.flatMap(c => c->Dict.get("PreTokenGeneration")),
      config
      ->Option.flatMap(c => c->Dict.get("PreTokenGenerationConfig"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(c => c->Dict.get("LambdaArn")),
    ))->toEqual((Some(str(triggerArn)), Some(str(triggerArn))))
  })

  // A pool left on V2_0 does not fail — the handler answers in V1_0 shape and
  // Cognito ignores it, so tokens mint un-narrowed and nothing reports it.
  testSync("a pool that arrived on V2_0 is pinned back to the version we implement", () =>
    expect(
      lambdaConfigOf(attachOnto(~version="V2_0"))
      ->Option.flatMap(c => c->Dict.get("PreTokenGenerationConfig"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(c => c->Dict.get("LambdaVersion")),
    )->toEqual(Some(str("V1_0")))
  )

  testSync("the customer's other triggers still survive", () =>
    expect(
      lambdaConfigOf(attachOnto(~version="V1_0"))->Option.flatMap(c => c->Dict.get("PreSignUp")),
    )->toEqual(Some(str("arn:aws:lambda:eu-west-1:1:function:TheirPreSignUp")))
  )

  testSync("detaching removes both fields, not just the legacy one", () => {
    let config = lambdaConfigOf(
      Attachment.mergedUpdateInput(
        ~described=describedWithConfig(~version="V1_0"),
        ~userPoolId="eu-west-1_abc123",
        ~preTokenGenerationArn=None,
      ),
    )
    expect((
      config->Option.flatMap(c => c->Dict.get("PreTokenGeneration")),
      config->Option.flatMap(c => c->Dict.get("PreTokenGenerationConfig")),
    ))->toEqual((None, None))
  })

  // The fixpoint property, and the one that would have caught this: AWS
  // materialises whichever field the merge did not write, so the merge has to
  // accept its own output unchanged or a later deploy fails with nothing altered
  // but the service normalising its own record.
  testSync("feeding the merge its own output back changes nothing", () => {
    let once = attachOnto(~version="V1_0")
    let twice = Attachment.mergedUpdateInput(
      ~described=once,
      ~userPoolId="eu-west-1_abc123",
      ~preTokenGenerationArn=Some(triggerArn),
    )
    expect(lambdaConfigOf(twice))->toEqual(lambdaConfigOf(once))
  })
})

describe("Auth_ActiveRolePoolAttachment.attachedTrigger", () => {
  testSync("reports the trigger a described pool carries", () =>
    expect(Attachment.attachedTrigger(~described=merged(~preTokenGenerationArn=Some(triggerArn))))
    ->toEqual(Some(triggerArn))
  )

  testSync("reports none when the pool carries no trigger", () =>
    expect(Attachment.attachedTrigger(~described=Dict.fromArray([("Name", str("Bare"))])))->toEqual(
      None,
    )
  )

  testSync("reads the V2 field on a pool that only carries that one", () =>
    expect(
      Attachment.attachedTrigger(
        ~described=Dict.fromArray([
          (
            "LambdaConfig",
            Dict.fromArray([("PreTokenGenerationConfig", v1Config(triggerArn))])->JSON.Encode.object,
          ),
        ]),
      ),
    )->toEqual(Some(triggerArn))
  )

  // Our own ARN, at a version the handler does not speak. Reporting it as
  // attached would leave a pool minting un-narrowed tokens looking correct
  // forever; reporting none makes it drift the next `up` repairs.
  testSync("reports none for our trigger held at a version we do not implement", () =>
    expect(
      Attachment.attachedTrigger(
        ~described=Dict.fromArray([
          (
            "LambdaConfig",
            Dict.fromArray([
              (
                "PreTokenGenerationConfig",
                Dict.fromArray([
                  ("LambdaArn", str(triggerArn)),
                  ("LambdaVersion", str("V2_0")),
                ])->JSON.Encode.object,
              ),
            ])->JSON.Encode.object,
          ),
        ]),
      ),
    )->toEqual(None)
  )
})

// The pre-attach check. Its whole job is to keep a trigger that cannot run off a
// live pool, because a pre-token-generation trigger that throws does not degrade
// the feature — it fails every sign-in for every user of that pool.
describe("Auth_ActiveRolePoolAttachment.probeVerdict", () => {
  // The real payload from the outage this check exists to prevent: the function
  // could not resolve a package at module load, so it died during init and never
  // reached its handler. Nothing inside the handler could have caught this.
  let initFailurePayload = `{"errorType":"Error","errorMessage":"Cannot find package '@reventlessdev/reventless-core' imported from /var/task/node_modules/@reventlessdev/reventless-aws/src/adapter/Auth/Auth_ActiveRoleTrigger_Ops.res.mjs","code":"ERR_MODULE_NOT_FOUND"}`

  testSync("refuses a function that died before reaching its handler", () =>
    expect(
      Attachment.probeVerdict(~functionError=Some("Unhandled"), ~payload=initFailurePayload),
    )->toEqual(Attachment.Crashed("Unhandled"))
  )

  testSync("accepts a function that hands the event back", () =>
    expect(
      Attachment.probeVerdict(
        ~functionError=None,
        ~payload=`{"request":{"groupConfiguration":{"groupsToOverride":[]}},"response":{}}`,
      ),
    )->toEqual(Attachment.Healthy)
  )

  // A 200 carrying the wrong shape is as fatal to sign-in as a throw, and far
  // easier to mistake for success.
  testSync("refuses a successful call that returns something else", () =>
    expect(Attachment.probeVerdict(~functionError=None, ~payload=`{"ok":true}`))->toEqual(
      Attachment.NotAnEvent,
    )
  )

  // Produces a verdict rather than escaping: a parse error here would fail the
  // deploy with a message about JSON instead of about the trigger.
  testSync("treats an unparseable payload as not an event", () =>
    expect(Attachment.probeVerdict(~functionError=None, ~payload="<html>502</html>"))->toEqual(
      Attachment.NotAnEvent,
    )
  )

  testSync("treats an empty payload as not an event", () =>
    expect(Attachment.probeVerdict(~functionError=None, ~payload=""))->toEqual(
      Attachment.NotAnEvent,
    )
  )
})

describe("Auth_ActiveRolePoolAttachment.probeEvent", () => {
  let event = Attachment.probeEvent(~userPoolId="eu-west-1_Example")->JSON.Decode.object

  testSync("is shaped like the V1_0 event Cognito sends", () =>
    expect(
      event
      ->Option.flatMap(o => o->Dict.get("request"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.isSome,
    )->toBe(true)
  )

  // Empty membership and a subject that cannot exist: the probe checks that the
  // function runs, not what it decides, and must not collide with a real row.
  testSync("presents no groups to narrow", () =>
    expect(
      event
      ->Option.flatMap(o => o->Dict.get("request"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(r => r->Dict.get("groupConfiguration"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(g => g->Dict.get("groupsToOverride"))
      ->Option.flatMap(JSON.Decode.array),
    )->toEqual(Some([]))
  )
})
