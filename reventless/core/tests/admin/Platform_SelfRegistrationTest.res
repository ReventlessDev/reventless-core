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
}

let registration: Reventless.Plugin.pluginStructure = {
  ...empty,
  admission: [
    {Reventless.Admission.role: "Shopper", strategy: "SelfService"},
    {Reventless.Admission.role: "Admin", strategy: "Provisioned"},
  ],
  admissionDoors: [
    {Reventless.Admission.component: "SignUp", part: "start"},
    {Reventless.Admission.component: "CompleteRegistration", part: "complete"},
    {Reventless.Admission.component: "RegistrationWindows", part: "openRoles"},
  ],
}

describe("Platform_SelfRegistration", () => {
  testSync(
    "names the two doors by their mutation fields, the self-service groups, and the open-roles query",
    () =>
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
          openRoles: "Registration_RegistrationWindows",
        }),
      ),
  )

  testSync("the open-roles query is left out where no view is marked", () =>
    expect(
      Platform_SelfRegistration.fromStructures([
        (
          "Registration",
          {
            ...registration,
            admissionDoors: registration.admissionDoors
            ->Option.getOr([])
            ->Array.filter(d => d.part != "openRoles"),
          },
        ),
      ])->Option.flatMap(c => c.openRoles),
    )->toEqual(None)
  )

  testSync("absent without both doors", () =>
    expect(
      Platform_SelfRegistration.fromStructures([
        (
          "Registration",
          {
            ...registration,
            admissionDoors: [{Reventless.Admission.component: "SignUp", part: "start"}],
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
        openRoles: "Registration_RegistrationWindows",
      })
      ->Pair.second
      ->JSON.stringify,
    )->toEqual(`{"start":"Registration_SignUp","complete":"Registration_CompleteRegistration","roles":["Shopper"],"openRoles":"Registration_RegistrationWindows"}`)
  )
})
