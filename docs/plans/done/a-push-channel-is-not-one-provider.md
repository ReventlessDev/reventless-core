# Plan: a push channel is not one provider

**Date:** 2026-09-09
**Status:** Done — 2026-09-10. All five steps. See *Outcome* at the foot for the two decisions the
plan left to implementation and the one place it named the wrong file. Found by reading
`Messaging.res` against its own definition of a channel. Nothing depended on it because no transport
implements `Push` — which is exactly the window in which it was nearly free to fix.
**Repos:** `reventless-core` only.

**Goal.** Make `Messaging` able to address a push recipient truthfully: the address shape the push
services actually issue, and a `supports` answer that means what it says.

**Non-goal.** Building a push transport. This plan makes the vocabulary right so that the first one
can be written against it; it writes none, and no step here makes a deployment able to send push.

---

## The gap

`Messaging.res` defines a channel as two things at once:

> A delivery route. The selector a recipient chooses per notification kind, and the granularity a
> platform provisions at.

Push satisfies the first reading and fails the second.

- **As a selector**, push is one thing. Nobody chooses APNs over FCM; a recipient ticks "push" and the
  app already knows its own token.
- **As a provisioning granularity**, push is three or more. APNs takes a signing key, a team id and a
  bundle id; FCM takes a service-account credential; Web Push takes a VAPID keypair. Provisioning one
  gives you none of the others, and they fail independently.

Email has no such split — one sender provisioning reaches every mailbox, because SMTP routes off the
address. Push has no routing layer: which service can reach a device is fixed by *which credential you
hold*, and there is nothing in the address to route on.

Two consequences follow, and neither is observable today.

**1. `supports` is unsound for push.**

```rescript
let supports = (provider: provider, ~recipient: recipient): bool =>
  provider.channels->Array.includes(recipient->channelOf)
```

`channelOf(ToPush(_))` is `Push` unconditionally, so this answers `true` for an APNs token on a
deployment that provisioned FCM only. The comment a few lines above states the property being lost —
*"Published rather than inferred from a failed send, because discovering a channel by failing on it
costs a real message."* For push, inferring by failing is precisely what a caller is left doing.

**2. The address type cannot hold a Web Push subscription.**

```rescript
| ToPush({deviceToken: string})
```

Web Push addresses a *subscription*: an endpoint URL plus the `p256dh` and `auth` keys used to encrypt
the payload — three fields, not one. The field's own comment says the token is *"Opaque and
provider-shaped — unlike an address, nobody else has a grammar for it"*. That is true of APNs and FCM
and false of Web Push, which has a published grammar and is the one variant a browser produces.

**Why it is cheap now.** `Messaging_Log_Backend` publishes `[Email]` at most, `Messaging_Ses_Backend`
answers `UnsupportedChannel(Push)`, and `recipient` carries no `@schema` and no `Semantic.Id` — it is
runtime port vocabulary, so changing a variant payload is a compile error, not a stored-data
migration.

**Except in one place, and that is the deadline.** `Notification_Scaffold` stores a recipient
*un-fused*, as a channel plus a flat `address: string`, and re-fuses it on send:

```rescript
| Push => Ok(Reventless.Messaging.ToPush({deviceToken: item.address}))
```

That round-trips for email and SMS because their addresses are single strings. It cannot round-trip a
Web Push subscription through one column. So the trait's recipient directory is the stored shape this
plan is racing, and it is worth noting that un-fusing is the move `Messaging.res`'s opening paragraph
exists to forbid — *"a `(channel, address)` pair can be built wrong… `recipient` fuses them, so the
wrong pair does not exist"* — reintroduced at the storage boundary.

## What deliberately does not change

**`channel` keeps three arms.** Splitting `Push` into `Apns | Fcm | WebPush` would fix `supports` and
break the selector: a preference centre would offer a person a choice between notification services,
which is not a choice anyone has or wants. The discrimination belongs on the *address* and on what a
provider *publishes*, not on the channel a human picks. Keeping those apart is the whole point.

---

## Step 1 — the push address becomes a variant

In `reventless/spec/src/semantic/Messaging.res`:

