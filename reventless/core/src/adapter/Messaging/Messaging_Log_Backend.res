// A logging messaging transport: accepts every message, delivers none, prints
// each one to the log.
//
// Provider-neutral and therefore here rather than beside either platform's own
// transport: both use it, and two copies would drift into two different ideas of
// what a logged send looks like. It is the counterpart to
// `Messaging_Ses_Backend` and deliberately the same shape — `channels` derived
// from the sender, `send` answering the shared `Messaging` vocabulary, `provider`
// closing over the sender. A slice reaches it through the injected capability
// record and cannot tell which one it got, which is the property that makes
// running a shop against it worth anything.
//
// **Accepting is the honest answer here, not a shortcut.** The alternative is
// `Capabilities.none`, which reports `Unavailable` — a *retryable* outage, so
// every notification is retried three times and then recorded as failed. A
// delivery view that is all failures teaches the wrong thing about a competency
// that works. Nothing leaves the process either way; the difference is only
// whether the outcome tells the truth about the domain.
//
// It refuses nothing a real provider would refuse, and that is the tradeoff to
// know: SES rejects a message with no subject, this does not, so a bug of that
// shape is caught on the real transport and not here.
//
// Runtime-pure: no Pulumi import, so it can be bundled into a Lambda entry point
// without dragging deploy-time modules into the cold-start graph.

let log = Logger.fromEnv()

/** Logged messages are numbered rather than given a random id: someone reading two
    log lines wants to know they are two messages, and a counter says so at a
    glance where a uuid does not. Per process, like the transport itself. */
let sent = ref(0)

/**
The channels this transport can attempt.

Derived from the sender exactly as SES derives it, so a platform that chose this
transport but named no address publishes the same empty list an unprovisioned
deployment does. SMS and push are absent for the same reason they are absent
there — no transport — and answer `UnsupportedChannel`, which is settled rather
than retried.
*/
let channels = (~sender: string): array<Reventless.Messaging.channel> =>
  sender == "" ? [] : [Email]

/** The message as it would have gone out, headers and all.

    The whole point of the transport: someone checking that a notification says the
    right thing needs the words, not a line saying words were sent. Rendered as
    one record rather than a line per header so two concurrent sends cannot
    interleave into one unreadable message. */
let render = (
  ~ref_: string,
  ~sender: string,
  ~to_: string,
  ~message: Reventless.Messaging.message,
) =>
  [
    `${ref_} — logged, not sent`,
    `  From:    ${sender}`,
    `  To:      ${to_}`,
    `  Subject: ${message.subject->Option.getOr("(none)")}`,
    "",
    message.body,
  ]->Array.join("\n")

/** Accept the message, print it, deliver nothing. */
let send = async (
  ~sender: string,
  ~recipient: Reventless.Messaging.recipient,
  ~message: Reventless.Messaging.message,
): result<Reventless.Messaging.receipt, Reventless.Messaging.failure> =>
  switch recipient {
  | ToSms(_) => Error(UnsupportedChannel(Sms))
  | ToPush(_) => Error(UnsupportedChannel(Push))
  | ToEmail(address) =>
    if sender == "" {
      // The wording an unprovisioned platform gave before this transport existed.
      // It is what lands in the delivery view's `detail`, and a platform that
      // provisions nothing should still read the way it always did.
      Error(Unavailable("no messaging provider is configured for this platform"))
    } else {
      sent := sent.contents + 1
      let ref_ = `log:${sent.contents->Int.toString}`
      log.info(
        ~comp="Messaging:Log",
        render(~ref_, ~sender, ~to_=address->Reventless.Email.toString, ~message),
      )
      Ok({ref: ref_})
    }
  }

/** The port, closed over the sender this platform was given. What a platform's
    capability record carries when logging is the chosen transport. */
let provider = (~sender: string): Reventless.Messaging.provider => {
  channels: channels(~sender),
  send: (~recipient, ~message) => send(~sender, ~recipient, ~message),
}
