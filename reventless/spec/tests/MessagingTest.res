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
    testSync(
      "the channel is read off the value that carries the address",
      () =>
        expect(
          [
            Messaging.ToEmail(address("ops@example.com")),
            ToSms(Phone.unsafe("+15555550100")),
            ToPush(Apns({deviceToken: "abc"})),
          ]->Array.map(Messaging.channelOf),
        )->toEqual([Messaging.Email, Sms, Push]),
    )

    // Push is one channel and three provisionings, so the address carries the
    // discrimination the channel deliberately does not. A `WebPush` arm cannot be
    // built without its encryption keys — that half is the compiler's, and it is
    // why the arm is a record rather than the single string the field used to be.
    testSync(
      "a push address names the service that issued it",
      () =>
        expect(
          [
            Messaging.Apns({deviceToken: "abc"}),
            Fcm({registrationToken: "def"}),
            WebPush({endpoint: "https://push.example.com/s/1", p256dh: "key", auth: "secret"}),
          ]->Array.map(Messaging.serviceOf),
        )->toEqual([Messaging.ApnsService, FcmService, WebPushService]),
    )
  })

  describe("retriable", () => {
    testSync(
      "an outage is retried",
      () => expect(Messaging.retriable(Unavailable("connection reset")))->toBe(true),
    )

    // Not a fact about the recipient, but not one more attempts can change
    // either: provisioning a channel is a deploy, not a retry.
    testSync(
      "a channel this deployment does not run is not retried",
      () => expect(Messaging.retriable(UnsupportedChannel(Sms)))->toBe(false),
    )

    testSync(
      "a refusal is not retried",
      () => expect(Messaging.retriable(Refused("address on the suppression list")))->toBe(false),
    )

    // Settled for the same reason the channel is, one level down: provisioning a
    // second push service is a deploy, and the device is reachable only through
    // its own.
    testSync(
      "a push service this deployment does not provision is not retried",
      () => expect(Messaging.retriable(UnsupportedPushService(ApnsService)))->toBe(false),
    )
  })

  describe("failureReason", () => {
    testSync(
      "an unsupported channel says which one",
      () =>
        expect(Messaging.failureReason(UnsupportedChannel(Push))->String.includes("Push"))->toBe(
          true,
        ),
    )

    // Naming the service is the whole point of the arm: "no push" and "not that
    // push" read identically otherwise, and they are diagnosed differently.
    testSync(
      "an unsupported push service says which one",
      () =>
        expect(
          Messaging.failureReason(UnsupportedPushService(FcmService))->String.includes("FCM"),
        )->toBe(true),
    )
  })

  describe("supports", () => {
    let stub: Messaging.send = async (~recipient as _, ~message as _) => Error(Unavailable("stub"))

    let emailOnly = Messaging.makeProvider(~emailAndSms=[Email], ~pushServices=[], ~send=stub)

    testSync(
      "a provisioned channel is supported",
      () =>
        expect(emailOnly->Messaging.supports(~recipient=ToEmail(address("ops@example.com"))))->toBe(
          true,
        ),
    )

    testSync(
      "an unprovisioned channel is not",
      () =>
        expect(emailOnly->Messaging.supports(~recipient=ToSms(Phone.unsafe("+15555550100"))))->toBe(
          false,
        ),
    )

    // The unsoundness this replaced: `channelOf` answers `Push` for every push
    // address, so checking the channel would have called an APNs token supported on
    // a deployment holding only an FCM credential — and left the caller to discover
    // otherwise by spending a send.
    describe(
      "a push address is checked against its own service",
      () => {
        let fcmOnly = Messaging.makeProvider(
          ~emailAndSms=[Email],
          ~pushServices=[FcmService],
          ~send=stub,
        )

        testSync(
          "the provisioned service is supported",
          () =>
            expect(
              fcmOnly->Messaging.supports(~recipient=ToPush(Fcm({registrationToken: "def"}))),
            )->toBe(true),
        )

        testSync(
          "another service on the same channel is not",
          () =>
            expect(
              fcmOnly->Messaging.supports(~recipient=ToPush(Apns({deviceToken: "abc"}))),
            )->toBe(false),
        )
      },
    )
  })

  describe("makeProvider", () => {
    let stub: Messaging.send = async (~recipient as _, ~message as _) => Error(Unavailable("stub"))

    // `channels` is derived so the two published answers cannot disagree. A
    // transport that provisions no push service cannot offer a preference centre a
    // channel it would then refuse every send on.
    testSync(
      "no push service publishes no push channel",
      () =>
        expect(
          Messaging.makeProvider(~emailAndSms=[Email], ~pushServices=[], ~send=stub).channels,
        )->toEqual([Messaging.Email]),
    )

    testSync(
      "one push service publishes the channel",
      () =>
        expect(
          Messaging.makeProvider(
            ~emailAndSms=[Email],
            ~pushServices=[WebPushService],
            ~send=stub,
          ).channels,
        )->toEqual([Messaging.Email, Push]),
    )

    // Push presence is a function of `pushServices` and nothing else, so a `Push`
    // handed to the channel list is dropped rather than honoured.
    testSync(
      "a push channel claimed without a service behind it is dropped",
      () =>
        expect(
          Messaging.makeProvider(~emailAndSms=[Email, Push], ~pushServices=[], ~send=stub).channels,
        )->toEqual([Messaging.Email]),
    )
  })

  describe("Capabilities.none", () => {
    // Both halves matter, and they say different true things. An empty channel
    // list is what a preference surface renders — offering a channel nothing can
    // deliver on collects a subscription that never arrives.
    testSync(
      "publishes no channels",
      () => expect(Capabilities.none.messaging.channels)->toEqual([]),
    )

    // The finer answer says the same thing at the granularity push is provisioned
    // at, and a deployment that provisions nothing has to be empty on both.
    testSync(
      "publishes no push services",
      () => expect(Capabilities.none.messaging.pushServices)->toEqual([]),
    )

    // …while the send stays retryable: a caller that got this far is looking at
    // a deployment gap, not at a fact about the recipient, and abandoning the
    // message would record the second.
    test(
      "a send against it is a retryable outage, not a verdict",
      async () => {
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
      },
    )
  })
})

describe("Messaging.fromHeader", () => {
  // One formatter for every transport: SES applies it to a verified address, the
  // logging transport to a hard-coded one, and neither may present the same
  // deployment under a differently-escaped name.
  testSync("no display name leaves the address bare", () =>
    expect(Messaging.fromHeader(~displayName=None, ~address="mail@shop.test"))->toBe(
      "mail@shop.test",
    )
  )

  testSync("a display name is quoted in front of the address", () =>
    expect(
      Messaging.fromHeader(~displayName=Some("Online Shop"), ~address="mail@shop.test"),
    )->toBe(`"Online Shop" <mail@shop.test>`)
  )

  // Quoted unconditionally, so the names needing it are not exceptions somebody
  // has to remember: a comma alone splits the header into two addresses.
  testSync("a name carrying a comma stays one address", () =>
    expect(
      Messaging.fromHeader(~displayName=Some("Shop, Inc."), ~address="mail@shop.test"),
    )->toBe(`"Shop, Inc." <mail@shop.test>`)
  )

  testSync("quotes and backslashes in a name are escaped", () =>
    expect(
      Messaging.fromHeader(~displayName=Some(`The "Big" Shop\\Co`), ~address="mail@shop.test"),
    )->toBe(`"The \\"Big\\" Shop\\\\Co" <mail@shop.test>`)
  )
})
