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
/**
A delivery route. The selector a recipient chooses per notification kind.

Three arms, and push stays one of them even though it is provisioned three ways.
Splitting it would offer a person a choice between notification services, which is
not a choice anyone has: an app knows its own token, and nobody prefers APNs. The
service-level discrimination lives on the address and on what a provider
publishes — see `pushService`.
*/
type channel =
  | Email
  | Sms
  | Push

/**
How a push service names one install.

A variant rather than a string because the shapes differ: two services issue an
opaque token, and Web Push issues a subscription whose encryption keys are part of
the address. This applies the rule the file opens with one level down — the wrong
(service, address) pair stops being constructible for the same reason the wrong
(channel, address) pair already is.
*/
type pushAddress =
  | Apns({deviceToken: string})
  | Fcm({registrationToken: string})
  /** The endpoint is where it goes; the keys are how it is sealed. Requiring them
        here keeps an unsendable subscription unconstructible. */
  | WebPush({endpoint: string, p256dh: string, auth: string})

/**
Which service issued an address — the granularity push is provisioned at.

Email needs no such type: one sender provisioning reaches every mailbox, because
SMTP routes off the address. Push has no routing layer, so which service can reach
a device is fixed by which credential the deployment holds, and there is nothing
in the address to route on.
*/
type pushService =
  /** Apple Push Notification service. Provisioned with a signing key, the team id
        that issued it and the app's bundle id. */
  | ApnsService
  /** Firebase Cloud Messaging, Google's. Provisioned with one service-account
        credential. */
  | FcmService
  /** Standardised rather than vendor-run: the endpoint the browser hands out is
        itself the service, so one VAPID keypair provisions all of them. */
  | WebPushService

/** An addressed recipient: the channel and the address it needs, inseparable.
    Email and SMS carry the branded scalar for their channel, so an unparseable one
    is refused where it is built rather than by the provider; push carries the
    variant its services issue, and the same property holds by construction. */
type recipient =
  | ToEmail(Email.t)
  | ToSms(Phone.t)
  /** How one install is reached. Not a bare string: the two token services and
        Web Push do not share a shape, and Web Push is not opaque. */
  | ToPush(pushAddress)

/** The service that issued a push address. What a provider's published list is
    checked against, so a token is never handed to the service that cannot use
    it. */
let serviceOf = (address: pushAddress): pushService =>
  switch address {
  | Apns(_) => ApnsService
  | Fcm(_) => FcmService
  | WebPush(_) => WebPushService
  }

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

/** The service's name as its own documentation spells it, because that is the
    word a support conversation about a missing notification is conducted with. */
let pushServiceToString = (service: pushService): string =>
  switch service {
  | ApnsService => "APNs"
  | FcmService => "FCM"
  | WebPushService => "Web Push"
  }

/**
The `From:` header a deployment's email sender presents as: the bare address, or
a display name in front of it.

Provider-neutral for the reason everything else here is — the header is the
RFC's, not a transport's, and two backends formatting it apart would present the
same deployment under two names. It is applied where the sender is *provisioned*
rather than at the send, so a transport receives one string and never has to know
whether a name was configured.

Quoted and escaped unconditionally rather than only when the name looks like it
needs it. The unquoted form excludes characters an ordinary shop name carries — a
comma above all, which would otherwise split the header into two addresses — and a
rule applied only where it looks necessary is a rule that gets the exceptions
wrong.
*/
let fromHeader = (~displayName: option<string>, ~address: string): string =>
  switch displayName {
  | None => address
  | Some(name) =>
    let escaped = name->String.replaceAll("\\", "\\\\")->String.replaceAll("\"", "\\\"")
    `"${escaped}" <${address}>`
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

The retry decision turns on the distinction, and getting it wrong is expensive in
both directions: retrying a refused address burns the budget on an outcome that
will not change, and abandoning a transient outage writes off a message that would
have gone.

Push needs its own refusal because it is provisioned per service. Once a
deployment can provision *some* push, `UnsupportedChannel(Push)` would have to
mean both "no push at all" and "not that service", and the two read the same to
someone debugging a half-provisioned deployment.
*/
type failure =
  /** The provider could not be reached, or refused the call. Retry. */
  | Unavailable(string)
  /** This deployment provisions nothing for this channel. Do not retry — no
        number of attempts provisions one. */
  | UnsupportedChannel(channel)
  /** This deployment provisions push, but not the service that issued this
        address. Do not retry — the device is reachable only through its own. */
  | UnsupportedPushService(pushService)
  /** The provider answered and will not take this message: an address it
        rejects, a recipient it suppresses. Do not retry. */
  | Refused(string)

/** The retry rule, stated once. Everything that sweeps a failed send derives
    from it rather than re-reading the constructors. */
let retriable = (failure: failure): bool =>
  switch failure {
  | Unavailable(_) => true
  | UnsupportedChannel(_)
  | UnsupportedPushService(_)
  | Refused(_) => false
  }

/** A reason for a human, for a caller that records the outcome rather than
    acting on it. */
let failureReason = (failure: failure): string =>
  switch failure {
  | Unavailable(reason) => reason
  | UnsupportedChannel(channel) =>
    `this deployment provisions no ${channel->channelToString} channel`
  | UnsupportedPushService(service) =>
    `this deployment provisions push, but not ${service->pushServiceToString}`
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

`pushServices` is the second answer, at the granularity push is actually
provisioned at. Both are published because the two granularities differ: a
preference centre reads `channels` because a person picks a channel, and `supports`
reads `pushServices` because a token is only reachable through its own service.
Build one through `makeProvider`, which derives the first from the second.
*/
type provider = {
  channels: array<channel>,
  pushServices: array<pushService>,
  send: send,
}

/**
Build a provider whose two published answers cannot disagree.

`channels` is derived rather than given: `Push` appears exactly when a push service
is behind it, so no transport can publish a channel with nothing to reach it on.
The alternative is that invariant stated in a comment beside two independently
written fields, which is where invariants go to die.

`emailAndSms` carries the channels the channel itself settles reachability for. A
`Push` passed there is dropped — `pushServices` is the only thing that provisions
push — and the switch doing the dropping is exhaustive, so a fourth channel arrives
here as a compile error rather than as a silent omission.
*/
let makeProvider = (
  ~emailAndSms: array<channel>,
  ~pushServices: array<pushService>,
  ~send: send,
): provider => {
  channels: emailAndSms
  ->Array.filter(channel =>
    switch channel {
    | Email
    | Sms => true
    | Push => false
    }
  )
  ->Array.concat(pushServices->Array.length == 0 ? [] : [Push]),
  pushServices,
  send,
}

/**
Whether this provider can attempt this recipient at all. The check a caller makes
before spending a send, and the same rule the provider applies internally, so the
two cannot disagree.

Push is checked against the issuing service, not against the channel. Answering off
`channels` would return `true` for an APNs token on a deployment that provisioned
FCM only — and inferring a channel by failing on it is exactly what publishing the
list exists to avoid, since a failed send costs a real message.
*/
let supports = (provider: provider, ~recipient: recipient): bool =>
  switch recipient {
  | ToPush(address) => provider.pushServices->Array.includes(address->serviceOf)
  | recipient => provider.channels->Array.includes(recipient->channelOf)
  }
