// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.CHARGING_UI_BUNDLE_URL"

let dcbSliceSchemas: array<Reventless.DcbTag.sliceSchemas> = [
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
  module RecordReadingSlice = Platform.StateChangeSlice.Make(RecordReading, RecordReading_Decision)
  module RegisterChargerSlice = Platform.StateChangeSlice.Make(
    RegisterCharger,
    RegisterCharger_Decision,
  )

  // StateViewSlices
  module ChargersSlice = Platform.StateViewSlice.Make(Chargers, Chargers_Projection)
  module SessionsSlice = Platform.StateViewSlice.Make(Sessions, Sessions_Projection)

  // InboundTranslationSlices
  module MeterChargerSlice = Platform.InboundTranslationSlice.Make(
    MeterCharger,
    MeterCharger_Translation,
  )

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Charging",
    ~stateViewSlices=[module(ChargersSlice), module(SessionsSlice)],
    ~stateChangeSlices=[module(RecordReadingSlice), module(RegisterChargerSlice)],
    ~inboundTranslationSlices=[module(MeterChargerSlice)],
    ~componentChapters=Dict.fromArray([
      ("Chargers", "Charger"),
      ("MeterCharger", "Metering"),
      ("RecordReading", "Metering"),
      ("RegisterCharger", "Charger"),
      ("Sessions", "Metering"),
    ]),
    ~identities=[ChargerId.key],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Charging",
      ~heartbeatInterval=5,
      ~stateChangeSlices=[module(RecordReadingSlice), module(RegisterChargerSlice)],
      ~stateViewSlices=[module(ChargersSlice), module(SessionsSlice)],
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
