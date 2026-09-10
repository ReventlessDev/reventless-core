# Plan: the ContactVerification trait

**Date:** 2026-09-10
**Status:** **Phase A ✅ complete 2026-09-10.** The vocabulary, the decision rules, the graft onto
`Customer`, the challenge ledger and the issue-and-send slice are all built in the ordering example —
202 tests there, with the staleness guard verified by deletion at *both* layers. The blocker it hit
(nothing in a plugin could produce a secret) was resolved by making one: `Secrets` is now a capability.
**Phase B (the registration chapter) and Phase C (extraction) not started.**
**Repos:** `reventless-core` only — the `online-shop-hybrid` ordering plugin it is written in, then a
new package under `traits/`.
**Builds on:** [trait-address-geocoding.md](./trait-address-geocoding.md) and
[trait-file-attachment.md](./trait-file-attachment.md) — the two extractions whose shape this follows ·
[domain-trait-extraction-online-shop-hybrid.md](./domain-trait-extraction-online-shop-hybrid.md)
(framework seams) · [identity-is-a-capability-not-a-cognito-handle.md](./identity-is-a-capability-not-a-cognito-handle.md)
— **not a dependency**; verification never calls it, and the two run in parallel.

**Goal.** An address on a host becomes proven-to-be-controlled, safely: one proof, expiring,
non-replayable, and dropped if the address changes underneath it.

**Non-goal.** Deciding *who may register* and *what a settled proof entitles*. That is host policy, it
does not survive a host swap, and keeping it out is what makes this a trait.

---

## Why this shape

The competency passes the trait test cleanly. Bind it to a `Customer`'s email, a `Supplier`'s contact
or an `Organization`'s billing address and the vocabulary is identical —
`challenge issued → proof presented → Verified | Expired | Superseded` — with the same policy knobs
meaning the same things. Only the contact being verified and the write-back target change.

It also lands on four framework cells nothing has occupied, which is the argument for building it as
the fourth specimen rather than a fifth of something already understood:

- **`WritesBack` and `SelfContained` were never exclusive.** The contract forked on
  `writeBack: WritesBack | SelfContained` after notification broke the two-specimen consensus.
  Verification is **both** — it writes an outcome onto the host *and* owns a challenge ledger. The fork
  is really two independent booleans, *writes to the host* and *brings components*, and the built
  specimens happen to occupy two of the four corners. Redrawing a contract member is something no
  specimen since the third has produced.
- **Trait-owned state that must not be projectable.** Every specimen's state is safe to project: a
  coordinate, a ref set, a delivery log. A challenge holds a secret (or its hash) and must be visible
  to `decide` and invisible to every read model. No contract member says "this state is not
  projectable", and the aggregate rule — *aggregate state stays host-owned, it is snapshotted* — points
  the same way from the other side: a token hash on a snapshotted host aggregate is a secret in a
  snapshot. This is the strongest technical reason the ledger must be trait-owned DCB state.
- **A door with its own authorization posture.** `SubmitProof` must be callable by someone not yet
  authenticated. A component that brings a door cannot declare that door's auth posture today.
- **Two verdicts, one from a capability and one from a human.** The outbound slice finishes at
  `Delivered` and the competency is still unfinished, waiting on an inbound command from the subject.
  No specimen has an inbound completion door. It also gives `onExhausted` a third answer: exhausting
  *delivery* retries is not a verdict on the *verification*, it is a reason to let the challenge expire
  normally.

## Vocabulary

