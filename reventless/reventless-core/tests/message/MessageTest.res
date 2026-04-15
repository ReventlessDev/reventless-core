open Jest
open Expect
open Message

type event = event'<string, PluginSpec.event>

describe("Message should", () => {
  test("create a valid sequenceNr", () => {
    let now = 123456789.
    let hrtime = (1, 1)
    expect(hrtimeToString(~hrtime, ~now))->toBe("123456789-000000001")
  })

  test("get variant name of json without payload", () => {
    let variant = PluginSpec.Heartbeat
    let variantJson = variant->Message.encode(PluginSpec.commandSchema)
    let variantName = variantNameOfJson(variantJson)

    expect(variantName)->toBe("Heartbeat")
  })

  test("get variant name of json with payload", () => {
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
      extensions: [{name: "testExtension", extensionPointName: "testExtensionPoint"}],
      eventCollector: "testEventCollector",
      extensionProtocols: [],
      apiSchemaFragment: None,
      apiTarget: None,
    })
    let variantJson = variant->Message.encode(PluginSpec.commandSchema)
    let variantName = variantNameOfJson(variantJson)

    let expected = "Connect"

    expect(variantName)->toBe(expected)
  })

  test("get event name of eventJson'", () => {
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
      event: UnknownPluginDetected,
    }
    let eventJson' = event'->Message.encodeEvent'(S.string, PluginSpec.eventSchema)
    let eventName = eventJson'->eventNameOfEvent'Json

    expect(eventName)->toBe("UnknownPluginDetected")
  })

  test("get id of eventJson'", () => {
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
      event: UnknownPluginDetected,
    }
    let eventJson' = event'->Message.encodeEvent'(S.string, PluginSpec.eventSchema)
    let eventId = idOfEvent'Json(eventJson')->Option.getOrThrow

    expect(eventId)->toBe("testId")
  })
})
