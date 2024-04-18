open Jest
open Expect
open Logger

describe("Logger", () => {
  describe("commandJsonsToLogMessage", () => {
    test(
      "createTag",
      () => {
        let level = Level.Info
        let loc = Some("File \"Aggregate.res\", line 214, characters 17-24")
        expect(createTag(~level, ~loc))->toEqual("Aggregate#214:")
      },
    )
  })
  describe("commandJsonsToLogMessage", () => {
    test(
      "empty",
      () => {
        let arr: array<Message.commandJson> = []
        expect(commandJsonsToLogMessages(arr))->toEqual([])
      },
    )
    test(
      "simple",
      () => {
        let commands: array<PluginSpec.command> = [Heartbeat]
        let meta: Message.meta = {
          service: "testService",
          time: "testTime",
          ip: "testIp",
          user: "testUser",
          msgId: "testMsgId",
          correlationId: "testCorrelationId",
        }
        let metaStr = meta->Message.meta_encode->Js.Json.stringify
        let arr: array<Message.commandJson> = commands->Belt.Array.mapWithIndex(
          (id, command) => {
            {
              Message.id: id->Belt.Int.toString,
              meta,
              commandJson: command->PluginSpec.command_encode,
              delay: None,
            }
          },
        )
        let expected = `1/1: Heartbeat(0): {"command":["Heartbeat"],"meta":${metaStr},"id":0}`
        expect(commandJsonsToLogMessages(arr))->toEqual([expected])
      },
    )
    test(
      "complex",
      () => {
        let commands: array<PluginSpec.command> = [
          Heartbeat,
          Connect({
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
          }),
        ]
        let meta: Message.meta = {
          service: "testService",
          time: "testTime",
          ip: "testIp",
          user: "testUser",
          msgId: "testMsgId",
          correlationId: "testCorrelationId",
        }
        let metaStr = meta->Message.meta_encode->Js.Json.stringify
        let arr: array<Message.commandJson> = commands->Belt.Array.mapWithIndex(
          (id, command) => {
            {
              Message.id: id->Belt.Int.toString,
              meta,
              commandJson: command->PluginSpec.command_encode,
              delay: None,
            }
          },
        )
        let expected1 = `1/2: Heartbeat(0): {"command":["Heartbeat"],"meta":${metaStr},"id":0}`
        let expected2 = `2/2: Connect(1): {"command":["Connect",{"id":"id","name":"testName","version":"testVersion","extensionPoints":[{"name":"testExtensionPoint","commandTopic":"testCommandTopic","eventTopic":"testEventTopic"}],"extensions":[{"name":"testExtension","extensionPointName":"testExtensionPoint"}],"eventCollector":"testEventCollector"}],"meta":${metaStr},"id":1}`
        expect(commandJsonsToLogMessages(arr))->toEqual([expected1, expected2])
      },
    )
  })
  describe("event'JsonToLogMessage", () => {
    test(
      "simple",
      () => {
        open PluginSpec
        let event': Message.event'<string, event> = {
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
        let event'Json: Js.Json.t =
          event'->Message.event'_encode(Decco.stringToJson, event_encode, _)
        let msg = event'JsonToLogMessage(event'Json)

        let expected = `UnknownPluginDetected(testId): {"event":["UnknownPluginDetected"],"meta":{"service":"testService","time":"testTime","ip":"testIp","user":"testUser","msgId":"testMsgId","correlationId":"testCorrelationId"},"id":"testId"}`

        expect(msg)->toEqual(expected)
      },
    )
  })
})
