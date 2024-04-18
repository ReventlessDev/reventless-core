open Jest
open Expect
open Message

describe("Message should", () => {
  test("create a valid sequenceNr", () => {
    let now = 123456789.
    let hrtime = (1, 1)
    expect(hrtimeToString(~hrtime, ~now))->toBe("123456789-000000001")
  })

  test("get variant name of json without payload", () => {
    let variant = PluginSpec.Heartbeat
    let variantJson = variant->PluginSpec.command_encode
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
    })
    let variantJson = variant->PluginSpec.command_encode
    let variantName = variantNameOfJson(variantJson)

    let expected = "Connect"

    expect(variantName)->toBe(expected)
  })

  test("get event name of event'Json", () => {
    open PluginSpec
    let event': event'<string, event> = {
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
    let event'Json: Js.Json.t = event'->event'_encode(Decco.stringToJson, event_encode, _)
    let eventName = event'Json->eventNameOfEvent'Json

    expect(eventName)->toBe("UnknownPluginDetected")
  })

  test("get id of event'Json", () => {
    open PluginSpec
    let event': event'<string, event> = {
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
    let event'Json: Js.Json.t = event'->event'_encode(Decco.stringToJson, event_encode, _)
    let eventId = idOfEvent'Json(event'Json)->Belt.Option.getExn

    expect(eventId)->toBe("testId")
  })
})
