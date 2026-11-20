// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.CHARGING_UI_BUNDLE_URL"

let dcbSliceSchemas: array<Reventless.DcbTag.sliceSchemas> = [
  {
    name: LimitPower.name,
    commandSchema: LimitPower.commandSchema->S.castToUnknown,
    consumedEventSchema: LimitPower.consumedEventSchema->S.castToUnknown,
    eventSchema: LimitPower.eventSchema->S.castToUnknown,
    moduleUrl: LimitPower.moduleUrl,
  },
  {
    name: RecordReading.name,
    commandSchema: RecordReading.commandSchema->S.castToUnknown,
    consumedEventSchema: RecordReading.consumedEventSchema->S.castToUnknown,
    eventSchema: RecordReading.eventSchema->S.castToUnknown,
    moduleUrl: RecordReading.moduleUrl,
  },
  {
    name: RegisterCharger.name,
    commandSchema: RegisterCharger.commandSchema->S.castToUnknown,
    consumedEventSchema: RegisterCharger.consumedEventSchema->S.castToUnknown,
    eventSchema: RegisterCharger.eventSchema->S.castToUnknown,
    moduleUrl: RegisterCharger.moduleUrl,
  },
]

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module LimitPowerSlice = Platform.StateChangeSlice.Make(LimitPower, LimitPower_Decision)
  module RecordReadingSlice = Platform.StateChangeSlice.Make(RecordReading, RecordReading_Decision)
  module RegisterChargerSlice = Platform.StateChangeSlice.Make(
    RegisterCharger,
    RegisterCharger_Decision,
  )

  // StateViewSlices
  module ChargersSlice = Platform.StateViewSlice.Make(Chargers, Chargers_Projection)
  module SessionsSlice = Platform.StateViewSlice.Make(Sessions, Sessions_Projection)

  // OutboundTranslationSlices
  module TellChargerPowerSlice = Platform.OutboundTranslationSlice.Make(
    TellChargerPower,
    TellChargerPower_Translation,
  )

  // InboundTranslationSlices
  module MeterChargerSlice = Platform.InboundTranslationSlice.Make(
    MeterCharger,
    MeterCharger_Translation,
  )

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Charging",
    ~stateViewSlices=[module(ChargersSlice), module(SessionsSlice)],
    ~stateChangeSlices=[
      module(LimitPowerSlice),
      module(RecordReadingSlice),
      module(RegisterChargerSlice),
    ],
    ~outboundTranslationSlices=[module(TellChargerPowerSlice)],
    ~inboundTranslationSlices=[module(MeterChargerSlice)],
    ~componentChapters=Dict.fromArray([
      ("Chargers", "Charger"),
      ("LimitPower", "Charger"),
      ("MeterCharger", "Metering"),
      ("RecordReading", "Metering"),
      ("RegisterCharger", "Charger"),
      ("Sessions", "Metering"),
      ("TellChargerPower", "Charger"),
    ]),
    ~identities=[ChargerId.key],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Charging",
      ~heartbeatInterval=5,
      ~stateChangeSlices=[
        module(LimitPowerSlice),
        module(RecordReadingSlice),
        module(RegisterChargerSlice),
      ],
      ~stateViewSlices=[module(ChargersSlice), module(SessionsSlice)],
      ~outboundTranslationSlices=[module(TellChargerPowerSlice)],
      ~inboundTranslationSlices=[module(MeterChargerSlice)],
      ~pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Charging",
          ~pluginStructure,
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
