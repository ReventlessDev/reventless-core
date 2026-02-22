open Jest
open Expect
open Logger

S.enableJson()

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
        let metaStr = meta->Message.encode(Message.metaSchema)->JSON.stringify
        let arr: array<Message.commandJson> = commands->Array.mapWithIndex(
          (command, idx) => {
            {
              Message.id: idx->Int.toString,
              meta,
              commandJson: command->Message.encode(PluginSpec.commandSchema),
            }
          },
        )
        let expected = `1/1: Heartbeat(0): {"command":"Heartbeat","meta":${metaStr},"id":0}`
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
            extensionProtocols: [],
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
        let metaStr = meta->Message.encode(Message.metaSchema)->JSON.stringify
        let arr: array<Message.commandJson> = commands->Array.mapWithIndex(
          (command, idx) => {
            {
              Message.id: idx->Int.toString,
              meta,
              commandJson: command->Message.encode(PluginSpec.commandSchema),
            }
          },
        )
        let expected1 = `1/2: Heartbeat(0): {"command":"Heartbeat","meta":${metaStr},"id":0}`
        let expected2 = `2/2: Connect(1): {"command":{"TAG":"Connect","_0":{"id":"id","name":"testName","version":"testVersion","extensionPoints":[{"name":"testExtensionPoint","commandTopic":"testCommandTopic","eventTopic":"testEventTopic"}],"extensions":[{"name":"testExtension","extensionPointName":"testExtensionPoint"}],"eventCollector":"testEventCollector","extensionProtocols":[]}},"meta":${metaStr},"id":1}`
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
        let eventJson' = event'->Message.encodeEvent'(S.string, eventSchema)
        let msg = event'JsonToLogMessage(eventJson')

        let expected = `UnknownPluginDetected(testId): {"event":"UnknownPluginDetected","meta":{"service":"testService","time":"testTime","ip":"testIp","user":"testUser","msgId":"testMsgId","correlationId":"testCorrelationId"},"id":"testId"}`

        expect(msg)->toEqual(expected)
      },
    )
  })
})
