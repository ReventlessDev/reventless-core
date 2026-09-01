/**
The conformance suite, run by a host against its own graft. `Make(Binding).register()`
inside a Jest test file registers one `describe` block over the binding.

What it asserts is the competency, not the host: the directory, the fallback to
the host's posture, and — the part worth being strict about — that the three ways
to send nothing stay three different facts.
*/

/** The suite's title, composed once and read twice: the suite registers it,
    and `certify-trait` computes the same string to find the run's assertions in
    a test report. Exported rather than inlined so neither side parses the
    other's prose. */
let suiteName = (host: string) => `${host} conforms to the notification trait`

module Make = (B: Notification.Binding) => {
  module G = ReventlessGwt.Behavior_GWT.Make(B.Spec, B.Behavior)
  module R = Notification_Rules

  let announced = Array.concat(B.created, [B.announcedC(B.addressA)])

  let register = () =>
    G.describe(suiteName(B.Spec.name), () => {
      G.test("an announced contact is recorded", () =>
        G.givenEvents(B.created)->G.whenCmd(B.announce(B.addressA))->G.thenEvent(
          B.announced(B.addressA),
        )
      )

      // The relay re-announces on every contact event a host publishes, and its
      // row completes on the publish rather than on an event coming back — so
      // saying nothing is safe here, and recording a change that did not happen
      // is not.
      G.test("re-announcing the address already on file is a no-op", () =>
        G.givenEvents(announced)->G.whenCmd(B.announce(B.addressA))->G.thenNoEvent
      )

      G.test("a changed address is recorded", () =>
        G.givenEvents(announced)->G.whenCmd(B.announce(B.addressB))->G.thenEvent(
          B.announced(B.addressB),
        )
      )

      // A person is at the other end of this one, so they are told rather than
      // having a fact recorded about them.
      G.test("managing preferences for an unannounced recipient is refused", () =>
        G.givenEvents(B.created)
        ->G.whenCmd(B.subscribe(B.optional, B.announcedChannel))
        ->G.thenError(B.recipientUnknown)
      )

      G.test("opting in to a kind that is off by default is recorded", () =>
        G.givenEvents(announced)
        ->G.whenCmd(B.subscribe(B.optional, B.announcedChannel))
        ->G.thenEvent(B.subscribed(B.optional, B.announcedChannel))
      )

      // Already on by the host's posture. Recording a subscription would say the
      // recipient chose something they did not, and a later posture change would
      // then not reach them.
      G.test("subscribing to a kind already on by posture is a no-op", () =>
        G.givenEvents(announced)
        ->G.whenCmd(B.subscribe(B.transactional, B.announcedChannel))
        ->G.thenNoEvent
      )

      G.test("opting out of a kind that is on is recorded", () =>
        G.givenEvents(announced)
        ->G.whenCmd(B.unsubscribe(B.transactional, B.announcedChannel))
        ->G.thenEvent(B.unsubscribed(B.transactional, B.announcedChannel))
      )

      G.test("opting out of a kind already off is a no-op", () =>
        G.givenEvents(announced)
        ->G.whenCmd(B.unsubscribe(B.optional, B.announcedChannel))
        ->G.thenNoEvent
      )

      // The posture doing its job: somebody who has never seen a settings screen
      // still gets what they asked for by acting.
      G.test("a transactional request goes out with no explicit subscription", () =>
        G.givenEvents(announced)
        ->G.whenCmd(B.request(B.transactional, "ref-1"))
        ->G.thenEvent(
          B.requested(B.transactional, "ref-1", B.announcedChannel, B.addressA),
        )
      )

      G.test("the address on the request is the one currently on file", () =>
        G.givenEvents(Array.concat(announced, [B.announcedC(B.addressB)]))
        ->G.whenCmd(B.request(B.transactional, "ref-1"))
        ->G.thenEvent(B.requested(B.transactional, "ref-1", B.announcedChannel, B.addressB))
      )

      G.test("an optional request is suppressed with no explicit subscription", () =>
        G.givenEvents(announced)
        ->G.whenCmd(B.request(B.optional, "ref-2"))
        ->G.thenEvent(B.suppressed(B.optional, "ref-2"))
      )

      G.test("a recipient who opted out is suppressed", () =>
        G.givenEvents(
          Array.concat(announced, [B.unsubscribedC(B.transactional, B.announcedChannel)]),
        )
        ->G.whenCmd(B.request(B.transactional, "ref-3"))
        ->G.thenEvent(B.suppressed(B.transactional, "ref-3"))
      )

      // The case the directory exists for.
      G.test("a request for a recipient nobody announced is undeliverable", () =>
        G.givenEvents(B.created)
        ->G.whenCmd(B.request(B.transactional, "ref-4"))
        ->G.thenEvent(B.undeliverable(B.transactional, "ref-4"))
      )

      // Wanted, and unreachable — the distinction the whole `Undeliverable` arm
      // exists for. Skipped by a host that announces an address for every channel
      // it offers, because there is then no way to be in this state.
      switch B.unreachableChannel {
      | None => ()
      | Some(channel) =>
        G.test("a channel with no address on file is undeliverable, not suppressed", () =>
          G.givenEvents(
            Array.concat(
              announced,
              [
                B.subscribedC(B.transactional, channel),
                B.unsubscribedC(B.transactional, B.announcedChannel),
              ],
            ),
          )
          ->G.whenCmd(B.request(B.transactional, "ref-5"))
          ->G.thenEvent(B.undeliverable(B.transactional, "ref-5"))
        )
      }
    })
}
