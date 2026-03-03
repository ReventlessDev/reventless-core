// Unit tests for InboundTranslationSlice_Callback — tests receive function directly.

open AsyncTest
open AsyncTest.Expect
open InboundTranslationSliceFixtures

module Callback = ReventlessCore.InboundTranslationSlice_Callback.Make(PaymentWebhookSpec)

describe("InboundTranslationSlice Callback", () => {
  let _ = beforeEach(() => {
    Callback.auditLog := Dict.make()
  })

  describe("receive", () => {
    testPromise("valid input with completed status publishes command and returns Ok", async () => {
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }

      let inputJson =
        {
          "paymentId": "pay-123",
          "orderId": "ord-1",
          "status": "completed",
        }->Obj.magic

      let result = await Callback.receive(mockPublish, inputJson)

      switch result {
      | Ok(targetId) => expect(targetId)->toBe("ord-1")
      | Error(_) => expect(true)->toBe(false)
      }
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let cmd = publishedCommands.contents->Array.getUnsafe(0)
      expect(cmd.id)->toBe("ord-1")

      // Audit log should have one entry
      let auditEntries = Callback.auditLog.contents->Dict.toArray
      expect(auditEntries->Array.length)->toBe(1)
      let (_, auditRow) = auditEntries->Array.getUnsafe(0)
      expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Success)
    })

    testPromise("translate returns Error — no command published, audit logged", async () => {
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }

      let inputJson =
        {
          "paymentId": "pay-123",
          "orderId": "ord-1",
          "status": "pending",
        }->Obj.magic

      let result = await Callback.receive(mockPublish, inputJson)

      switch result {
      | Error(msg) => expect(msg)->toBe("Unknown payment status: pending")
      | Ok(_) => expect(true)->toBe(false)
      }
      expect(publishedCommands.contents->Array.length)->toBe(0)

      let auditEntries = Callback.auditLog.contents->Dict.toArray
      expect(auditEntries->Array.length)->toBe(1)
      let (_, auditRow) = auditEntries->Array.getUnsafe(0)
      expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
    })

    testPromise("invalid JSON input returns Error and audit logged", async () => {
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()

      // Missing required fields
      let inputJson = {"unexpected": "data"}->Obj.magic

      let result = await Callback.receive(mockPublish, inputJson)

      switch result {
      | Error(_) => expect(true)->toBe(true)
      | Ok(_) => expect(true)->toBe(false)
      }

      let auditEntries = Callback.auditLog.contents->Dict.toArray
      expect(auditEntries->Array.length)->toBe(1)
      let (_, auditRow) = auditEntries->Array.getUnsafe(0)
      expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
    })

    testPromise("publishJsons failure returns Error and audit logged", async () => {
      let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => {
        JsError.throwWithMessage("publish failed")
      }

      let inputJson =
        {
          "paymentId": "pay-123",
          "orderId": "ord-1",
          "status": "completed",
        }->Obj.magic

      let result = await Callback.receive(failingPublish, inputJson)

      switch result {
      | Error(msg) => expect(msg)->toBe("publish failed")
      | Ok(_) => expect(true)->toBe(false)
      }

      let auditEntries = Callback.auditLog.contents->Dict.toArray
      expect(auditEntries->Array.length)->toBe(1)
      let (_, auditRow) = auditEntries->Array.getUnsafe(0)
      expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
    })
  })
})
