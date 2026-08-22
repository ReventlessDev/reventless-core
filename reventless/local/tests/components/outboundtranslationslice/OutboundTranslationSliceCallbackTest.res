// Unit tests for OutboundTranslationSlice_Callback — tests collect and translate phases directly.

open JestGlobals
open OutboundTranslationSliceFixtures

module SendTrackingEmailTranslation = {
  let collect = SendTrackingEmailSpec.collect
  let translate = SendTrackingEmailSpec.translate
  let onExhausted = SendTrackingEmailSpec.onExhausted
  let moduleUrl = SendTrackingEmailSpec.moduleUrl
}
module ProcessPaymentTranslation = {
  let collect = ProcessPaymentSpec.collect
  let translate = ProcessPaymentSpec.translate
  let onExhausted = ProcessPaymentSpec.onExhausted
  let moduleUrl = ProcessPaymentSpec.moduleUrl
}
module FireForgetCallback = ReventlessCore.OutboundTranslationSlice_Callback.Make(
  SendTrackingEmailSpec,
  SendTrackingEmailTranslation,
)
module CommandBackCallback = ReventlessCore.OutboundTranslationSlice_Callback.Make(
  ProcessPaymentSpec,
  ProcessPaymentTranslation,
)

open ReventlessCore.OutboundTranslationSlice_Callback

