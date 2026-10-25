// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.REGISTRATION_UI_BUNDLE_URL"

let dcbSliceSchemas: array<Reventless.DcbTag.sliceSchemas> = [
  {
    name: RegistrationPolicy.name,
    commandSchema: RegistrationPolicy.commandSchema->S.castToUnknown,
    consumedEventSchema: RegistrationPolicy.consumedEventSchema->S.castToUnknown,
    eventSchema: RegistrationPolicy.eventSchema->S.castToUnknown,
    moduleUrl: RegistrationPolicy.moduleUrl,
  },
  {
    name: Registrations.name,
    commandSchema: Registrations.commandSchema->S.castToUnknown,
    consumedEventSchema: Registrations.consumedEventSchema->S.castToUnknown,
    eventSchema: Registrations.eventSchema->S.castToUnknown,
    moduleUrl: Registrations.moduleUrl,
  },
]

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module RegistrationPolicySlice = Platform.StateChangeSlice.Make(
    RegistrationPolicy,
    RegistrationPolicy_Decision,
  )
  module RegistrationsSlice = Platform.StateChangeSlice.Make(Registrations, Registrations_Decision)

  // StateViewSliceStreams
  module RegistrationWindowsStreamSlice = Platform.StateViewSliceStream.Make(
    RegistrationWindows,
    RegistrationWindows_Projection,
  )

  // OutboundTranslationSlices
  module CreateRegisteredPrincipalSlice = Platform.OutboundTranslationSlice.Make(
    CreateRegisteredPrincipal,
    CreateRegisteredPrincipal_Translation,
  )
  module SendRegistrationChallengeSlice = Platform.OutboundTranslationSlice.Make(
    SendRegistrationChallenge,
    SendRegistrationChallenge_Translation,
  )

  // InboundTranslationSlices
  module CompleteRegistrationSlice = Platform.InboundTranslationSlice.Make(
    CompleteRegistration,
    CompleteRegistration_Translation,
  )
  module SignUpSlice = Platform.InboundTranslationSlice.Make(SignUp, SignUp_Translation)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Registration",
    ~stateViewSlices=[module(RegistrationWindowsStreamSlice)],
    ~stateChangeSlices=[module(RegistrationPolicySlice), module(RegistrationsSlice)],
    ~outboundTranslationSlices=[
      module(CreateRegisteredPrincipalSlice),
      module(SendRegistrationChallengeSlice),
    ],
    ~inboundTranslationSlices=[module(CompleteRegistrationSlice), module(SignUpSlice)],
    ~componentChapters=Dict.fromArray([
      ("CompleteRegistration", "Registration"),
      ("CreateRegisteredPrincipal", "Registration"),
      ("RegistrationPolicy", "Registration"),
      ("RegistrationWindows", "Registration"),
      ("Registrations", "Registration"),
      ("SendRegistrationChallenge", "Registration"),
      ("SignUp", "Registration"),
    ]),
    ~lifecycleModel=LifecycleModel.model,
    ~identities=[ContactAddressId.key],
    ~admission=Admission.table,
    ~admissionDoors=[
      (CompleteRegistration.name, CompleteRegistration.admissionDoor),
      (SignUp.name, SignUp.admissionDoor),
    ],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Registration",
      ~heartbeatInterval=5,
      ~stateChangeSlices=[module(RegistrationPolicySlice), module(RegistrationsSlice)],
      ~stateViewSlices=[module(RegistrationWindowsStreamSlice)],
      ~outboundTranslationSlices=[
        module(CreateRegisteredPrincipalSlice),
        module(SendRegistrationChallengeSlice),
      ],
      ~inboundTranslationSlices=[module(CompleteRegistrationSlice), module(SignUpSlice)],
      ~pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Registration",
          ~pluginStructure,
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
