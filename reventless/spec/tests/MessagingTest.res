// The provider-neutral half of the messaging capability: who a message can be
// addressed to, which failures are worth retrying, and what a deployment that
// provisions nothing says about itself.
//
// Every transport derives its retry behaviour from `retriable`, so getting these
// wrong is expensive in both directions — retrying a refused address burns the
// budget on an outcome that will not change, and abandoning a transient outage
// writes off a message that would have gone.

open JestGlobals

let address = (raw): Email.t =>
  switch Email.fromString(raw) {
  | Ok(email) => email
  | Error(reason) => JsError.panic(reason)
  }

describe("Messaging", () => {
  describe("recipient", () => {
    // The reason `recipient` fuses the channel with the address: a separate
    // `(channel, address)` pair can name one and carry the other, and nothing
    // but the provider would notice.
    testSync("the channel is read off the value that carries the address", () =>
      expect([
        Messaging.ToEmail(address("ops@example.com")),
        ToSms(Phone.unsafe("+15555550100")),
        ToPush({deviceToken: "abc"}),
      ]->Array.map(Messaging.channelOf))->toEqual([Messaging.Email, Sms, Push])
    )
  })

  describe("retriable", () => {
    testSync("an outage is retried", () =>
      expect(Messaging.retriable(Unavailable("connection reset")))->toBe(true)
    )

    // Not a fact about the recipient, but not one more attempts can change
    // either: provisioning a channel is a deploy, not a retry.
    testSync("a channel this deployment does not run is not retried", () =>
      expect(Messaging.retriable(UnsupportedChannel(Sms)))->toBe(false)
    )

    testSync("a refusal is not retried", () =>
      expect(Messaging.retriable(Refused("address on the suppression list")))->toBe(false)
    )
  })

  describe("failureReason", () => {
    testSync("an unsupported channel says which one", () =>
      expect(Messaging.failureReason(UnsupportedChannel(Push))->String.includes("Push"))->toBe(true)
    )
  })

  describe("supports", () => {
    let emailOnly: Messaging.provider = {
      channels: [Email],
      send: async (~recipient as _, ~message as _) => Error(Unavailable("stub")),
    }

    testSync("a provisioned channel is supported", () =>
      expect(emailOnly->Messaging.supports(~recipient=ToEmail(address("ops@example.com"))))->toBe(
        true,
      )
    )

    testSync("an unprovisioned channel is not", () =>
      expect(emailOnly->Messaging.supports(~recipient=ToSms(Phone.unsafe("+15555550100"))))->toBe(
        false,
      )
    )
  })

  describe("Capabilities.none", () => {
    // Both halves matter, and they say different true things. An empty channel
    // list is what a preference surface renders — offering a channel nothing can
    // deliver on collects a subscription that never arrives.
    testSync("publishes no channels", () =>
      expect(Capabilities.none.messaging.channels)->toEqual([])
    )

    // …while the send stays retryable: a caller that got this far is looking at
    // a deployment gap, not at a fact about the recipient, and abandoning the
    // message would record the second.
    test("a send against it is a retryable outage, not a verdict", async () => {
      let outcome = await Capabilities.none.messaging.send(
        ~recipient=ToEmail(address("ops@example.com")),
        ~message={subject: "Order confirmed", body: "Thanks."},
      )
      expect(
        switch outcome {
        | Error(failure) => Messaging.retriable(failure)
        | Ok(_) => false
        },
      )->toBe(true)
    })
  })
})
