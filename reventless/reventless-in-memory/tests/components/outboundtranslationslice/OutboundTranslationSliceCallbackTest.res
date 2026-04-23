// Unit tests for OutboundTranslationSlice_Callback — tests collect and translate phases directly.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open OutboundTranslationSliceFixtures

module FireForgetCallback = ReventlessCore.OutboundTranslationSlice_Callback.Make(SendTrackingEmailSpec)
module CommandBackCallback = ReventlessCore.OutboundTranslationSlice_Callback.Make(ProcessPaymentSpec)

open ReventlessCore.OutboundTranslationSlice_Callback

describe("OutboundTranslationSlice Callback", () => {
  let _ = beforeEach(() => {
    FireForgetCallback.todoItems->Dict.keysToArray->Array.forEach(k => FireForgetCallback.todoItems->Dict.delete(k))
    CommandBackCallback.todoItems->Dict.keysToArray->Array.forEach(k => CommandBackCallback.todoItems->Dict.delete(k))
    // Reset the translate function to its default
    ProcessPaymentSpec.translateFn :=
      (async (id, _item) => Ok(Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id})))))
  })

  describe("Phase 1 — collect", () => {
    testPromise("OrderShipped event creates a pending outbound item", async () => {
      FireForgetCallback.phase1([OrderShipped({orderId: "ord-1", email: "test@example.com"})])
      let items = FireForgetCallback.todoItems
      expect(items->Dict.toArray->Array.length)->toBe(1)
      let row = items->Dict.get("ord-1")
      expect(row->Option.isSome)->toBe(true)
      let r = row->Option.getOrThrow
      expect(r.status)->toBe(Pending)
      expect(r.retryCount)->toBe(0)
    })

    testPromise("duplicate event does not create a second item (idempotent)", async () => {
      FireForgetCallback.phase1([OrderShipped({orderId: "ord-1", email: "test@example.com"})])
      FireForgetCallback.phase1([OrderShipped({orderId: "ord-1", email: "other@example.com"})])
      let items = FireForgetCallback.todoItems
      expect(items->Dict.toArray->Array.length)->toBe(1)
    })

    testPromise("multiple different events create multiple items", async () => {
      FireForgetCallback.phase1([
        OrderShipped({orderId: "ord-1", email: "a@example.com"}),
        OrderShipped({orderId: "ord-2", email: "b@example.com"}),
      ])
      let items = FireForgetCallback.todoItems
      expect(items->Dict.toArray->Array.length)->toBe(2)
    })

  })

  describe("Phase 2 — translate (fire-and-forget)", () => {
    testPromise("Ok(None) marks item as Completed, no command published", async () => {
      FireForgetCallback.phase1([OrderShipped({orderId: "ord-1", email: "test@example.com"})])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await FireForgetCallback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
      let row = FireForgetCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Completed)
    })

    testPromise("empty TODO list produces no commands", async () => {
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await FireForgetCallback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
    })
  })

  describe("Phase 2 — translate (command-back)", () => {
    testPromise("Ok(Some(...)) marks item as Completed and publishes command", async () => {
      CommandBackCallback.phase1([PaymentReceived({orderId: "ord-1", amount: 50.0})])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := Array.concat(publishedCommands.contents, cmds)
      }
      await CommandBackCallback.phase2(mockPublish)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let cmd = publishedCommands.contents->Array.getUnsafe(0)
      expect(cmd.id)->toBe("ord-1")
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Completed)
    })

    testPromise("Error marks item as Failed with incremented retryCount", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("gateway timeout"))

      CommandBackCallback.phase1([PaymentReceived({orderId: "ord-1", amount: 50.0})])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
      await CommandBackCallback.phase2(mockPublish)

      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Failed)
      expect(row.retryCount)->toBe(1)
    })

    testPromise("failed items with retryCount < maxRetries are retried", async () => {
      // First attempt fails
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("timeout"))
      CommandBackCallback.phase1([PaymentReceived({orderId: "ord-1", amount: 50.0})])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
      await CommandBackCallback.phase2(mockPublish)
      let row1 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row1.retryCount)->toBe(1)

      // Second attempt succeeds
      ProcessPaymentSpec.translateFn :=
        (async (id, _item) => Ok(Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id})))))
      let publishedCommands = ref([])
      let successPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await CommandBackCallback.phase2(successPublish)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let row2 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row2.status)->toBe(Completed)
    })

    testPromise("failed items beyond maxRetries are not retried", async () => {
      // ProcessPaymentSpec.maxRetries = 2, so after 2 failures it should stop
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("timeout"))
      CommandBackCallback.phase1([PaymentReceived({orderId: "ord-1", amount: 50.0})])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()

      // Fail twice
      await CommandBackCallback.phase2(mockPublish)
      await CommandBackCallback.phase2(mockPublish)
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.retryCount)->toBe(2)

      // Third attempt should not be tried
      let publishedCommands = ref([])
      let trackPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await CommandBackCallback.phase2(trackPublish)
      expect(publishedCommands.contents->Array.length)->toBe(0)
      let row2 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      // retryCount should still be 2 — not retried
      expect(row2.retryCount)->toBe(2)
    })

    testPromise("individual item failure does not affect other items", async () => {
      let callCount = ref(0)
      ProcessPaymentSpec.translateFn := (async (id, _item) => {
        callCount := callCount.contents + 1
        if callCount.contents == 1 {
          Error("first item fails")
        } else {
          Ok(Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id}))))
        }
      })

      CommandBackCallback.phase1([
        PaymentReceived({orderId: "ord-1", amount: 50.0}),
        PaymentReceived({orderId: "ord-2", amount: 75.0}),
      ])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := Array.concat(publishedCommands.contents, cmds)
      }
      await CommandBackCallback.phase2(mockPublish)

      // ord-1 should be Failed, ord-2 should be Completed
      let row1 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row1.status)->toBe(Failed)
      let row2 = CommandBackCallback.todoItems->Dict.get("ord-2")->Option.getOrThrow
      expect(row2.status)->toBe(Completed)
      expect(publishedCommands.contents->Array.length)->toBe(1)
    })
  })
})
