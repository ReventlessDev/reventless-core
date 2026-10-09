// The contact relay. It reaches nothing outside the plugin, so what it decides
// is the keying and the command — and that it sends nothing on the way.

@@reventless.gwt

let item: AnnounceRecipientContact.outboundItem = {recipientId: "c1", email: "alice@x.y"}

describe("AnnounceRecipientContact OutboundTranslationSlice", () => {
  testSync("a registration is relayed, keyed by recipient and address", () =>
    givenEvent(Registered({email: "alice@x.y"}))
    ->whenCollect(~sourceId="c1")
    ->thenTodos([("c1:alice@x.y", item)])
  )

  // A changed address is new work, not work already done.
  testSync("a changed address is relayed under its own key", () =>
    givenEvent(EmailUpdated({email: "alice2@x.y"}))
    ->whenCollect(~sourceId="c1")
    ->thenTodos([("c1:alice2@x.y", {recipientId: "c1", email: "alice2@x.y"})])
  )

  test("the relay announces the recipient to the directory", () =>
    givenTodo("c1:alice@x.y", item)
    ->whenTranslated
    ->thenCommand("c1", AnnounceRecipient({recipientId: "c1", email: "alice@x.y"}))
  )

  test("the relay calls no capability", () =>
    givenTodo("c1:alice@x.y", item)->whenTranslated->thenNothingSent
  )

  // Inventing a notification fact here would claim the directory knows an
  // address it does not; the sweep's Abandoned row is the honest record.
  test("an exhausted relay says nothing", () =>
    givenTodo("c1:alice@x.y", item)->whenExhausted->thenNoCommand
  )
})