```rescript
/** An ADDRESS, not a channel. Narrower than `Messaging.recipient` on purpose:
    a push token is not a claim anyone makes, so it is not a subject, and the
    wrong subject should not be constructible. Lifts into `Messaging.recipient`
    totally, for the send. */
type contact =
  | ByEmail(Email.t)
  | ByPhone(Phone.t)

/** Which channels an address is reachable over — one-to-many, which is why
    address and channel stay separate types. Intersected at runtime with what
    `Capabilities.messaging` publishes. */
let channelsFor: contact => array<Messaging.channel>
// ByEmail => [Email]     ByPhone => [Sms]

type subject = {contact: contact, purpose: purpose}
type purpose = Registration | ContactChange | Invitation | Recovery | Custom(string)

type outcome = Verified | Expired | Superseded | Abandoned

/** Keyed by `Messaging.channel` — not global, and not by `contact`. A
    32-character link with a 24-hour window is right for Email and unusable over
    Sms, where a human types the proof off a screen. Keying by contact instead
    would look identical today and hard-code one channel per address. */
type policy = {
  tokenTtl: Duration.t,
  maxAttempts: int,
  resendCooldown: Duration.t,
  proofLength: int,
  proofAlphabet: alphabet,
}
```

**`purpose` is the single most important decision in the trait.** The same machinery — issue a secret
to an address, expire it, accept it once — serves registration, a contact change, an invitation and a
password reset. Ship it without `purpose` and the next four consumers rebuild it. `Invitation` also
needs a payload (the role being granted) to ride along, so the challenge carries an opaque
`payload: option<JSON.t>` the host interprets and **the trait never reads**.

**Staleness token: `verifiedAddress`.** Structurally identical to geocoding's `resolvedFrom`, and the
first case where the guard is a **security control rather than a correctness one**. A proof arriving
for `alice@old.example` when the host's contact is `alice@new.example` must produce no host event —
without that guard, "change your email, then present the old address's token" is an account takeover.
Geocoding's staleness guard produces a stale coordinate; this one produces a breach. Not optional under
any host shape.

**Requires `Messaging` only, and with a modality the deploy gate cannot yet express.** Notification
needs "≥1 of {Email, Sms, Push} — any will do". Verification needs *the channel the subject
determines*: verifying an email address requires `Email` specifically, and no amount of SMS
provisioning satisfies it. So `{alternatives, min}` needs a second reading — the alternatives are not
always free to choose. A deployment provisioning push-only can run notification and cannot run email
verification.

**It must not require `Notification`.** A verification message is **transactional** and must not be
suppressible by a preference toggle. Routing it through notification would put it behind the preference
ledger, where a recipient who unsubscribed from "account" mail could no longer complete a signup. This
is also the second consumer showing that the *send* half and the *preference* half of notification are
genuinely separable.

## Channels: design over `{Email, Phone}`, build `Email`

`contact` is a two-arm variant from the first commit and `policy` is keyed by channel. That costs a
variant arm, a `channelsFor` and a keyed lookup now, and it is the difference between adding a channel
later and redesigning for one. Leave `ByPhone` as an arm the compiler points at.

Phone is a deliberate build rather than a free generalisation, for four reasons worth writing down
before anyone assumes otherwise — two about the SMS channel, two about the number:

1. **Cost turns an abuse problem into a fraud problem.** An unthrottled anonymous email door costs
   sender reputation; an unthrottled anonymous SMS door costs money per request to an attacker who
   profits from the traffic. See the unowned gap below.
2. **A verified number decays without the subject changing.** Carriers reassign numbers, so the contact
   stays byte-identical and comes to belong to someone else. The staleness token cannot help — nothing
   changed on the host to compare against. This is a **fifth framework parameter and the first one the
   framework cannot add a guard for**: what it implies is a verdict lifetime on the policy surface
   (`verifiedFor: option<Duration.t>`, `None` for email, months for a number) and a re-verification
   obligation the host schedules.
3. **The claim tag needs canonicalisation.** `+43 660 1234567`, `0660 1234567` and `00436601234567` are
   one number and three tags. E.164 normalisation must happen where the claim is written or uniqueness
   silently does not hold.
4. **The local platform has no SMS transport at all**, so a channel that works only on AWS breaks the
   local-first story.

**Admissibility is per `(purpose, channel)`, not per channel.** SMS is a reasonable proof that someone
can receive at a number and a weak basis for *account recovery* — SIM-swap is the standard attack. Note
the level: a swapped SIM captures the number, so it takes voice with it; the restriction is really on
the PSTN address, expressed at the finer channel grain. `Recovery` over `ByPhone` is a deployment's
decision, not the trait's to assume.

