// The send half. Everything it decides is the retry split — whether a provider's
// answer is worth another attempt or is the final word — so that is what this
// asserts. Who to write to and whether to write at all were settled upstream.

module SendNotificationSlice = {
  include SendNotification
  let collect = SendNotification_Translation.collect
}

@@reventless.gwt

let item: SendNotification.outboundItem = {
  recipientId: "c1",
  reference: "confirm:o1",
  channel: Email,
  address: "buyer@example.com",
  subject: "Your order o1 is confirmed",
  body: "Thanks.",
}

// The real `translate`, driven by a stub provider. Spreads `none` so the test
// says nothing about capabilities it is not exercising.
let withProvider = (
  answer: result<Reventless.Messaging.receipt, Reventless.Messaging.failure>,
) => {
  let capabilities: Reventless.Capabilities.t = {
    ...Reventless.Capabilities.none,
    messaging: {
      channels: [Email],
      send: (~recipient as _, ~message as _) => Promise.resolve(answer),
    },
  }
  (id, item) => SendNotification_Translation.translate(id, item, ~capabilities)
}

describe("SendNotification OutboundTranslationSlice", () => {
  test("an accepted message reports the provider's own id back", () =>
    givenTodo("confirm:o1", item)
    ->whenTranslateMocked(withProvider(Ok({ref: "ses-123"})))
    ->thenCommand(
      "c1",
      RecordDelivery({recipientId: "c1", reference: "confirm:o1", providerRef: "ses-123"}),
    )
  )

  // The half that must not settle. An unreachable provider says nothing about
  // this recipient, and writing the message off would lose a confirmation over a
  // network blip.
  test("an outage leaves the TODO pending", () =>
    givenTodo("confirm:o1", item)
    ->whenTranslateMocked(withProvider(Error(Unavailable("502"))))
    ->thenTodoStatus("confirm:o1", #Pending)
  )

  // The half that must settle. Two more attempts would learn the same thing, and
  // the recipient's row is what needs fixing.
  test("a refused address is recorded as failed rather than retried", () =>
    givenTodo("confirm:o1", item)
    ->whenTranslateMocked(withProvider(Error(Refused("address on the suppression list"))))
    ->thenCommand(
      "c1",
      RecordDeliveryFailure({
        recipientId: "c1",
        reference: "confirm:o1",
        reason: "address on the suppression list",
      }),
    )
  )

  // A channel this deployment does not run. Settled for the same reason: no
  // number of attempts provisions one.
  test("a channel the platform does not provision is recorded, not retried", () =>
    givenTodo("confirm:o1", item)
    ->whenTranslateMocked(withProvider(Error(UnsupportedChannel(Sms))))
    ->thenCommand(
      "c1",
      RecordDeliveryFailure({
        recipientId: "c1",
        reference: "confirm:o1",
        reason: "this deployment provisions no Sms channel",
      }),
    )
  )

  // An address the directory holds that its own channel's grammar refuses. The
  // provider is never called — there is nothing to send it to.
  test("an address its channel cannot parse is recorded without asking the provider", () =>
    givenTodo("confirm:o1", {...item, address: "not-an-address"})
    ->whenTranslateMocked(withProvider(Ok({ref: "must-not-be-used"})))
    ->thenCommand("c1", RecordDeliveryFailure({recipientId: "c1", reference: "confirm:o1", reason: "expected an email address, got \"not-an-address\""}))
  )

  testSync("the request's own reference is the TODO key", () =>
    givenEvent(
      NotificationRequested({
        recipientId: "c1",
        reference: "confirm:o1",
        channel: Email,
        address: "buyer@example.com",
        subject: "Your order o1 is confirmed",
        body: "Thanks.",
      }),
    )
    ->whenCollect
    ->thenTodos([("confirm:o1", item)])
  )
})
