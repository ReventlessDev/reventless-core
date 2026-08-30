# Plan: the Notification trait

**Date:** 2026-08-30
**Repo:** reventless-core — a new package under `traits/`, a new `Messaging` capability, and the
`online-shop-hybrid` ordering plugin.
**Status:** **Stub — blocked on capability-layer work, not on trait design.** The five-point spec for
this competency has been worked through independently and is settled enough to build against; what is
missing is an entire capability that does not exist. One design question (D1) has a recommendation
but no decision. Sequenced last of the three traits.
**Builds on:**
[domain-trait-extraction-online-shop-hybrid.md](./domain-trait-extraction-online-shop-hybrid.md)
Part 1 (the messaging capability — a hard dependency) ·
[trait-address-geocoding.md](./trait-address-geocoding.md) (retry-vs-verdict failure split, the
capability-port shape this copies)

---

## 1. Why this is last

Not because it is undesigned. Because it is the only one of the three whose **substrate does not
exist**:

- `Platform.capability` has exactly two arms today — `ObjectStore({plugin, store})` and `Geocoding`.
  There is no `Messaging` arm, no provisioner, no injected port, and no local dev implementation.
- Its shipped behaviour is a `console.log` stub in
  `examples/online-shop-hybrid/ordering/src/Service/EmailService.res` that ignores its injected
  capabilities, so this is not an extraction — there is nothing to strip.

Building it means designing the competency *and* a capability *and* the packaging in one motion,
which confuses a packaging failure with a design failure. That is what sequencing a real extraction
first avoids.

## 2. 🚨 Correction to carry forward — this trait does **not** write back to the host

Earlier planning had the `Order` aggregate gaining arms that record the outcome as domain facts
(`ConfirmationSent` / `ConfirmationFailed({reason})`, `@noApi` commands from the slice, mirroring
`SetLocation` / `MarkAddressUnresolvable`) plus a `confirmationStatus` field on the orders read model.

**That is the wrong shape for this competency.** Worked through independently, notification is
**host-side-effect-free**: it reads host events, and writes nothing back. There is no result command
and no obligation placed on the host at all. Delivery state and recipient preferences are the
*trait's* own, not the host's.

This matters beyond notification: it is the fork in the trait model. Geocoding writes back to its
host; notification does not. A trait contract generalised from the first two specimens alone would
have hard-coded write-back as universal and mis-modelled this one. Any host contract written here
must carry the write-back posture as an explicit flag, not an assumption.

**Consequence for this plan:** the `Order` arms and `confirmationStatus` above are struck. Do not
build them.

## 3. What the trait owns

Three components, of which one is shipped:

- **The send slice** — an outbound translation slice on the shipped slice/Task/schedule rails, with
  the retry-vs-verdict failure split that geocoding proved out (`Unavailable` retries, a provider
  refusal is a verdict).
- **A preferences entity — trait-owned, new.** A per-recipient component keyed by recipient id
  holding the kind × channel matrix plus the trait's default posture (`OptOut` for transactional
  kinds — notify unless they said no). This is the first trait that owns a domain component of its
  own rather than contributing arms to a host's.
- **A channel vocabulary and delivery-failure type** in spec.

## 4. D1 — the open question: the slice cannot resolve a recipient

`SendOrderConfirmation_Translation.res` calls its mailer with `~email=item.customerId` — a customer
id where an email address belongs. It is not a local typo: the slice consumes `OrderPlaced` off the
DCB log, which carries `customerId` and no contact detail of any kind, so **the slice cannot resolve
a recipient with what it has.**

The tension is sharpest against the `OptOut` posture: "notify unless they said no" means an
*unregistered* recipient must still be reachable, and for an unregistered recipient the trait holds
no address at all.

Three ways to close it:

1. **The preferences entity becomes the recipient registry** — the trait resolves id → channels +
   addresses from its own state. Cleanest against "keyed by recipient, never by host id", but it
   does not answer the unregistered-recipient case, so `OptOut` transactional kinds would silently
   send nothing.
2. **The host contract gains a resolution member** — the graft supplies
   `recipientOf: subject => promise<contact>`, satisfied by reading the host's own read model
   (`Customers.email` exists and is `@displayName`). **Recommended.** It puts the lookup where the
   knowledge is. It costs the tidy result that a trait grafts by reading host *events* alone — a
   resolution member means reading host *state* too, and no other specimen needs a query door.
3. **The host event carries the contact.** Cheapest and wrong, for the same reason `SetLocation`
   carries `resolvedFrom` rather than the address of record: it copies a mutable fact into an
   immutable log, so a customer who changes their email gets old orders confirmed to the old
   address.

**Decide before building.** It determines the host contract, which determines the package.

## 5. Capability-layer prerequisite

A trait `requires` capabilities; it never contains or provisions one. This trait's requirement is
unkept today and is the bulk of the work:

- a `Messaging` arm on `Platform.capability`
- an AWS provisioner (SES-backed, the way `Capability_ObjectStore_S3` and the geocoding capability
  helper are provisioned)
- a `send` port in spec — channel-neutral, with `Unavailable(string)` (retry) vs a refusal verdict
- a local captured-outbox implementation so the same slice code runs locally with observable output
- `Capabilities.t` gains the port; `Capabilities.none` answers `Unavailable`, keeping work queued and
  visible rather than silently dropped

⚠️ **The at-least-one-channel requirement is not enforceable today.** A trait that needs "≥1 of
{email, sms, push}" cannot be checked at deploy time or degraded at runtime unless a capability can
publish *which of its features a given platform actually provisioned*. Capabilities publish an
endpoint, not a feature-set. That is capability-layer work; either build it with the `Messaging` arm
or restrict the first version to a single required channel and say so.

## 6. Why it is still worth doing

It is the deepest of the three: port type in spec, provider adapter, capability extension,
retry-vs-verdict split, plus a trait-owned component — so it is the real test that the pattern
generalises rather than describing geocoding twice. Its outbound-delivery half is the reusable middle
of several further competencies (verification, reminders, alerting, digests, subscriptions).