**Push is structurally excluded, not deferred.** A push token is not a claim anyone makes — it is
issued by the push service to one app install and relayed to the server over an already-authenticated
session. There is nothing to prove, and a challenge echoed back by the app proves only that the app is
reachable, which registering the token already proved. Push presupposes an authenticated session and so
cannot bootstrap one. An unbuilt `ByPush` arm would be worse than no arm, because "not yet" invites
someone to try.

## Expiry is lazy

Check expiry in `decide` against the challenge's `issuedAt` when the proof is presented — no scheduled
fire, no process-manager state, and therefore no brush with the "a competency needing multi-step
orchestration state has outgrown trait size" boundary. A sweep is still wanted, but only to
garbage-collect abandoned challenges and release their claim tags: a heartbeat, not a timer. Cheaper,
testable without clock control, and it keeps the trait inside its category.

---

## Phase A — the graft, in the ordering example

**Email-change verification on `Customer`. It blocks on nothing and can start today.**

`Customer` already carries `email`, `UpdateEmail` and `EmailUpdated`
(`Customer_Behavior.res`), including a no-op guard when the address is unchanged; `Email.t` ships;
`Messaging` ships with both an SES and a local log transport. Nothing in this phase needs an identity
provider, an unauthenticated door, a claim tag, a policy component or principal creation.

**Why this and not registration.** Registration has no host — it creates the subject the rest of the
system is about — so a trait extracted from registration alone would be built `SelfContained`-shaped
and the entire write-back half, **including the staleness guard that is this trait's security
control**, would never be exercised. There is no address to supersede in a flow creating the first one.
A trait whose hard half was never run is the failure mode already measured from the other direction:
the emitter reproduces its own specimen almost exactly and is untested everywhere else, and attachments
is the best-covered trait precisely because it has two hosts.

What Phase A exercises is exactly the part that is hard to get right: the staleness guard (change the
email while a challenge is open), the redelivery no-op, the stand-down, and lazy expiry. It grafts onto
the same aggregate geocoding already grafts onto, so it is a second graft on a host whose first graft is
known-good.

**One interaction to watch.** `EmailUpdated` already has a consumer — the notification graft's
`AnnounceRecipientContact_Translation`, whose directory keys on `${sourceId}:${email}`. An email change
mid-challenge therefore already produces a new directory row. Phase A's staleness guard lands directly
on that interaction, which makes it a better probe than a fresh aggregate would be.

**It is small enough to be a spike:** if the vocabulary above is wrong, that is discovered having
written one graft rather than a ~2,000-line package.

### Built 2026-09-10 — the rules, and what the spike changed

`ContactVerification` (vocabulary) and `ContactVerification_Guards` (decision rules) in the ordering
example, with 22 tests. The rules are pure and Pulumi-free, so extraction in Phase C is a move rather
than a rewrite.

**The staleness guard is wired, and that is asserted rather than claimed.** Removing the one branch
that compares the challenge's address to the host's turns two tests red. Given this plan's own position
— that a green certificate compatible with an unwired guard is worse than no certificate — a guard of
this kind should not be called done on a passing suite alone, and this one was not.

Three things the sketch above did not settle, decided while writing it:

- **Check order is part of the security control, not formatting.** Supersession is tested before
  expiry, settlement, attempts and the secret. A challenge that is *both* superseded and expired must
  be refused as superseded — reporting it as merely expired describes the harmless half of a dangerous
  state. The secret is compared last, so no structural refusal depends on it.
- **`policyFor` returns `option<policy>`, and `Push` is the `None`.** The plan argued push is
  structurally excluded; making that a missing arm rather than an unbuilt one is what stops "not yet"
  from inviting an implementation. The exclusion is now a value the compiler carries.
- **Issuance and resend are separate rules.** They were one idea in the sketch and are two decisions:
  a redelivered command must mint nothing (`AlreadyOpen`), while a person asking again past the
  cooldown re-sends **the same secret** (`Send`) — minting a fresh one would invalidate the link they
  are looking at while they read it. `TooSoon` carries the remaining wait so a host can say *when*
  rather than only *no*.

### The graft, built the same day

