/**
Sending a message to a person, and deciding whether to try again.

The transport is provider-specific and lives with its provider. What is here is
provider-neutral: who a message can be addressed to, what a send can answer, the
retry rule — decided once, so no transport invents its own.

## One value carries the channel and the address

A `(channel, address)` pair can be built wrong: `Sms` beside an email address
compiles and fails at the provider. `recipient` fuses them, so the wrong pair
does not exist, and the channel is read back off the value that carries it.
*/

/** A delivery route. The selector a recipient chooses per notification kind, and
    the granularity a platform provisions at. */
type channel =
  | Email
  | Sms
  | Push

/** An addressed recipient: the channel and the address it needs, inseparable.
    Each address is the branded scalar for its channel, so an unparseable one is
    refused where it is built rather than by the provider. */
type recipient =
  | ToEmail(Email.t)
  | ToSms(Phone.t)
  | /** The token the device registered with the push service. Opaque and
        provider-shaped — unlike an address, nobody else has a grammar for it. */
  ToPush({deviceToken: string})

/** The channel a recipient is addressed on. */
let channelOf = (recipient: recipient): channel =>
  switch recipient {
  | ToEmail(_) => Email
  | ToSms(_) => Sms
  | ToPush(_) => Push
  }

/** The channel's name, for a message a human reads and for a preference key. */
let channelToString = (channel: channel): string =>
  switch channel {
  | Email => "Email"
  | Sms => "Sms"
  | Push => "Push"
  }

/**
What to say.

`subject` is carried for the channels that have one — an email header, a push
notification's title — and ignored by those that do not. Optional rather than an
empty string, so "this message has no subject" and "its subject is blank" stay
distinguishable.
*/
type message = {subject?: string, body: string}

/** The provider accepted the message. `ref` is its own id for it — what a
    support conversation about a missing message is conducted with, and the only
    thing a caller can record that the provider will recognise. */
type receipt = {ref: string}

/**
Why a send produced no receipt.

Three constructors because the retry decision turns on the distinction, and
getting it wrong is expensive in both directions: retrying a refused address
burns the budget on an outcome that will not change, and abandoning a transient
outage writes off a message that would have gone.
*/
type failure =
  | /** The provider could not be reached, or refused the call. Retry. */
  Unavailable(string)
  | /** This deployment provisions nothing for this channel. Do not retry — no
        number of attempts provisions one. */
  UnsupportedChannel(channel)
  | /** The provider answered and will not take this message: an address it
        rejects, a recipient it suppresses. Do not retry. */
  Refused(string)

/** The retry rule, stated once. Everything that sweeps a failed send derives
    from it rather than re-reading the constructors. */
let retriable = (failure: failure): bool =>
  switch failure {
  | Unavailable(_) => true
  | UnsupportedChannel(_)
  | Refused(_) => false
  }

/** A reason for a human, for a caller that records the outcome rather than
    acting on it. */
let failureReason = (failure: failure): string =>
  switch failure {
  | Unavailable(reason) => reason
  | UnsupportedChannel(channel) =>
    `this deployment provisions no ${channel->channelToString} channel`
  | Refused(reason) => reason
  }

/**
The port a caller reaches a messaging provider through, so swapping the
implementation is a change of supplier rather than of call site.
*/
type send = (~recipient: recipient, ~message: message) => promise<result<receipt, failure>>

/**
The capability as a slice receives it: what can be attempted, and how.

`channels` is here because a recipient cannot be offered a choice the deployment
cannot honour. A platform provisions email only, or email and SMS; a preference
centre that listed all three would collect a subscription every send then answers
`UnsupportedChannel` for. Published rather than inferred from a failed send,
because discovering a channel by failing on it costs a real message.

Empty means no channel at all — the shape `none` takes, and the one a deploy-time
gate exists to catch before it ships.
*/
type provider = {
  channels: array<channel>,
  send: send,
}

/** Whether this provider can attempt a recipient's channel at all. The check a
    caller makes before spending a send, and the same rule the provider applies
    internally, so the two cannot disagree. */
let supports = (provider: provider, ~recipient: recipient): bool =>
  provider.channels->Array.includes(recipient->channelOf)