```rescript
/** How a push service names one install. A variant rather than a string because
    the shapes differ: two services issue an opaque token, Web Push issues a
    subscription whose encryption keys are part of the address. */
type pushAddress =
  | Apns({deviceToken: string})
  | Fcm({registrationToken: string})
  /** The endpoint is where it goes; the keys are how it is sealed. Requiring
      them here keeps an unsendable subscription unconstructible. */
  | WebPush({endpoint: string, p256dh: string, auth: string})

/** Which service issued an address — the granularity push is provisioned at. */
type pushService = ApnsService | FcmService | WebPushService

let serviceOf: pushAddress => pushService
```

and `ToPush({deviceToken: string})` becomes `ToPush(pushAddress)`. This applies the file's existing
rule one level down: the wrong (service, address) pair stops being constructible for the same reason
the wrong (channel, address) pair already is.

## Step 2 — a provider publishes what it can reach

`channels` answers the selector question and must keep doing so. Add the provisioning answer beside
it, and derive `channels` so the two cannot disagree:

```rescript
type provider = {
  channels: array<channel>,          // what a preference centre may offer
  pushServices: array<pushService>,  // non-empty iff `channels` includes Push
  send: send,
}

let supports = (provider: provider, ~recipient: recipient): bool =>
  switch recipient {
  | ToPush(address) => provider.pushServices->Array.includes(address->serviceOf)
  | recipient => provider.channels->Array.includes(recipient->channelOf)
  }
```

**Decision to take at implementation.** The `non-empty iff` invariant is stated in a comment above,
which is where invariants go to die. Prefer a `makeProvider` smart constructor that takes
`(~emailAndSms, ~pushServices, ~send)` and *derives* `channels`, appending `Push` exactly when
`pushServices` is non-empty — then the invariant holds by construction and no backend can publish
`Push` with nothing behind it. Cost is one constructor and touching both existing providers; take it
unless it fights the record's use as a plain injected value.

## Step 3 — both transports state push honestly

Mechanical: `Messaging_Log_Backend.provider` and `Messaging_Ses_Backend.provider` gain
`pushServices: []`. Their `UnsupportedChannel(Push)` arms stay correct and unchanged. If Step 2 takes
the smart constructor, both go through it instead.

## Step 4 — the failure vocabulary gains the finer refusal

`UnsupportedChannel(Push)` becomes ambiguous once a deployment can provision *some* push: it would
have to mean both "no push at all" and "not that service". Add one arm:

```rescript
/** This deployment provisions push, but not the service that issued this
    address. Do not retry — the device is reachable only through its own. */
| UnsupportedPushService(pushService)
```

`retriable` returns `false` for it, beside the other two settled arms. `failureReason` renders it
naming the service, because that string is what a support conversation about a missing notification is
conducted with. Small, and the alternative is a message that misleads exactly when someone is
debugging a half-provisioned deployment.

## Step 5 — the guide says what a capability publishes

`docs/guides/platform-capabilities.md` currently says nothing about messaging channels. Add a short
section stating the general rule this work discovers, since it is not specific to messaging: **a
capability publishes what it can reach, at the granularity a caller must choose at — and when those
two granularities differ, it publishes both.** Push is the worked example; the shape recurs anywhere
one selector is served by several independently provisioned providers.

## Verification

- `MessagingTest` gains: `supports` is `false` for an `Apns` address against an FCM-only provider;
  `Capabilities.none` publishes no push services; a `WebPush` address cannot be built without its keys.
- The existing assertions must stay green untouched — `channels: [Email]` and
  `Capabilities.none.messaging.channels` equal to `[]`.
- `Notification_Scaffold`'s generated `recipientFor` compiles against the new arm. Its `Push` case
  cannot be written correctly from a flat `address: string`, so this step either changes the directory's
  stored shape or the scaffold refuses `Push` explicitly and says why. **Decide that before Step 1**,
  because it is the only part of this plan with a stored shape behind it.
- Full build warning-free, whole suite green, and the AWS `Capability_MessagingTest` rebuilt.

## Honesty ledger