`Customer` gains `MarkEmailVerified` (unpublished), `EmailVerified`, and a `verifiedEmail` token whose
invariant matches geocoding's `locationResolvedFrom`: absent, or equal to the current address.
`EmailUpdated` drops it, in the fold and in the read model alike. 186 tests green in the example, eight
of them new.

**The staleness guard turned out to want two implementations, not one.** The plan described it as the
trait's security control, singular. Writing the graft made it clear that the ledger refusing to *settle*
and the aggregate refusing to *record* are different failures: a verdict can reach the host by
redelivery, by a replayed command, or from a ledger that is simply wrong, and only the aggregate's check
sits inside the host's own consistency boundary. Both are now present, and deleting **either** one turns
a test red — verified by doing it.

Two smaller decisions the graft forced:

- **The write-back command is not published.** A client never asserts that an address was proven; it
  presents a secret to the slice that issued one, and the slice reports the verdict. A public command
  would let any caller mark any address verified, which is the entire property being protected. Same
  `@noApi` reasoning as geocoding's `SetLocation`, and for a sharper reason.
- **The read model carries the outcome and never the challenge.** The plan argued the ledger must not be
  projectable because it holds a secret. The corollary is that the *verdict* projects freely — and must
  also be dropped on an address change, or a row shows an address as proven that nobody proved.

### The ledger, and the thing it ran into

`EmailVerificationChallenges` — a StateChangeSlice of its own, because an aggregate is snapshotted and
a secret held on `Customer` would be a secret in every backup of one. Commands carry a **hash**, never
the secret, so `decide` stays pure and replayable; a wrong answer is recorded as a *fact*, so the
attempt budget survives a replay rather than resetting on every rebuild. 194 tests green.

Building it moved two rules that had been written with one host in view:

- **`onIssueRequested` no longer takes host state.** A ledger has no host. Folding "is this address
  owed a proof" together with "is a secret already outstanding" read naturally for a contact change and
  stopped compiling the moment a second flow had no host at all. The stand-down (`contactToVerify`)
  stayed with whoever reads the host.
- **`onProofPresented` takes the held address as an `option`.** A registration has no subject yet, so
  there is nothing for its challenge to be superseded *by* — which is a different statement from
  skipping the check, and the type now says which one is meant.

Both are the WritesBack/SelfContained split this plan predicted, arriving a phase earlier than
expected — from the ledger rather than from the registration chapter.

## The blocker Phase A hit, and what it produced — resolved 2026-09-10

**The send half could not be built at all, and the reason was a missing seam rather than missing work.**

A `translate` is handed exactly one thing — `~capabilities: Reventless.Capabilities.t`. There is no
clock, no randomness and no hashing in it, and none anywhere else a plugin can reach: `Capabilities.t`
carries `geocode`, `messaging` and `identityProvider`; nothing in `reventless-spec` exposes a random
source (the two files matching "uuid" mention it only in prose); and no trait or example plugin uses
randomness at all. The single `Math.random()` in the tree is in a platform-side publish check, not in
plugin code.

So the outbound slice can compose the message and cannot produce what goes in it.

**`Math.random()` is not the answer, and taking it would be the exact defect this plan already names.**
Token entropy is listed here as one of the five failure modes that end in account takeover. A secret
drawn from a non-cryptographic PRNG is guessable, and it would be guessable behind a green test suite,
which is worse than an obvious gap.

**The seam has to be injected rather than imported, for a second reason beyond portability:** a
conformance suite cannot test issuance against an unpredictable secret. Injecting the generator is what
lets a test pin it, exactly as `geocoder(answer)` pins a geocode. An `external` binding to a runtime
global would work in production and leave the trait's issuance untestable — which is the shape this
plan already refuses in its publishing gate.

**Resolved by making it a capability.** `Secrets.t` — `randomToken(~length, ~alphabet)` and `hash` —
sits beside `geocode` / `messaging` / `identityProvider`, with a refusing `Capabilities.none` arm, a
shared Node backend, and `Secrets.fixed` for suites that need to know the secret in advance. The trait's
own `alphabet` type went away in favour of the capability's: it had been written before there was a
source to draw from, and one vocabulary for what a secret is made of belongs to the source that defines
it.

