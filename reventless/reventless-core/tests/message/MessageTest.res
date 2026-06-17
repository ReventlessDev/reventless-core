open JestGlobals
open Message

type event = event'<string, PluginSpec.event>

describe("Message should", () => {
  testSync("create a valid sequenceNr", () => {
    let now = 123456789.
    let hrtime = (1, 1)
    expect(hrtimeToString(~hrtime, ~now))->toBe("123456789-000000001")
  })

  testSync("get variant name of json without payload", () => {
    let variant = PluginSpec.Heartbeat("0.0.0")
    let variantJson = variant->Message.encode(PluginSpec.commandSchema)
    let variantName = variantNameOfJson(variantJson)

    expect(variantName)->toBe("Heartbeat")
  })

  testSync("get variant name of json with payload", () => {
    let variant = PluginSpec.Connect({
      id: "id",
      name: "testName",
      version: "testVersion",
      extensionPoints: [
        {
          name: "testExtensionPoint",
          commandTopic: "testCommandTopic",
          eventTopic: "testEventTopic",
        },
      ],
      extensions: [
        {
          name: "testExtension",
          extensionPointName: "testExtensionPoint",
          dcbSources: [],
        },
      ],
      eventCollector: "testEventCollector",
      extensionProtocols: [],
      apiSchemaFragment: None,
      apiTarget: None,
      uiFragments: None,
      structure: None,
      dcbEventLog: None,
    })
    let variantJson = variant->Message.encode(PluginSpec.commandSchema)
    let variantName = variantNameOfJson(variantJson)

    let expected = "Connect"

    expect(variantName)->toBe(expected)
  })

  testSync("get event name of eventJson'", () => {
    open PluginSpec
    let event' = {
      id: "testId",
      meta: {
        service: "testService",
        time: "testTime",
        ip: "testIp",
        user: "testUser",
        msgId: "testMsgId",
        correlationId: "testCorrelationId",
      },
      event: VersionDetected("0.0.0"),
    }
    let eventJson' = event'->Message.encodeEvent'(S.string, PluginSpec.eventSchema)
    let eventName = eventJson'->eventNameOfEvent'Json

    expect(eventName)->toBe("VersionDetected")
  })

  testSync("get id of eventJson'", () => {
    open PluginSpec
    let event' = {
      id: "testId",
      meta: {
        service: "testService",
        time: "testTime",
        ip: "testIp",
        user: "testUser",
        msgId: "testMsgId",
        correlationId: "testCorrelationId",
      },
      event: VersionDetected("0.0.0"),
    }
    let eventJson' = event'->Message.encodeEvent'(S.string, PluginSpec.eventSchema)
    let eventId = idOfEvent'Json(eventJson')->Option.getOrThrow

    expect(eventId)->toBe("testId")
  })
})
