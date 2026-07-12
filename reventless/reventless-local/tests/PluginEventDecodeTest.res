// Regression: subscribeToPluginEvents' Source-C emission decoded the WHOLE bus
// envelope {id, meta, event} with the bare Plugin event schema — convert mode
// "succeeded" and then threw a TypeError on every variant's payload access, so
// the onPluginStatusChange / onUIFragmentChange subscription emissions never
// fired on the local platform. decodePluginEventEnvelope must decode the
// payload under "event" and degrade to None on anything malformed.

open JestGlobals

let _ = TestRunner.setup()

let meta = ReventlessCore.Message.generateMeta(~service=ReventlessCore.PluginSpec.name)

let envelopeOf = (event: ReventlessCore.PluginSpec.event) =>
  ReventlessCore.Message.composeEventJson'(
    "Catalog",
    meta,
    event->S.reverseConvertToJsonOrThrow(ReventlessCore.PluginSpec.eventSchema),
  )

describe("Platform.decodePluginEventEnvelope", () => {
  testSync("decodes a VersionConnected event from the published envelope", () => {
    let envelope = envelopeOf(VersionConnected(Plugin_Fixtures.pluginDefinition))
    switch Platform.decodePluginEventEnvelope(envelope) {
    | Some(VersionConnected(def)) => expect(def.name)->toBe(Plugin_Fixtures.pluginDefinition.name)
    | _ => expect("VersionConnected")->toBe("something else")
    }
  })

  testSync("decodes a payload-light variant (VersionDetected)", () => {
    let envelope = envelopeOf(VersionDetected("2.0.0"))
    expect(Platform.decodePluginEventEnvelope(envelope))->toEqual(
      Some(ReventlessCore.PluginSpec.VersionDetected("2.0.0")),
    )
  })

  testSync("returns None for a bare event JSON (no envelope) and malformed input", () => {
    // The old bug class: input that is not the {id, meta, event} envelope.
    let bare =
      ReventlessCore.PluginSpec.VersionDetected("2.0.0")->S.reverseConvertToJsonOrThrow(
        ReventlessCore.PluginSpec.eventSchema,
      )
    expect(Platform.decodePluginEventEnvelope(bare))->toEqual(None)
    expect(Platform.decodePluginEventEnvelope(JSON.Encode.string("junk")))->toEqual(None)
    expect(
      Platform.decodePluginEventEnvelope(
        JSON.Encode.object(Dict.fromArray([("event", JSON.Encode.object(Dict.make()))])),
      ),
    )->toEqual(None)
  })
})

// The onUIFragmentChange Source-C emission decodes UiFragmentRegistry slice
// events from the admin DcbEventLog's published envelope — the exact shape
// DcbEventLog_Operations produces: composeEventJson'(entityId, meta,
// combineMessage(eventType, data)).
describe("Platform.decodeUiFragmentRegistryEventEnvelope", () => {
  let dcbMeta = ReventlessCore.Message.generateMeta(~service="AdminDcbEventLog")

  let dcbEnvelopeOf = (event: ReventlessCore.UiFragmentRegistry.event) => {
    let json = event->S.reverseConvertToJsonOrThrow(ReventlessCore.UiFragmentRegistry.eventSchema)
    let (eventType, data) = json->ReventlessCore.Message.splitMessage
    ReventlessCore.Message.composeEventJson'(
      "Catalog",
      dcbMeta,
      ReventlessCore.Message.combineMessage(eventType, data),
    )
  }

  testSync("decodes a UiFragmentRegistered event from the published envelope", () => {
    let event = ReventlessCore.UiFragmentRegistry.UiFragmentRegistered({
      pluginId: "Catalog",
      manifest: Plugin_Fixtures.uiManifest,
      at: "t0",
    })
    expect(Platform.decodeUiFragmentRegistryEventEnvelope(dcbEnvelopeOf(event)))->toEqual(
      Some(event),
    )
  })

  testSync("decodes a UiFragmentDeregistered event", () => {
    let event = ReventlessCore.UiFragmentRegistry.UiFragmentDeregistered({pluginId: "Catalog"})
    expect(Platform.decodeUiFragmentRegistryEventEnvelope(dcbEnvelopeOf(event)))->toEqual(
      Some(event),
    )
  })

  testSync("returns None for malformed input", () => {
    expect(
      Platform.decodeUiFragmentRegistryEventEnvelope(JSON.Encode.string("junk")),
    )->toEqual(None)
    expect(
      Platform.decodeUiFragmentRegistryEventEnvelope(
        JSON.Encode.object(Dict.fromArray([("event", JSON.Encode.object(Dict.make()))])),
      ),
    )->toEqual(None)
  })
})
