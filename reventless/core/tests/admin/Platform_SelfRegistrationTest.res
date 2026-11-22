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
    {Reventless.Admission.role: "Shopper", strategy: SelfServiceWord},
    {Reventless.Admission.role: "Admin", strategy: ProvisionedWord},
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
        Platform_SelfRegistration.fromStructures(
          [("Catalog", empty), ("Registration", registration)],
          ~initially=InitiallyClosed,
        ),
      )->toEqual(
        Some({
          Platform_SelfRegistration.start: "Registration_SignUp",
          complete: "Registration_CompleteRegistration",
          roles: ["Shopper"],
          openRoles: "Registration_RegistrationWindows",
          initially: "closed",
        }),
      ),
  )

  testSync("the open-roles query is left out where no view is marked", () =>
    expect(
      Platform_SelfRegistration.fromStructures(
        [
          (
            "Registration",
            {
              ...registration,
              admissionDoors: registration.admissionDoors
              ->Option.getOr([])
              ->Array.filter(d => d.part != "openRoles"),
            },
          ),
        ],
        ~initially=InitiallyOpen,
      )->Option.flatMap(c => c.openRoles),
    )->toEqual(None)
  )

  testSync("absent without both doors", () =>
    expect(
      Platform_SelfRegistration.fromStructures(
        [
          (
            "Registration",
            {
              ...registration,
              admissionDoors: [{Reventless.Admission.component: "SignUp", part: "start"}],
            },
          ),
        ],
        ~initially=InitiallyOpen,
      ),
    )->toEqual(None)
  )

  testSync("writes the key the shell reads", () =>
    expect(
      Platform_SelfRegistration.configEntry({
        start: "Registration_SignUp",
        complete: "Registration_CompleteRegistration",
        roles: ["Shopper"],
        openRoles: "Registration_RegistrationWindows",
        initially: "closed",
        policy: {
          open_: "Registration_OpenRegistration",
          close: "Registration_CloseRegistration",
        },
      })
      ->Pair.second
      ->JSON.stringify,
    )->toEqual(`{"start":"Registration_SignUp","complete":"Registration_CompleteRegistration","roles":["Shopper"],"openRoles":"Registration_RegistrationWindows","initially":"closed","policy":{"open":"Registration_OpenRegistration","close":"Registration_CloseRegistration"}}`)
  )

  let command = (name): Reventless.Plugin.commandDef => {
    name,
    schema: "{}",
    level: Collection,
    mutationField: `Registration_${name}`,
    references: [],
  }
  let policy = (commands): Reventless.Plugin.pluginStructure => {
    ...registration,
    stateChangeSlices: [
      {
        name: "RegistrationPolicy",
        commands,
        producedEventTypes: [],
        consumedEventTypes: [],
        linkedViews: [],
        events: [],
        errors: [],
      },
    ],
    admissionDoors: registration.admissionDoors
    ->Option.getOr([])
    ->Array.concat([{Reventless.Admission.component: "RegistrationPolicy", part: "policy"}]),
  }

  testSync("names the marked policy's mutations: the one that opens and the one that closes", () =>
    expect(
      Platform_SelfRegistration.fromStructures(
        [("Registration", policy([command("CloseRegistration"), command("OpenRegistration")]))],
        ~initially=InitiallyOpen,
      )->Option.map(c => (c.initially, c.policy)),
    )->toEqual(
      Some((
        "open",
        Some({
          Platform_SelfRegistration.open_: "Registration_OpenRegistration",
          close: "Registration_CloseRegistration",
        }),
      )),
    )
  )

  testSync("no switch where no policy is marked, or it lacks one of the two", () =>
    expect((
      Platform_SelfRegistration.fromStructures(
        [("Registration", registration)],
        ~initially=InitiallyOpen,
      )->Option.flatMap(c => c.policy),
      Platform_SelfRegistration.fromStructures(
        [("Registration", policy([command("OpenRegistration")]))],
        ~initially=InitiallyOpen,
      )->Option.flatMap(c => c.policy),
    ))->toEqual((None, None))
  )
})