Two things that fell out of building it, both worth keeping:

- **No `CapabilityNeed` arm was added.** A need exists so a deploy can refuse when a deployment did not
  provision something; every runtime has a cryptographic source, so a gate over it could never fire.
  Adding one later is additive, whereas the record member is not — so waiting is the cheap direction.
- **A sampled test of the token distribution is worthless, and the first one written here was.** The
  Node backend rejects bytes rather than folding them with a modulo, because 256 is not a multiple of
  10 and the remainder would make six digits about four percent likelier each. The first test sampled
  20,000 draws for that skew — but it is only 0.609 against 0.600, a couple of standard errors, and the
  test **passed with the defence deleted**. It is now a named `accepts` predicate checked over every
  byte value, and deleting the defence turns two tests red. The general lesson is the one this plan
  already applies to the staleness guard: assert the rule, not a sample of its output.

## Phase A, complete

The issue-and-send slice draws a secret, sends it, and opens a challenge against its hash — in that
order, deliberately. Recording first and failing to send would open a challenge nobody can answer,
and the ledger would then refuse a second one for that address until the first lapsed. Done this way a
failed send records nothing, so the work stays outstanding and the sweep retries.

**`onExhausted` reports nothing, and that is the third answer this plan predicted.** A geocode records
"unresolvable" rather than leaving a row pending forever; there is no equivalent here, because an
address is not disproven by a mail transport that was down. Exhausting *delivery* retries is not a
verdict on the *verification*.

What Phase A now exercises, end to end: the staleness guard at both layers, the redelivery no-op, the
stand-down, lazy expiry, the attempt budget, the resend cooldown, and a send whose secret a test can
name in advance.

## Phase B — the second consumer

**Phase B is the registration chapter** ([self-registration-is-a-chapter-not-a-trait.md](./self-registration-is-a-chapter-not-a-trait.md)),
not a further graft. Two consumers and two purposes are what make the extracted emitter something other
than a copy of its only specimen, and this particular pair is better than two similar grafts would be:

| | Purpose | Corner it occupies |
|---|---|---|
| Phase A — email change on `Customer` | `ContactChange` | **WritesBack** — a host contact to supersede, the staleness guard live |
| Phase B — the registration chapter | `Registration` | **SelfContained** — no host, nothing to write back to |

Those are the two halves of the contract member this trait redraws. Extracting from Phase A alone would
emit a `WritesBack`-shaped trait whose self-contained arm is untested; extracting from registration
alone would do the reverse and leave the staleness guard — the security control — exercised by nothing.
**Neither is sufficient, which is why extraction waits for both.**

Phase B does not have to wait for Phase A to be *finished*, but it must not be built first: a trait
whose hard half was written second tends to be a trait whose hard half was retrofitted.

## Phase C — extract, writing the procedure down as you go

**The procedure is the deliverable, not a by-product.** All three shipped traits were extracted ad hoc
and the documented procedure that `Extractable` promises has never been written. A fourth extraction is
the chance to pay that debt by following it.

**Make extraction the exit condition of the work, not a follow-up.** The named failure mode for
example-first is not absorbing or packaging — it is *leaving it as example code that each project
re-derives*, and the history shows the risk is real: the traits were extracted eventually, the
procedure never was.

**Certification multiplies per contact arm, not per channel.** A host can carry several verified
contacts at once, so the write-back is per contact rather than a boolean. Attachments is certified
twice, `Many` and `Single`, because `cardinality` changes which commands exist and one specimen would
leave the other branch emitting untested code. This inherits that obligation — a second, independent
reason to ship one arm first rather than two half-certified ones.

**Do not publish until the certificate covers the door and the staleness guard.** `check:traits`
currently certifies 1 of notification's 7 components, and its own summary is that *"a green certificate
is compatible with a graft that cannot deliver a message."* For an attachment set that is an
embarrassment; for this trait a certificate compatible with a graft whose door is unthrottled and whose
staleness guard is unwired is **worse than no certificate, because it is a claim.**

