// Unit tests for InboundTranslationSlice_Callback — tests receive function directly.

open JestGlobals
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
    testPromise(
      "valid input with completed status publishes command and returns Ok",
      async () => {
        let publishedCommands = ref([])
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
          publishedCommands := cmds
        }

        let inputJson = {
          "paymentId": "pay-123",
          "orderId": "ord-1",
          "status": "completed",
        }->Obj.magic

        let result = await Callback.receive(
          mockPublish,
          inputJson,
          ~capabilities=Reventless.Capabilities.none,
        )

        switch result {
        | Ok({requestId, targetIds, commandCount}) =>
          expect(targetIds)->toEqual(["ord-1"])
          expect(commandCount)->toBe(1)
          // requestId keys the audit row, so the caller can correlate the response.
          expect(Callback.auditLog->Dict.get(requestId)->Option.isSome)->toBe(true)
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
      },
    )

    testPromise(
      "translate returns Error — no command published, audit logged",
      async () => {
        let publishedCommands = ref([])
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
          publishedCommands := cmds
        }

        let inputJson = {
          "paymentId": "pay-123",
          "orderId": "ord-1",
          "status": "pending",
        }->Obj.magic

        let result = await Callback.receive(
          mockPublish,
          inputJson,
          ~capabilities=Reventless.Capabilities.none,
        )

        switch result {
        | Error({error}) => expect(error)->toBe("Unknown payment status: pending")
        | Ok(_) => expect(true)->toBe(false)
        }
        expect(publishedCommands.contents->Array.length)->toBe(0)

        let auditEntries = Callback.auditLog->Dict.toArray
        expect(auditEntries->Array.length)->toBe(1)
        let (_, auditRow) = auditEntries->Array.getUnsafe(0)
        expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
      },
    )

    testPromise(
      "invalid JSON input returns Error and audit logged",
      async () => {
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()

        // Missing required fields
        let inputJson = {"unexpected": "data"}->Obj.magic

        let result = await Callback.receive(
          mockPublish,
          inputJson,
          ~capabilities=Reventless.Capabilities.none,
        )

        switch result {
        | Error(_) => expect(true)->toBe(true)
        | Ok(_) => expect(true)->toBe(false)
        }

        let auditEntries = Callback.auditLog->Dict.toArray
        expect(auditEntries->Array.length)->toBe(1)
        let (_, auditRow) = auditEntries->Array.getUnsafe(0)
        expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
      },
    )

    testPromise(
      "publishJsons failure returns Error and audit logged",
      async () => {
        let failingPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => {
          JsError.throwWithMessage("publish failed")
        }

        let inputJson = {
          "paymentId": "pay-123",
          "orderId": "ord-1",
          "status": "completed",
        }->Obj.magic

        let result = await Callback.receive(
          failingPublish,
          inputJson,
          ~capabilities=Reventless.Capabilities.none,
        )

        switch result {
        | Error({error}) => expect(error)->toBe("publish failed")
        | Ok(_) => expect(true)->toBe(false)
        }

        let auditEntries = Callback.auditLog->Dict.toArray
        expect(auditEntries->Array.length)->toBe(1)
        let (_, auditRow) = auditEntries->Array.getUnsafe(0)
        expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
      },
    )
  })

  // `auditLog` hands a row to whoever persists it and must not keep it: the dict
  // outlives the request (a warm Lambda container serves many), so a drain that
  // re-read the whole dict would rewrite every row the container had ever seen on
  // every request — and, since the write overwrites by row id, would resurrect
  // rows deleted from the table in between. Persisting is per-request and takes.
  describe("draining the audit log", () => {
    testPromise(
      "taking a row leaves the log empty for the next request",
      async () => {
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
        let input = status =>
          {"paymentId": "pay-1", "orderId": "ord-1", "status": status}->Obj.magic

        let first = await Callback.receive(
          mockPublish,
          input("completed"),
          ~capabilities=Reventless.Capabilities.none,
        )
        let firstId = first->ReventlessCore.InboundTranslationSlice_Callback.requestIdOf
        expect(
          Callback.auditLog
          ->ReventlessCore.InboundTranslationSlice_Callback.takeAuditRow(firstId)
          ->Option.isSome,
        )->toBe(true)
        expect(Callback.auditLog->Dict.toArray->Array.length)->toBe(0)

        // A second request drains only its own row — the first one is gone, so it
        // cannot be written a second time.
        let second = await Callback.receive(
          mockPublish,
          input("completed"),
          ~capabilities=Reventless.Capabilities.none,
        )
        let secondId = second->ReventlessCore.InboundTranslationSlice_Callback.requestIdOf
        expect(secondId == firstId)->toBe(false)
        expect(Callback.auditLog->Dict.toArray->Array.length)->toBe(1)
        expect(
          Callback.auditLog
          ->ReventlessCore.InboundTranslationSlice_Callback.takeAuditRow(firstId)
          ->Option.isSome,
        )->toBe(false)
        expect(
          Callback.auditLog
          ->ReventlessCore.InboundTranslationSlice_Callback.takeAuditRow(secondId)
          ->Option.isSome,
        )->toBe(true)
      },
    )

    testPromise(
      "a rejected request's row is drained the same way",
      async () => {
        let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async _cmds => ()
        let result = await Callback.receive(
          mockPublish,
          {"paymentId": "pay-1", "orderId": "ord-1", "status": "pending"}->Obj.magic,
          ~capabilities=Reventless.Capabilities.none,
        )
        let id = result->ReventlessCore.InboundTranslationSlice_Callback.requestIdOf
        switch Callback.auditLog->ReventlessCore.InboundTranslationSlice_Callback.takeAuditRow(id) {
        | Some(row) =>
          expect(row.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
        | None => expect(true)->toBe(false)
        }
        expect(Callback.auditLog->Dict.toArray->Array.length)->toBe(0)
      },
    )
  })

  describe("multi-command", () => {
    testPromise(
      "translate returning multiple pairs publishes all commands",
      async () => {
        // Use a spec that returns multiple commands
        module MultiSpec = {
          let name = "BatchWebhook"
          let moduleUrl: string = %raw(`import.meta.url`)

          @schema
          type externalInput = {orderId: string, items: array<string>}

          @schema
          type command =
            | ConfirmPayment({
                orderId: @s.matches(Reventless.DcbTag.string) string,
                paymentId: string,
              })

          let targetName = "ConfirmPayment"
          let externalSystem = None
          let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
          let endpoint = None

          let translate = async (
            input: externalInput,
            ~capabilities as _: Reventless.Capabilities.t,
            ~caller as _: option<Reventless.Identity.t>,
          ) => Ok(
            input.items->Array.map(
              item => (input.orderId, ConfirmPayment({orderId: input.orderId, paymentId: item})),
            ),
          )

          type role = Reventless.Role.name

          let authorizationOf = (_: string): Reventless.Authorization.rule<role> =>
            AllowAuthenticated
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

        let inputJson = {
          "orderId": "ord-1",
          "items": ["pay-1", "pay-2", "pay-3"],
        }->Obj.magic

        let result = await MultiCallback.receive(
          mockPublish,
          inputJson,
          ~capabilities=Reventless.Capabilities.none,
        )

        switch result {
        | Ok({targetIds, commandCount}) =>
          expect(targetIds)->toEqual(["ord-1", "ord-1", "ord-1"])
          expect(commandCount)->toBe(3)
        | Error(_) => expect(true)->toBe(false)
        }
        // All 3 commands published in one batch
        expect(publishedCommands.contents->Array.length)->toBe(3)

        let auditEntries = MultiCallback.auditLog->Dict.toArray
        expect(auditEntries->Array.length)->toBe(1)
        let (_, auditRow) = auditEntries->Array.getUnsafe(0)
        expect(auditRow.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Success)
        expect(auditRow.commandCount)->toBe(Some(3))
      },
    )

    testPromise(
      "translate returning empty array publishes nothing",
      async () => {
        module EmptySpec = {
          let name = "EmptyWebhook"
          let moduleUrl: string = %raw(`import.meta.url`)

          @schema
          type externalInput = {orderId: string}

          @schema
          type command =
            | ConfirmPayment({
                orderId: @s.matches(Reventless.DcbTag.string) string,
                paymentId: string,
              })

          let targetName = "ConfirmPayment"
          let externalSystem = None
          let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
          let endpoint = None

          let translate = async (
            _input: externalInput,
            ~capabilities as _: Reventless.Capabilities.t,
            ~caller as _: option<Reventless.Identity.t>,
          ) => Ok([])

          type role = Reventless.Role.name

          let authorizationOf = (_: string): Reventless.Authorization.rule<role> =>
            AllowAuthenticated
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

        let result = await EmptyCallback.receive(
          mockPublish,
          inputJson,
          ~capabilities=Reventless.Capabilities.none,
        )

        switch result {
        | Ok({targetIds, commandCount}) =>
          expect(targetIds)->toEqual([])
          expect(commandCount)->toBe(0)
        | Error(_) => expect(true)->toBe(false)
        }
        expect(publishedCommands.contents->Array.length)->toBe(0)
      },
    )
  })
})

module CatalogFeedTranslation = {
  let translate = CatalogFeedSpec.translate
  let moduleUrl = CatalogFeedSpec.moduleUrl
}
module CatalogFeedCallback = ReventlessCore.InboundTranslationSlice_Callback.Make(
  CatalogFeedSpec,
  CatalogFeedTranslation,
)

let caller = (groups): Reventless.Identity.t => {
  userId: "u-1",
  username: "alice",
  groups,
  provider: InMemory,
}

let catalogInput = (kind): JSON.t =>
  Dict.fromArray([
    ("kind", JSON.Encode.string(kind)),
    ("id", JSON.Encode.string("x-1")),
  ])->JSON.Encode.object

describe("receive checks each command against its own rule", () => {
  let published = ref([])
  let publish: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
    published := published.contents->Array.concat(cmds)
  let _ = beforeEach(() => published := [])

  testPromise(
    "a caller lacking one command's role is refused, and nothing is published",
    async () => {
      let result = await CatalogFeedCallback.receive(
        publish,
        catalogInput("both"),
        ~capabilities=Reventless.Capabilities.none,
        ~caller=caller(["Merchandiser"]),
      )
      switch result {
      | Error({requestId, ?errorCode}) =>
        expect(errorCode)->toEqual(Some("Forbidden"))
        let row = CatalogFeedCallback.auditLog->Dict.get(requestId)
        expect(row->Option.map(r => r.status))->toEqual(
          Some(ReventlessCore.InboundTranslationSlice_Callback.Failure),
        )
      | Ok(_) => expect(true)->toBe(false)
      }
      expect(published.contents->Array.length)->toBe(0)
    },
  )

  testPromise("a caller holding every command's role publishes them all", async () => {
    let result = await CatalogFeedCallback.receive(
      publish,
      catalogInput("both"),
      ~capabilities=Reventless.Capabilities.none,
      ~caller=caller(["Merchandiser", "Admin"]),
    )
    expect(result->Result.isOk)->toBe(true)
    expect(published.contents->Array.length)->toBe(2)
  })

  testPromise("the role one command needs is enough when the input yields only it", async () => {
    let result = await CatalogFeedCallback.receive(
      publish,
      catalogInput("product"),
      ~capabilities=Reventless.Capabilities.none,
      ~caller=caller(["Merchandiser"]),
    )
    expect(result->Result.isOk)->toBe(true)
    expect(published.contents->Array.length)->toBe(1)
  })

  testPromise("no caller is the platform itself, and publishes", async () => {
    let result = await CatalogFeedCallback.receive(
      publish,
      catalogInput("both"),
      ~capabilities=Reventless.Capabilities.none,
    )
    expect(result->Result.isOk)->toBe(true)
    expect(published.contents->Array.length)->toBe(2)
  })

  testPromise("a refusal answers CommandRejected with Forbidden", async () => {
    let result = await CatalogFeedCallback.receive(
      publish,
      catalogInput("both"),
      ~capabilities=Reventless.Capabilities.none,
      ~caller=Reventless.Identity.anonymous,
    )
    switch result->ReventlessCore.InboundTranslationSlice_Callback.receiveResultToOutcome {
    | Rejected({errorCode}) => expect(errorCode)->toBe("Forbidden")
    | _ => expect(true)->toBe(false)
    }
  })
})

module NoteFeedTranslation = {
  let translate = NoteFeedSpec.translate
  let moduleUrl = NoteFeedSpec.moduleUrl
}
module NoteFeedCallback = ReventlessCore.InboundTranslationSlice_Callback.Make(
  NoteFeedSpec,
  NoteFeedTranslation,
)

describe("receive encodes commands with their schema", () => {
  testPromise("an absent option the schema writes as null decodes at the target", async () => {
    let published = ref([])
    let publish: ReventlessInfra.CommandTopic.publishJsons = async cmds => published := cmds
    let _ = await NoteFeedCallback.receive(
      publish,
      Dict.fromArray([("orderId", JSON.Encode.string("ord-1"))])->JSON.Encode.object,
      ~capabilities=Reventless.Capabilities.none,
    )

    let commandJson = (published.contents->Array.getUnsafe(0)).commandJson
    // The target decodes with the same schema; the runtime value would omit `note`.
    let decoded = commandJson->S.parseOrThrow(~to=NoteFeedSpec.commandSchema)
    expect(decoded)->toEqual(NoteFeedSpec.Annotate({orderId: "ord-1", note: None}))
    expect(commandJson->JSON.stringify->String.includes(`"note":null`))->toBe(true)
  })
})

// A door that looks at its caller before it decides: only an administrator may
// send it. It refuses before reaching a capability, and the refusal is recorded
// like any other translation error, naming who was refused.
module AdminOnlyTranslation = {
  let translate = async (input, ~capabilities, ~caller: option<Reventless.Identity.t>) =>
    switch caller {
    | None => Error("this door needs a caller")
    | Some(identity) if !(identity->Reventless.Identity.hasGroup("Admin")) =>
      Error("only an administrator may send this")
    | Some(_) => await PaymentWebhookSpec.translate(input, ~capabilities, ~caller)
    }
  let moduleUrl = PaymentWebhookSpec.moduleUrl
}
module AdminOnlyCallback = ReventlessCore.InboundTranslationSlice_Callback.Make(
  PaymentWebhookSpec,
  AdminOnlyTranslation,
)

describe("receive hands the door its caller", () => {
  let payment = {"paymentId": "pay-1", "orderId": "ord-1", "status": "completed"}->Obj.magic
  let identity = (~userId, ~groups): Reventless.Identity.t => {
    ...Reventless.Identity.anonymous,
    userId,
    groups,
  }

  let receive = async (~caller=?) => {
    AdminOnlyCallback.auditLog
    ->Dict.keysToArray
    ->Array.forEach(k => AdminOnlyCallback.auditLog->Dict.delete(k))
    let published = ref([])
    let publish: ReventlessInfra.CommandTopic.publishJsons = async cmds => published := cmds
    let result = await AdminOnlyCallback.receive(
      publish,
      payment,
      ~capabilities=Reventless.Capabilities.none,
      ~caller?,
    )
    let row = AdminOnlyCallback.auditLog->Dict.valuesToArray->Array.getUnsafe(0)
    (result, published.contents, row)
  }

  testPromise("with no caller, the door refuses and nothing is published", async () => {
    let (result, published, row) = await receive()
    expect(result->Result.isError)->toBe(true)
    expect(published)->toEqual([])
    expect(row.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Failure)
    expect(row.error)->toEqual(Some("this door needs a caller"))
    expect(row.caller)->toEqual(None)
  })

  testPromise(
    "a caller lacking the role is refused, and the row names who was refused",
    async () => {
      let (result, published, row) = await receive(
        ~caller=identity(~userId="u_visitor", ~groups=["Shopper"]),
      )
      switch result {
      | Error({error, ?errorCode}) =>
        expect(error)->toBe("only an administrator may send this")
        // The door's refusal, not the platform's per-command gate.
        expect(errorCode)->toEqual(None)
      | Ok(_) => expect(true)->toBe(false)
      }
      expect(published)->toEqual([])
      expect(row.caller)->toEqual(Some("u_visitor"))
    },
  )

  testPromise("a caller holding the role is let through, and named", async () => {
    let (result, published, row) = await receive(
      ~caller=identity(~userId="u_admin", ~groups=["Admin"]),
    )
    expect(result->Result.isOk)->toBe(true)
    expect(published->Array.length)->toBe(1)
    expect(row.status)->toBe(ReventlessCore.InboundTranslationSlice_Callback.Success)
    expect(row.caller)->toEqual(Some("u_admin"))
  })
})
