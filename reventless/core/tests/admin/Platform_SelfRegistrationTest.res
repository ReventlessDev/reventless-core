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
    "names the two doors by their mutation fields, the self-service groups, the open-roles query and the counts query",
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
          counts: "Registration_VisitorRequestCountsByIds",
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
        counts: "Registration_VisitorRequestCountsByIds",
      })
      ->Pair.second
      ->JSON.stringify,
    )->toEqual(`{"start":"Registration_SignUp","complete":"Registration_CompleteRegistration","roles":["Shopper"],"openRoles":"Registration_RegistrationWindows","initially":"closed","policy":{"open":"Registration_OpenRegistration","close":"Registration_CloseRegistration"},"counts":"Registration_VisitorRequestCountsByIds"}`)
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

  testSync("as a file, the settings say where the door for visitors is", () =>
    expect(
      Platform_SelfRegistration.fileJson(
        Some({
          start: "Registration_SignUp",
          complete: "Registration_CompleteRegistration",
          roles: ["Shopper"],
          initially: "closed",
        }),
        ~door={endpoint: "https://x.appsync-api.eu-west-1.amazonaws.com/graphql", apiKey: "da2-k"},
      )->JSON.stringify,
    )->toEqual(`{"start":"Registration_SignUp","complete":"Registration_CompleteRegistration","roles":["Shopper"],"initially":"closed","endpoint":"https://x.appsync-api.eu-west-1.amazonaws.com/graphql","apiKey":"da2-k"}`)
  )

  testSync(
    "a plugin with no door to sign up at writes only where its fields for visitors are",
    () =>
      expect(
        Platform_SelfRegistration.fileJson(
          None,
          ~door={endpoint: "https://x/graphql", apiKey: "da2-k"},
          ~personCheck={siteKey: "0x4A"},
        )->JSON.stringify,
      )->toEqual(`{"endpoint":"https://x/graphql","apiKey":"da2-k"}`),
  )

  testSync("the file names the person check's widget, by its public key only", () =>
    expect(
      Platform_SelfRegistration.fileJson(
        Some({
          start: "Registration_SignUp",
          complete: "Registration_CompleteRegistration",
          roles: ["Shopper"],
          initially: "closed",
        }),
        ~door={endpoint: "https://x/graphql", apiKey: "da2-k"},
        ~personCheck={siteKey: "0x4A"},
      )->JSON.stringify,
    )->toEqual(`{"start":"Registration_SignUp","complete":"Registration_CompleteRegistration","roles":["Shopper"],"initially":"closed","endpoint":"https://x/graphql","apiKey":"da2-k","personCheck":{"siteKey":"0x4A"}}`)
  )
})