## What it costs

Across the three shipped traits, **60% of all trait code is a program that prints ReScript** — 1,774
lines of rules, contract and conformance against 2,613 of scaffold — because a plugin cannot depend on
a component living in a package, so every declaration is re-materialised in the host's namespace.

This trait is notification-shaped or larger: a challenge ledger, two doors, a write-back graft and a
status read model. Expect **~800–1,000 lines of trait proper and ~1,200–1,500 of scaffold**. That makes
it the largest single item on the roster, and it is worth saying plainly rather than discovering at the
end. Separately, 222 lines of notification's output are printed for a human to place by hand for a
reason that does not apply to them; this trait's components are new files in the same way, so that fix
should be taken **before** this trait rather than after.

## The unowned gap: unauthenticated rate limiting

Attempt counts per challenge are ordinary event-sourced state and belong in `decide`. *Unauthenticated
request* throttling — "at most three registrations per IP per hour" — is a transport concern with no
framework expression: WAF or AppSync throttling on AWS, nothing at all locally. **The trait cannot close
this and must name it in its README rather than let a consumer assume it.** It stops being hygiene the
moment either an SMS channel or a publicly reachable door ships.

## Risks

- **This is the first trait where a bug is a vulnerability.** Enumeration, token entropy, timing,
  replay and the staleness window are correctness properties whose failure mode is an account takeover
  rather than a wrong badge. That raises the bar on the conformance suite, and current certification
  coverage does not clear it.
- **The build order says something else.** The ranked next move is extracting `OutboundDelivery` and
  `PreferenceLedger` out of notification; this is built against `Messaging` directly instead. That is
  defensible — it supplies the second consumer justifying that extraction — but the inversion is
  deliberate, and if the primitives are extracted later this is one of the things re-pointed at them.
- **A deployment should be able to skip the trait entirely** and use provider-native verification. The
  cost of domain-owned verification is real: hosted-UI signup, the provider's own confirmation mail and
  its password-reset flow all become unavailable or must be turned off, and a team deploying only on
  AWS pays for portability it will not use.

## Verification

- The staleness guard: a proof for the previous address after `EmailUpdated` produces **no host event**.
  This is the security test, and it is the one that must exist before anything else.
- Replay: a settled proof presented twice settles once.
- Lazy expiry: a proof after `tokenTtl` yields `Expired` with no scheduled fire and no clock control in
  the test.
- Stand-down: `contactToVerify` answering `None` spends no capability call.
- Redelivery no-op and the resend cooldown.
- `Capabilities.none` and an email-less provider both refuse without the graft inventing a verdict.
- Full build warning-free, whole suite green, no `.res.mjs` deletions.

## Honesty ledger

- **Read off code:** `Customer_Behavior.res` carrying `UpdateEmail` / `EmailUpdated` and its
  unchanged-email no-op; `AnnounceRecipientContact_Translation` consuming `EmailUpdated` and keying its
  directory on `${sourceId}:${email}`; `Messaging`'s `channel` / `recipient` / `provider` /
  `makeProvider` / `supports`; `Capabilities.t` and `Capabilities.none`; `CapabilityNeed.t`'s two arms;
  the three trait packages' `capabilityNeeds` and `module type Binding` shape.
- **Read off prior measurement, re-quoted rather than re-run:** the 60% scaffold ratio, the 1,774 /
  2,613 line counts, `check:traits` certifying 1 of 7 components, and the 222 hand-placed lines.
- **Design proposal, not validated:** every ReScript block here is illustrative shape, not code that
  compiles. `purpose` / `payload`, lazy expiry and the verdict-lifetime parameter are argued from three
  built specimens and one unbuilt one, subject to the standing warning that a fourth specimen can invert
  which half was load-bearing.
- **Asserted from outside this repo:** that SIM-swap is the standard attack on SMS-based recovery and
  that SMS and voice OTP are restricted as out-of-band authenticators. Well established, unmeasured
  here.
- **Not investigated:** the UI half — what a verification form looks like, and what an unauthenticated
  route does with a half-completed flow.
