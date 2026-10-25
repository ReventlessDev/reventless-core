open JestGlobals

// The shell's self-registration key, read off the plugin structures: the two
// doors by their mutation names and the groups a visitor may sign up for.

let empty: Reventless.Plugin.pluginStructure = {
  readModels: [],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  extensionPoints: None,
  requiredStores: None,
  requiredStoreDeclarations: None,
  requiredCapabilities: None,
  traitDeclarations: None,
  admission: None,
  admissionDoors: None,
}

let registration: Reventless.Plugin.pluginStructure = {
  ...empty,
  admission: Some([
    {Reventless.Admission.role: "Shopper", strategy: "SelfService"},
    {Reventless.Admission.role: "Admin", strategy: "Provisioned"},
  ]),
  admissionDoors: Some([
    {Reventless.Admission.component: "SignUp", part: "start"},
    {Reventless.Admission.component: "CompleteRegistration", part: "complete"},
  ]),
}

describe("Platform_SelfRegistration", () => {
  testSync("names the two doors by their mutation fields and the self-service groups", () =>
    expect(
      Platform_SelfRegistration.fromStructures([
        ("Catalog", empty),
        ("Registration", registration),
      ]),
    )->toEqual(
      Some({
        Platform_SelfRegistration.start: "Registration_SignUp",
        complete: "Registration_CompleteRegistration",
        roles: ["Shopper"],
      }),
    )
  )

  testSync("absent without both doors", () =>
    expect(
      Platform_SelfRegistration.fromStructures([
        (
          "Registration",
          {
            ...registration,
            admissionDoors: Some([{Reventless.Admission.component: "SignUp", part: "start"}]),
          },
        ),
      ]),
    )->toEqual(None)
  )

  testSync("writes the key the shell reads", () =>
    expect(
      Platform_SelfRegistration.configEntry({
        start: "Registration_SignUp",
        complete: "Registration_CompleteRegistration",
        roles: ["Shopper"],
      })
      ->Pair.second
      ->JSON.stringify,
    )->toEqual(`{"start":"Registration_SignUp","complete":"Registration_CompleteRegistration","roles":["Shopper"]}`)
  )
})
