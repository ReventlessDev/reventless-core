// Unit tests for InboundTranslationSlice_Callback — tests receive function directly.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open InboundTranslationSliceFixtures

module PaymentWebhookTranslation = {
  let translate = PaymentWebhookSpec.translate
  let moduleUrl = PaymentWebhookSpec.moduleUrl
}
module Callback = ReventlessCore.InboundTranslationSlice_Callback.Make(
  PaymentWebhookSpec,
  PaymentWebhookTranslation,
)

describe("InboundTranslationSlice Callback", () => {
  let _ = beforeEach(() => {
    Callback.auditLog->Dict.keysToArray->Array.forEach(k => Callback.auditLog->Dict.delete(k))
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
      | Ok(targetIds) =>
        expect(targetIds->Array.length)->toBe(1)
        expect(targetIds->Array.getUnsafe(0))->toBe("ord-1")
      | Error(_) => expect(true)->toBe(false)
      }
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let cmd = publishedCommands.contents->Array.getUnsafe(0)
      expect(cmd.id)->toBe("ord-1")

      // Audit log should have one entry
      let auditEntries = Callback.auditLog->Dict.toArray
      expect(auditEntries->Array.length)->toBe(1)
      let (_, auditRow) = auditEntries->Array.getUnsafe(0)
      expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Success)
      expect(auditRow.commandCount)->toBe(Some(1))
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

      let auditEntries = Callback.auditLog->Dict.toArray
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

      let auditEntries = Callback.auditLog->Dict.toArray
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

      let auditEntries = Callback.auditLog->Dict.toArray
      expect(auditEntries->Array.length)->toBe(1)
      let (_, auditRow) = auditEntries->Array.getUnsafe(0)
      expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
    })
  })

  describe("multi-command", () => {
    testPromise("translate returning multiple pairs publishes all commands", async () => {
      // Use a spec that returns multiple commands
      module MultiSpec = {
        let name = "BatchWebhook"
        let moduleUrl: string = %raw(`import.meta.url`)

        @schema
        type externalInput = {orderId: string, items: array<string>}

        @schema
        type command = ConfirmPayment({
          orderId: @s.matches(Reventless.DcbTag.string) string,
          paymentId: string,
        })

        let targetName = "ConfirmPayment"

        let translate = (input: externalInput) =>
          Ok(
            input.items->Array.map(item => (
              input.orderId,
              ConfirmPayment({orderId: input.orderId, paymentId: item}),
            )),
          )
      }

      module MultiTranslation = {
        let translate = MultiSpec.translate
        let moduleUrl = MultiSpec.moduleUrl
      }
      module MultiCallback = ReventlessCore.InboundTranslationSlice_Callback.Make(
        MultiSpec,
        MultiTranslation,
      )

      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }

      let inputJson =
        {
          "orderId": "ord-1",
          "items": ["pay-1", "pay-2", "pay-3"],
        }->Obj.magic

      let result = await MultiCallback.receive(mockPublish, inputJson)

      switch result {
      | Ok(targetIds) =>
        expect(targetIds->Array.length)->toBe(3)
        expect(targetIds->Array.getUnsafe(0))->toBe("ord-1")
      | Error(_) => expect(true)->toBe(false)
      }
      // All 3 commands published in one batch
      expect(publishedCommands.contents->Array.length)->toBe(3)

      let auditEntries = MultiCallback.auditLog->Dict.toArray
      expect(auditEntries->Array.length)->toBe(1)
      let (_, auditRow) = auditEntries->Array.getUnsafe(0)
      expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Success)
      expect(auditRow.commandCount)->toBe(Some(3))
    })

    testPromise("translate returning empty array publishes nothing", async () => {
      module EmptySpec = {
        let name = "EmptyWebhook"
        let moduleUrl: string = %raw(`import.meta.url`)

        @schema
        type externalInput = {orderId: string}

        @schema
        type command = ConfirmPayment({
          orderId: @s.matches(Reventless.DcbTag.string) string,
          paymentId: string,
        })

        let targetName = "ConfirmPayment"

        let translate = (_input: externalInput) => Ok([])
      }

      module EmptyTranslation = {
        let translate = EmptySpec.translate
        let moduleUrl = EmptySpec.moduleUrl
      }
      module EmptyCallback = ReventlessCore.InboundTranslationSlice_Callback.Make(
        EmptySpec,
        EmptyTranslation,
      )

      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }

      let inputJson = {"orderId": "ord-1"}->Obj.magic

      let result = await EmptyCallback.receive(mockPublish, inputJson)

      switch result {
      | Ok(targetIds) => expect(targetIds->Array.length)->toBe(0)
      | Error(_) => expect(true)->toBe(false)
      }
      expect(publishedCommands.contents->Array.length)->toBe(0)
    })
  })
})
