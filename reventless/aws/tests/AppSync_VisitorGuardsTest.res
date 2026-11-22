// A self-service role on a public address is refused until the door's guards are
// all there, and the refusal names each one that is missing.

open JestGlobals

module G = AppSync_VisitorGuards

let all: G.has = {fingerprintKey: true, personCheck: true, boundedSender: true, billAlarm: true}

let structure = (admission): Reventless.Plugin.pluginStructure => {
  readModels: [],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  admission,
}

describe("the guards of a door for visitors", () => {
  testSync("a deployment with every guard is not refused", () =>
    expect(G.refusal(~plugin="Registration", ~roles=["Shopper"], all))->toEqual(None)
  )

  testSync("a plugin with no self-service role is not refused, whatever is missing", () =>
    expect(
      G.refusal(
        ~plugin="Catalog",
        ~roles=[],
        {fingerprintKey: false, personCheck: false, boundedSender: false, billAlarm: false},
      ),
    )->toEqual(None)
  )

  testSync("each missing guard is one refusal, naming it", () =>
    expect(
      [
        {...all, fingerprintKey: false},
        {...all, personCheck: false},
        {...all, boundedSender: false},
        {...all, billAlarm: false},
      ]->Array.map(
        has => (
          G.missing(has),
          G.refusal(~plugin="Registration", ~roles=["Shopper"], has)->Option.isSome,
        ),
      ),
    )->toEqual([
      ([G.FingerprintKey], true),
      ([G.PersonCheck], true),
      ([G.BoundedSender], true),
      ([G.BillAlarm], true),
    ])
  )

  testSync("the refusal names the plugin, the roles and every missing guard", () => {
    let why =
      G.refusal(
        ~plugin="Registration",
        ~roles=["Shopper", "Driver"],
        {fingerprintKey: false, personCheck: false, boundedSender: true, billAlarm: true},
      )->Option.getOr("")
    expect((
      why->String.startsWith("Registration: Shopper, Driver can be signed up for by visitors"),
      why->String.includes("platform:fingerprintKey"),
      why->String.includes("a check that a person is signing up"),
      why->String.includes("daily cap"),
    ))->toEqual((true, true, true, false))
  })

  testSync("the self-service roles are read off the plugin's admission table", () =>
    expect(
      G.selfServiceRoles(
        structure([
          {Reventless.Admission.role: "Shopper", strategy: SelfServiceWord},
          {Reventless.Admission.role: "Admin", strategy: ProvisionedWord},
        ]),
      ),
    )->toEqual(["Shopper"])
  )
})

describe("the shell's configuration on a deployed platform", () => {
  testSync("names where the settings for signing up will be", () =>
    expect(
      Util_ShellConfig.fields(~computed=[])->Dict.get(
        ReventlessCore.Platform_SelfRegistration.urlKey,
      ),
    )->toEqual(Some(JSON.String("/self-registration.json")))
  )
})

testSync("a fingerprint key shorter than 32 characters is refused, saying how long it is", () =>
  expect((
    ReventlessCore.Secrets_Node_Backend.checkFingerprintKey(~setting="k", "short")->Result.isError,
    ReventlessCore.Secrets_Node_Backend.checkFingerprintKey(~setting="k", "x"->String.repeat(32)),
    switch ReventlessCore.Secrets_Node_Backend.checkFingerprintKey(~setting="k", "short") {
    | Error(m) => m->String.includes("5 characters")
    | Ok(_) => false
    },
  ))->toEqual((true, Ok("x"->String.repeat(32)), true))
)