describe("OutboundTranslationSlice Callback", () => {
  let _ = beforeEach(() => {
    FireForgetCallback.todoItems->Dict.keysToArray->Array.forEach(k => FireForgetCallback.todoItems->Dict.delete(k))
    CommandBackCallback.todoItems->Dict.keysToArray->Array.forEach(k => CommandBackCallback.todoItems->Dict.delete(k))
    // Reset the translate function to its default
    ProcessPaymentSpec.translateFn :=
      (async (id, _item) => Ok(Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id})))))
    // Default is a slice with nothing to say when its budget runs out.
    ProcessPaymentSpec.onExhaustedFn := ((_id, _item, _lastError) => None)
  })

  describe("Phase 1 — collect", () => {
    testPromise("OrderShipped event creates a pending outbound item", async () => {
      FireForgetCallback.phase1([("evt", OrderShipped({orderId: "ord-1", email: "test@example.com"}))])
      let items = FireForgetCallback.todoItems
      expect(items->Dict.toArray->Array.length)->toBe(1)
      let row = items->Dict.get("ord-1")
      expect(row->Option.isSome)->toBe(true)
      let r = row->Option.getOrThrow
      expect(r.status)->toBe(Pending)
      expect(r.retryCount)->toBe(0)
    })

    testPromise("duplicate event does not create a second item (idempotent)", async () => {
      FireForgetCallback.phase1([("evt", OrderShipped({orderId: "ord-1", email: "test@example.com"}))])
      FireForgetCallback.phase1([("evt", OrderShipped({orderId: "ord-1", email: "other@example.com"}))])
      let items = FireForgetCallback.todoItems
      expect(items->Dict.toArray->Array.length)->toBe(1)
    })

    testPromise("multiple different events create multiple items", async () => {
      FireForgetCallback.phase1([
        ("evt", OrderShipped({orderId: "ord-1", email: "a@example.com"})),
        ("evt", OrderShipped({orderId: "ord-2", email: "b@example.com"})),
      ])
      let items = FireForgetCallback.todoItems
      expect(items->Dict.toArray->Array.length)->toBe(2)
    })

  })

  describe("Phase 2 — translate (fire-and-forget)", () => {
    testPromise("Ok(None) marks item as Completed, no command published", async () => {
      FireForgetCallback.phase1([("evt", OrderShipped({orderId: "ord-1", email: "test@example.com"}))])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await FireForgetCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)
      expect(publishedCommands.contents->Array.length)->toBe(0)
      let row = FireForgetCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Completed)
    })

    testPromise("empty TODO list produces no commands", async () => {
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await FireForgetCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)
      expect(publishedCommands.contents->Array.length)->toBe(0)
    })
  })

  describe("Phase 2 — translate (command-back)", () => {
    testPromise("Ok(Some(...)) marks item as Completed and publishes command", async () => {
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := Array.concat(publishedCommands.contents, cmds)
      }
      await CommandBackCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let cmd = publishedCommands.contents->Array.getUnsafe(0)
      expect(cmd.id)->toBe("ord-1")
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Completed)
    })

    // The published command's `meta.service` must name the TARGET, not this
    // slice. An aggregate derives its event's meta from the command's, and
    // ReadModel/AutomationSlice callbacks dispatch mappings on `meta.service` —
    // so a slice that stamps its own name here makes the target's events match
    // no mapping and project as zero actions, with no error anywhere.
    testPromise("published command is tagged with the target's name", async () => {
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := Array.concat(publishedCommands.contents, cmds)
      }
      await CommandBackCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)
      let cmd = publishedCommands.contents->Array.getUnsafe(0)
      expect(cmd.meta.service)->toBe("ConfirmPayment")
    })

    testPromise("Error marks item as Failed with incremented retryCount", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("gateway timeout"))

      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
      await CommandBackCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)

      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Failed)
      expect(row.retryCount)->toBe(1)
    })

    testPromise("failed items with retryCount < maxRetries are retried", async () => {
      // First attempt fails
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("timeout"))
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
      await CommandBackCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)
      let row1 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row1.retryCount)->toBe(1)

      // Second attempt succeeds
      ProcessPaymentSpec.translateFn :=
        (async (id, _item) => Ok(Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id})))))
      let publishedCommands = ref([])
      let successPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await CommandBackCallback.phase2(successPublish, ~capabilities=Reventless.Capabilities.none)
      expect(publishedCommands.contents->Array.length)->toBe(1)
      let row2 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row2.status)->toBe(Completed)
    })

    testPromise("failed items beyond maxRetries are not retried", async () => {
      // ProcessPaymentSpec.maxRetries = 2, so after 2 failures it should stop
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("timeout"))
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()

      // Fail once — still retriable, and the status says so.
      await CommandBackCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)
      expect((CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)
      ->toBe(Failed)

      // The second failure spends the budget, and is marked at that moment rather
      // than by falling out of the next pass's filter.
      await CommandBackCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.retryCount)->toBe(2)
      expect(row.status)->toBe(Abandoned)

      // Third attempt should not be tried
      let publishedCommands = ref([])
      let trackPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := cmds
      }
      await CommandBackCallback.phase2(trackPublish, ~capabilities=Reventless.Capabilities.none)
      expect(publishedCommands.contents->Array.length)->toBe(0)
      let row2 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      // retryCount should still be 2 — not retried
      expect(row2.retryCount)->toBe(2)
      expect(row2.status)->toBe(Abandoned)
    })

    // What an older build wrote, and what a Spec that lowers maxRetries leaves
    // behind: Failed at the ceiling, a status promising a retry no pass will make.
    testPromise("a row left stranded at the ceiling is normalised on the next pass", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("timeout"))
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      CommandBackCallback.todoItems->Dict.set("ord-1", {...row, status: Failed, retryCount: 2})

      await CommandBackCallback.phase2(
        async _cmds => (),
        ~capabilities=Reventless.Capabilities.none,
      )
      expect((CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)
      ->toBe(Abandoned)
    })

    testPromise("the last error survives the transition to Abandoned", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("gateway down"))
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let publish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)
      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Abandoned)
      expect(row.lastError)->toEqual(Some("gateway down"))
    })

    testPromise("the row carries the ceiling its count is racing", async () => {
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      expect((CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow).maxRetries)
      ->toEqual(Some(ProcessPaymentSpec.maxRetries))
    })

    // Abandonment is an outcome, and a slice that has one to report gets to say
    // so — the row going quiet is otherwise the only trace.
    testPromise("a slice that answers onExhausted has its command published", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("gateway down"))
      ProcessPaymentSpec.onExhaustedFn :=
        ((id, _item, _lastError) => Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id}))))

      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let published = ref([])
      let publish: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
        published := Array.concat(published.contents, cmds)

      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)
      expect(published.contents->Array.length)->toBe(0) // still retriable
      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)

      expect((CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)
      ->toBe(Abandoned)
      expect(published.contents->Array.length)->toBe(1)
      expect((published.contents->Array.getUnsafe(0)).id)->toBe("ord-1")
      // The target's name, not the slice's — the same rule the success path follows.
      expect((published.contents->Array.getUnsafe(0)).meta.service)->toBe("ConfirmPayment")
    })

    testPromise("the hook is handed the error that ended it", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("gateway down"))
      let seen = ref(None)
      ProcessPaymentSpec.onExhaustedFn :=
        ((_id, _item, lastError) => {
          seen := lastError
          None
        })

      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let publish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)
      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)
      expect(seen.contents)->toEqual(Some("gateway down"))
    })

    testPromise("a silent slice publishes nothing, and the row is still Abandoned", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("gateway down"))
      // onExhaustedFn stays at its default None (reset in beforeEach).
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let published = ref([])
      let publish: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
        published := Array.concat(published.contents, cmds)
      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)
      await CommandBackCallback.phase2(publish, ~capabilities=Reventless.Capabilities.none)
      expect(published.contents->Array.length)->toBe(0)
      expect((CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)
      ->toBe(Abandoned)
    })

    // The budget is what ran out, so there is nothing left to retry with — a row
    // must not fall back to Failed and re-enter the sweep on a publish error.
    testPromise("a failed announcement leaves the row Abandoned", async () => {
      ProcessPaymentSpec.translateFn := (async (_id, _item) => Error("gateway down"))
      ProcessPaymentSpec.onExhaustedFn :=
        ((id, _item, _lastError) => Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id}))))

      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let failOnAbandonment: ReventlessInfra.CommandTopic.publishJsons = async _cmds =>
        JsError.throwWithMessage("topic unavailable")
      await CommandBackCallback.phase2(failOnAbandonment, ~capabilities=Reventless.Capabilities.none)
      await CommandBackCallback.phase2(failOnAbandonment, ~capabilities=Reventless.Capabilities.none)
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row.status)->toBe(Abandoned)
      expect(row.retryCount)->toBe(2)
    })

    // A row an older build stranded reaches the hook too — it is being abandoned
    // now, as far as anything downstream is concerned.
    testPromise("a stranded row announces when it is normalised", async () => {
      ProcessPaymentSpec.onExhaustedFn :=
        ((id, _item, _lastError) => Some((id, ProcessPaymentSpec.ConfirmPayment({orderId: id}))))
      CommandBackCallback.phase1([("evt", PaymentReceived({orderId: "ord-1", amount: 50.0}))])
      let row = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      CommandBackCallback.todoItems->Dict.set("ord-1", {...row, status: Failed, retryCount: 2})

      let published = ref([])
      await CommandBackCallback.phase2(
        async cmds => published := cmds,
        ~capabilities=Reventless.Capabilities.none,
      )
      expect(published.contents->Array.length)->toBe(1)
      expect((CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow).status)
      ->toBe(Abandoned)
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
        ("evt", PaymentReceived({orderId: "ord-1", amount: 50.0})),
        ("evt", PaymentReceived({orderId: "ord-2", amount: 75.0})),
      ])
      let publishedCommands = ref([])
      let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
        publishedCommands := Array.concat(publishedCommands.contents, cmds)
      }
      await CommandBackCallback.phase2(mockPublish, ~capabilities=Reventless.Capabilities.none)

      // ord-1 should be Failed, ord-2 should be Completed
      let row1 = CommandBackCallback.todoItems->Dict.get("ord-1")->Option.getOrThrow
      expect(row1.status)->toBe(Failed)
      let row2 = CommandBackCallback.todoItems->Dict.get("ord-2")->Option.getOrThrow
      expect(row2.status)->toBe(Completed)
      expect(publishedCommands.contents->Array.length)->toBe(1)
    })
  })
})
