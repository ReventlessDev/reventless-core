# @reventlessdev/trait-notification

A **domain trait**: telling somebody something happened. It holds a per-recipient
contact directory and a kind × channel subscription matrix, and decides — per
request — whether that becomes an addressed message, a suppression, or a record
that nobody could be reached. The rules are a module the host calls; the types are
the host's own:

| Part | Where |
|---|---|
| The competency's rules | `src/Notification_Rules.res` (`empty`, `op`, `fact`, `decide`, `evolve`, `addressFor`) |
| The host contract, as a type | `src/Notification.res` (`module type Binding`) |
| The conformance suite | `src/Notification_Conformance.res` (`Make(Binding).register()`) |
| The emitter | `src/Notification_Scaffold.res` (`emit(~config, ~into, ~tests)`) |

`Notification_Rules` is compiled code a host imports at runtime, so a change to it
is a behavior change for every host: version it `fix:`/`feat:` accordingly.

## What makes this one different

The first two traits add arms to something the host already had. This one **brings
its own components**: a StateChangeSlice, an outbound send, and two views, none of
which the host had before. So the emitter writes more than either of the others —
five files whole — and the host's part shrinks to two **relays**, which are printed
rather than written because what a host's events *mean* is the one thing a trait
cannot be told in names.

It also never writes to the host. Not one field, not one arm: the directory, the
matrix and the delivery log are all the trait's own state, so a host can graft this
onto components that have no opinion about mail at all.

## The rules it owns

- **The address is resolved when the message is composed, not when the occurrence
  happened.** A request names a recipient and a kind; the address comes off the
  directory at decision time. Putting it on the occurrence instead would freeze a
  mutable fact into an append-only log, and a recipient who changed their address
  would have old occurrences confirmed to the old one.
- **An absent choice falls back to a posture the host supplies.** The rule is the
  trait's; the table is not — whether an unheard-from recipient should be notified
  is per kind and per host, and a trait that hard-coded either answer would be
  wrong for half of them.
- **Three ways to send nothing, and they stay three facts.** A recipient who
  declined is `Suppressed`; one who enabled a channel nobody holds an address for
  is `Undeliverable`; one nobody announced is `Undeliverable` too. Collapsing the
  second into the first would hide every delivery gap behind a legitimate
  preference, permanently.
- **Announcing an address already on file appends nothing.** The relay that feeds
  it re-announces on every contact event a host publishes, and its row completes
  on the publish rather than on an event coming back — so the no-op is safe, and
  recording a change that did not happen would not be.

Delivery itself is the platform's: the send slice reaches
`Reventless.Capabilities.messaging`, declares the `Messaging` capability need, and
takes its retry split from `Reventless.Messaging.retriable`.

## Grafting a host

1. **Run the emitter.** Every `--key` is a field of its config, and it validates
   them, so a misspelled one is refused before anything is written.

   ```
   pnpm exec graft-trait @reventlessdev/trait-notification \
     --into src/Notification --tests tests/Notification \
     --chapter Notification --noun Recipient \
     --categories OrderConfirmation,ShippingUpdate,Marketing \
     --transactional OrderConfirmation,ShippingUpdate \
     --contactSource Customer --contactEvents Registered,EmailUpdated \
     --contactField email \
     --occurrence OrderPlaced --occurrenceId orderId \
     --occurrenceRecipient customerId --occurrenceCategory OrderConfirmation
   ```

2. **Write the two printed relays.** They arrive with their shape filled in and
   their meaning marked `TODO(graft)`: which of your events announce a contact,
   and what your notification actually says. The contact relay is an
   `OutboundTranslationSlice` rather than an automation on purpose — an
   automation's mapping is handed no source id, and an aggregate's event does not
   repeat the id that addressed it.

3. **Fill the emitted `TODO(graft)` markers.** The posture table, and the wording.
   Nothing else is left open.

4. **Provision a sender.** The send slice declares `Messaging`, so a deployment
   that provisions none fails the deploy rather than queueing every message until
   it is abandoned.

## What the suite checks, and what it does not

`Notification_Conformance` asserts the directory, the posture fallback, and the
three ways to send nothing. It says nothing about your wording, your
authorization, or what your views render — those are yours, and a rule the suite
covers must not also live in your own tests.

Two `Binding` members exist for the suite's sake and are worth reading before you
fill them: `transactional` and `optional` must be kinds whose posture actually
differs, and `unreachableChannel` is a channel your host announces no address for.
A host that announces every channel it offers passes `None` and two assertions are
skipped — which is the honest outcome, not a gap.

## Limits worth knowing

- **One address per channel.** An email is one address per person; a push token is
  one per *install*, and a set that churns. The directory's shape allows several
  channels but the announce path carries one address, so push is expressible and
  not yet reachable — a recipient who enables it is recorded `Undeliverable`
  rather than quietly skipped.
- **No dedupe on `reference`.** The relay upstream is a TODO list, which publishes
  once per item and resolves on the outcome. Keeping every reference ever seen in
  a snapshotted state to re-check that guarantee would cost more than it buys.