- **Read off code:** `channel` / `recipient` / `provider` / `supports` / `failure` / `retriable` and
  the doc comments quoted above, all in `reventless/spec/src/semantic/Messaging.res`; both backends'
  `channels` derivation and their `UnsupportedChannel(Push)` arms; `Notification_Scaffold`'s
  `recipientFor` emitting `ToPush({deviceToken: item.address})`; the absence of any `@schema` or
  `Semantic.Id` on the messaging types; `MessagingTest`'s two channel assertions.
- **Asserted from outside knowledge, not probed here — verify before Step 1:** the credential shapes
  per service, and that a Web Push subscription is (endpoint, `p256dh`, `auth`). Both are
  well-established and neither is measured in this repo; confirm against whichever SDK the first push
  transport uses, because that is what fixes the arms' payloads.
- **Not investigated:** whether routing push through a fan-out service that registers a token and
  returns its own endpoint id would collapse the discriminator back to one arm on a given platform. If
  a deployment always went that way, the service distinction would move to provisioning time and
  Step 2's shape would change — Step 1's would not, which is a mild argument for doing Step 1 first
  regardless.

---

## Outcome

All five steps landed. Whole suite green (400 suites, 4352 tests), build warning-free, and every
`check:*` gate passing including `check:traits`, which rebuilds the notification trait's specimen host
from a packed tarball.

**Decision 1 — the smart constructor was taken.** `Messaging.makeProvider(~emailAndSms, ~pushServices,
~send)` derives `channels`, appending `Push` exactly when `pushServices` is non-empty, so the
`non-empty iff` invariant holds by construction rather than in a comment. It did not fight the
record's use as an injected value: consumers still read `provider.channels` and `provider.send`
directly, and only the four construction sites changed (`Capabilities.none`, both backends, the
`SendNotification_GWT` stub). A `Push` passed in `emailAndSms` is dropped rather than honoured, and
the switch that drops it is exhaustive — so a fourth channel arrives here as a compile error.

One cost worth recording: `Capabilities.none` is now computed by a call at module init, so
`Capabilities.res.mjs`'s footer went from `No side effect` to `none Not a pure module`. `Messaging` is
runtime-pure vocabulary with no infra dependency and was already in every entry point's graph, so no
cold-start weight was added. The alternative was a record literal that could publish `Push` with
nothing behind it, which is the whole point of the constructor.

**Decision 2 — the trait's directory keeps its stored shape, and the scaffold refuses `Push`.** The
plan asked for this before Step 1. The directory stores `(channel, address: string)`, and the flat
column is not the only obstacle: **it does not record which service issued the token either**, so
even the two opaque-token arms cannot be re-fused from it. Widening the stored event to hold a
subscription that no transport will read would be speculative storage for a channel nothing can send
on — against the plan's own non-goal. So `recipientFor`'s `Push` arm returns `Error` naming the
reason, which the existing `translate` path already routes to a non-retryable delivery failure whose
comment says exactly the right thing: *the row that holds it needs fixing*. A push transport arrives
with the stored shape it needs, in the commit that justifies the columns. Changed in
`Notification_Scaffold`'s template and in the generated
[`SendNotification_Translation.res`](../../examples/online-shop-hybrid/ordering/src/Notification/OutboundTranslation/SendNotification_Translation.res)
together, with a GWT test asserting the provider is never asked.

**Step 5 named the wrong file.** `docs/guides/platform-capabilities.md` is a superseded copy from
August, referenced by nothing but this plan, and with no messaging section at all. The live published
guide is [`packages/doc/docs-app/platform-capabilities.md`](../../packages/doc/docs-app/platform-capabilities.md),
which already carried *Messaging channels* — so the general rule went there, beside the section it
generalises, together with a new *Push is one channel and three provisionings* subsection and the
paragraph on what un-fusing a recipient costs the trait's directory. The stale copy was left alone
rather than given a messaging section it never had.

**Ledger item resolved, partly.** The Web Push subscription shape is `endpoint` plus `keys.p256dh` and
`keys.auth` — `PushSubscription.toJSON()`'s own shape, per RFC 8291. Still **not probed in this
repo**: there is no `web-push`, APNs or FCM dependency anywhere in the workspace to confirm against,
so the arms' payloads remain read off the specs rather than off an SDK. The first push transport
should re-check them against whichever client it picks; that is a change to three inline records and
`serviceOf`, and nothing downstream of them.
