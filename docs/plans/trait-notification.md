# Plan: the Notification trait

**Date:** 2026-08-30
**Repo:** reventless-core — a new package under `traits/`, a new `Messaging` capability, and the
`online-shop-hybrid` ordering plugin.
**Status:** **Part 1 DELIVERED. Part 2 is the open work.** Everything §1–§6 called blocking has
shipped — see the correction box below. Part 2 turns the competency's wording from code into data,
and lets a deployment compose from a configured table instead of the compiled one.
**Builds on:**
[domain-trait-extraction-online-shop-hybrid.md](./domain-trait-extraction-online-shop-hybrid.md)
Part 1 (the messaging capability — a hard dependency) ·
[trait-address-geocoding.md](./trait-address-geocoding.md) (retry-vs-verdict failure split, the
capability-port shape this copies) ·
[done/monitoring-hook-seam.md](./done/monitoring-hook-seam.md) (the default-implementation seam
shape Part 2 §9 measures itself against)

---

## 0. 🚨 [2026-09-02] Correction: §1–§6 below are history

Every blocker §1 names is cleared and the competency is built and published as
`@reventlessdev/trait-notification@1.0.0-alpha.3` (Apache-2.0). Read §1–§6 as the record of how it
was designed, not as work to do:

- **§1 "its substrate does not exist"** — superseded. The `Messaging` capability shipped, with the
  provider publishing its channel list at runtime rather than a deploy-time modality system.
  `Capabilities.none` answers `Unavailable` as §5 required.
- **§4 D1** — decided, and **the recommendation in this file was wrong.** Option 2 (a `recipientOf`
  member on the host contract) is unbuildable: `OutboundTranslationSlice.Translation.translate`
  receives `(id, item, ~capabilities)` and nothing else, so there is no door a lookup could go
  through. The decision is **option 1, extended** — the trait's own preferences component *is* the
  recipient registry, populated by folding host events rather than only by explicit subscription,
  which removes the unregistered-recipient case §4 raised against option 1. "A trait grafts by
  reading host events alone" therefore survives.
- **§2's correction** — held. The trait writes nothing back to the host, and `posture` is carried on
  the host contract as an explicit member rather than assumed.
- **§5's ⚠️ at-least-one-channel gap** — resolved the way that paragraph's second option suggests,
  as a runtime channel list (`Reventless.Messaging.provider.channels`) that a deploy gate and a
  preference screen both read.

**Where it stands as of this correction:** exactly one host grafts the trait —
`examples/online-shop-hybrid/ordering` — and nothing outside this repository consumes it. That fact
is what makes Part 2 cheap, and it is the only thing that does.

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

---

# Part 2 — the wording becomes data, and a deployment can bring its own table

**Date:** 2026-09-02

## 7. The problem Part 1 left behind

`examples/online-shop-hybrid/ordering/src/Notification/AutomationSlice/NotificationIntake_Automation.res`
is the file a graft has to be given, and its own comments say why: *"this is where 'a placed order is
an OrderConfirmation, a shipped one is a ShippingUpdate, and here is what each says' is written
down"*. Six things are written in code there that are not the trait's and not really the host's
either — they are a *table*:

| Written as code today | In `NotificationIntake_Automation.res` / `NotificationIntake.res` |
|---|---|
| Which host events are notifiable | the closed `OrderingDcbSource.event` variant and `collect` |
| The occurrence taxonomy | `type occurrence = Placed \| Shipped` |
| Which occurrence earns which category | the `switch` in `compose` |
| The wording | template literals inside the same `switch` |
| The idempotency key | `confirmationKey` / `shippingKey` |
| The category vocabulary | the closed `category` variant in `NotificationPreferences.res` |

Everything downstream of that file is already free of it. `SendNotification` reads no state and
knows nothing about orders; the channel is already a per-recipient runtime preference;
`Notification_Rules` already types `category` as a bare `string` precisely so the vocabulary stays
the host's. **The competency's delivery half is data-driven and its intake half is hand-written**,
and that asymmetry is the whole subject of Part 2.

## 8. What Part 2 changes, in one sentence

The graft file stops containing a `switch` and starts containing **an array of rule values**, and a
message that goes out records which rule wrote it.

Both are worth doing on their own terms:

- **Rules as data** shrinks the graft file to a value and makes the wording readable text instead of
  ReScript interpolation. It also puts this trait within reach of a result the traits programme has
  not achieved for any specimen: a graft that hands over *nothing* hand-written.
- **Provenance** answers a question nothing can answer today: which wording was in force when this
  message was sent. One field, useful whether or not anything else in Part 2 is ever built.

Where a rule table might come from *other* than the compiled array is a separate question, and a
much smaller one than an earlier draft of this plan made it — §9 and §13.

## 9. The constraint that decides the shape

One fact settles more of this than any preference: **a composing automation cannot read
configuration.** `AutomationSlice.context` is four strings — environment, platform, plugin, slice —
and the framework says so deliberately: *"The record is intentionally narrow — extending it is a
deliberate framework change, not an open-dict escape hatch. Runtime registry lookups are out of
scope."* `process` is `(id, todoItem) => option<(string, command)>` and closes over module-level
values, nothing more.

So a compiled composer has no door through which to ask "is somebody else handling this one?". Any
design in which it *stands aside* has to move that decision downstream into the slice, and paying
for that is what turned an earlier draft of this plan into a claim protocol (§13b).

The way out is not to ask the question at runtime. **Which rule table a deployment composes from is
a property of the deployment, not of a request** — one producer, always, with per-notification
granularity living *inside* the table rather than between two of them. Nothing to arbitrate, nothing
to fence, and a duplicate send is impossible by construction rather than prevented by a mechanism.

That also puts this closer to `done/monitoring-hook-seam.md` than it first appeared — a default that
does the whole job, and a replacement that takes over — with the difference that what is replaced
here is a *table of values*, so the replacement can start as a copy of the default and be edited one
row at a time. That is what an administrator actually wants, and it needs no protocol.

## 10. P0 — the rule becomes a value

New in `traits/notification/src`:

```rescript
// Notification_Rule.res — the shape both a compiled table and a persisted one hold.
type recipientSource =
  | FromField({path: string})
  | FixedAddress({channel: Notification_Rules.channel, address: string})

type predicate =
  | Always
  | Compare({path: string, op: comparison, value: literal})
  | All(array<predicate>) | Any(array<predicate>) | Not(predicate)

type content = {locale: string, subject: string, body: string}

type t = {
  id: string,
  source: {log: string, eventType: string},
  filter: predicate,
  category: string,
  recipient: recipientSource,
  content: array<content>,
}
```

The graft file then holds a `defaultRules: array<Notification_Rule.t>` and the automation's
`process` looks a rule up rather than switching. `Notification_Scaffold` emits the array shape
instead of the `switch`.

**Why the predicate is a typed tree and not a string.** A rule's filter is data that will one day
arrive from outside this repository. A string that has to be parsed at evaluation time is a parser
plus an injection surface; a tree is neither, and the tree is also what lets a caller offer only the
operators a field's semantic supports.

**Deliverable:** the `online-shop-hybrid` graft file loses its `compose` and its `occurrence` type,
and the two notifications it sends are unchanged. `OrderingFlow_GWT` and the notification GWT suites
are the check.

## 11. P1 — the renderer

New in `reventless/spec/src/semantic` — **not** in the trait. It is a pure function of
(template, payload, field schema, locale) and it reads the semantic vocabulary that already lives
there; putting it in the trait would make every other future consumer depend on a trait.

Grammar, and deliberately nothing more:

```
{{ order.total }}                       field interpolation by path
{{ order.total | currency }}            explicit formatter override
{{# if order.expedited }}…{{/ if }}     guard
{{# each items }}…{{ .name }}…{{/each}} one level of iteration, bounded
```

Total, pure, no evaluation of caller-supplied code. A path that does not resolve renders a visible
placeholder and never throws — a rule can outlive the shape of the event it reads, and the send path
is not where that should surface as an exception.

**The part worth building carefully.** The *default* formatter comes from the field's semantic
annotation, which `SuryToJsonSchema.deriveObjectSchema` already carries (it is annotation-aware,
unlike `S.toJSONSchema`). A `@money` field renders as currency, a `dateTime` in the recipient's zone,
a `percent`/`duration`/`bytes` by its own rule — with no formatter written in the template. This is
the whole argument for rendering on top of an annotated schema rather than raw JSON, and it is
cheap only because the annotations are already there.

## 12. P2 — provenance

One field. `RequestNotification` gains

```rescript
origin = Default | Configured({ruleId: string, ruleVersion: string})
```

carried onto `NotificationRequested` and onto the delivery row. `Default` means the compiled array
of §10 produced this message; `Configured` names the rule and the version of it that did.

**Why it earns its place independently of everything else here.** A delivery row today says a
notification happened, to whom, on which channel and how it ended. It cannot say *what it said*, or
why it said that — and once wording is data that can change, "which wording was in force when this
went out" becomes a question support and audit both ask. Recording the answer costs one field at the
moment the decision is made; reconstructing it afterwards is not possible at all.

⚠️ **`Default` is not a placeholder for a missing value.** It is a real answer — this deployment
composes from the compiled table — and it stays a real answer forever, because a deployment that
never configures anything is the intended steady state, not an unfinished one.

An earlier draft paired this with a fourth non-send outcome, `NotificationDeferred`, so a compiled
composer could stand aside for a configured one. That outcome is gone with the protocol that needed
it — §13b.

## 13. P3 — one producer, and where its rules come from

The rule table a deployment composes from is either the compiled array of §10 or a configured one.
**Never both**, and which it is, is settled when the deployment is assembled.

Concretely: the host's compiled intake automation composes from `defaultRules`. A deployment that
wants its wording configured instead deploys a component that composes from a table it folds itself
— a slice can hold state where an automation cannot (§9) — and the host's compiled intake is not
deployed alongside it. One producer is wired at a time.

Everything downstream is untouched. Both producers publish the same `RequestNotification`, differing
only in `origin`; `NotificationPreferences` decides, `SendNotification` delivers, and neither knows
or cares which one asked.

### 13.1 Seeding, so nothing goes quiet

A configured table that starts empty means every notification the deployment used to send stops the
day it is switched over. It has to start as a **copy of the compiled defaults**, which are then
edited one row at a time.

The compiled array lives in the host plugin and cannot be imported across a plugin boundary, so it
has to travel as data. Two ways:

| | How | Cost |
|---|---|---|
| **Publish the defaults** | The host publishes `defaultRules` as data when it connects, the way other registries here are populated by lifecycle events | Real work, and the right shape — the same event-sourced-configuration move used elsewhere in this repository |
| **Start empty** | Whoever configures the deployment writes the rules | Free, and worse: a switchover silently stops every notification until someone notices |

**Recommended: publish the defaults.** The second option's failure is silence, which is the failure
mode this whole competency is most careful about everywhere else.

### 13.2 ⚠️ The invariant, and that nothing enforces it

**Two producers wired at once means duplicate notifications, and there is no mechanism here to stop
it** — that is the deliberate trade for not building the protocol in §13b. The invariant is an
assembly-time one: the host plugin's component list contains the compiled intake *or* a configured
composer, never both.

Give it a fail-fast rather than a comment. The natural place is wherever the plugin's components are
assembled, refusing two components that publish `RequestNotification` to the same
`NotificationPreferences`; a check that runs at deploy time is worth more than a rule in a document,
because the symptom — a customer receiving two identical confirmations — is one that reaches a
person before it reaches a log.

### 13.3 What this deliberately does not support

Compiled and configured rules serving different entries **at the same time**, switchable at runtime.
Under this design a deployment is on one table or the other, and per-notification granularity lives
inside the configured table — an administrator edits one row and leaves the rest at their seeded
defaults, which is the same outcome by simpler means.

The cost is **drift**: a seeded row stops tracking later improvements to the compiled default it was
copied from. That is the ordinary cost of forking a value on adopt, it applies per row rather than
wholesale, and it is worth naming in whatever surface presents the table.

## 13b. Rejected — a claim protocol between two live producers

Recorded so it is not re-invented. An earlier draft had the compiled and configured producers both
running, negotiating per entry through claims:

- `RequestNotification` carried a `sourceKey` (`"<log>:<eventType>"`), auto-tagged as a DCB tag.
- `NotificationSourceClaimed({sourceKey, by})` / `NotificationSourceReleased({sourceKey})` were folded
  by `NotificationPreferences`.
- `decide` answered a `Default`-origin request for a claimed key with `NotificationDeferred` instead
  of putting it through `Rules.decide`; a `Configured` request always went through.

**It works.** The DCB mechanics are sound: adding `sourceKey` to the command widens the conditional
read (the tags are extracted from the command and OR'd — `StateChangeSlice_Callback.res:198`), so the
claim is visible at the decision; and because that read is also the concurrency fence, a claim landing
mid-flight forces in-flight requests to re-decide, making the handover atomic.

**It was dropped because it solves a harder problem than the requirement.** The requirement is that
an administrator can configure each notification individually. Two live producers negotiating at
runtime is strictly more than that, and it costs: a fourth non-send outcome, a fourth arm on the
automation's `resolve`, a tag on every request, two claim events, a fold, a branch in `decide`,
release-on-uninstall, and two conformance assertions. A merged table reached the same
per-notification granularity with none of it.

Two findings from that draft are worth keeping if anyone revives it:

- **`NotificationDeferred` must not be projected into `NotificationDeliveries`.** The view keys rows
  with `Set(reference, …)`, so a deferral and a real outcome carrying the same reference would fight
  over one row. A deferral is not a delivery outcome — it is one producer standing aside, which is
  invisible to the domain.
- **The two producers do *not* need to derive the reference key identically.** An earlier version of
  this section claimed they did; the deferral keys on `sourceKey`, not on `reference`, so it holds
  either way. The requirement was never real.

## 14. P4 — the category vocabulary opens

`NotificationPreferences.category` is a closed `@schema` variant and is the key of the subscription
matrix. `Notification_Rules.category` is already `string`, so only the host component's schema is
the obstacle. The vocabulary becomes configured data — id, display name, default posture, whether a
recipient may opt out — and the compiled variant survives as the *seeded* set rather than the closed
universe.

**The conformance suite needs no change; the binding does.** `Notification.Binding` declares
`type category` **abstract** and takes `transactional` / `optional` as members, and
`Notification_Conformance` never enumerates categories — it drives everything through those two
members. A configured vocabulary satisfies it as long as the binding names two ids with differing
postures and its `created` history additionally seeds the vocabulary.

⚠️ **`posture` is the field with consequences.** "Notify someone who has never said anything" is the
correct answer for a confirmation and the wrong one for marketing; the trait already refuses to
decide it globally for that reason. Once it is data rather than a compiled table, whatever writes it
needs a distinct authorization from ordinary preference writes, and the change needs to be
auditable. Do not ship the vocabulary as configuration without that.

## 14b. P5 — the delivery row stops carrying an address, and starts naming its subject

**Status: ✅ DELIVERED [2026-09-02].** Both halves shipped, with the two §17 assertions, the
scaffold emitting the same shape, and the GraphQL and lifecycle goldens refreshed alongside.
Two corrections to what is written below:

- **The field is `subjectRef`, not `subjectId`.** Two separate inferences read id fields by
  **name**: `GraphQL_FragmentGenerator.resolveKeyField` (which supplied this view's filter and
  `orderBy` off its "sole `*Id` field" rung) and `DcbTag.idFieldsOfProperties` feeding
  `DcbScopeInference` (which picks the DCB partition). A second `*Id` on the row makes the first
  ambiguous — silently dropping `recipientIdEq` and the whole `orderBy` from the SDL — and the
  second unresolvable. Neither has an escape hatch: `@noDcbTag` is documented as *not* reaching
  the scope inference, and `@partitionTag` is **boundary-wide unique** (`orderId` already holds it
  for this plugin), so annotating around it is not available. The name is the fix.
- **`recipientId` now carries `@scan @scanSort`.** The view's filter and sort surface was an
  artifact of that inference rather than anything declared. Declared, it no longer depends on how
  many fields happen to end in `Id`. No SDL change.

Worth its own plan, and not scoped here: an inference that silently removes a queryable's filter
and ordering when an unrelated field is added is a trap any view can fall into. A deploy-time
warning when `resolveKeyField` goes ambiguous on a state with no `@id` would surface it.

Two changes to `NotificationDeliveries`, one removing data and one adding it. Independent of
P0–P4 and safe to do first.

### 14b.1 Remove `address` from the view

`NotificationDeliveries.state` carries `address` — "*the inbox, the number, the device token*" — and
its projection writes it on every `Set`. It is the recipient's personal data sitting in a queryable
read model, and a read model is the widest, longest-lived surface this competency has. It comes out.

⚠️ **This deletes a capability the field was added for, and the field's own comment argues for it:**
the directory holds the address of *record*, which changes, while this held the address a message
actually went to. A support conversation about a confirmation nobody received is about the second.
That question stays answerable — `NotificationRequested` still carries `address`, because
`SendNotification` cannot deliver without it, and the per-log event-history query exposes it with
its audit metadata. What changes is that answering it now requires reading the event log rather
than a general read model, which is the correct shape for personal data: available to an
investigation, not to every reader of a view.

**The event keeps the field. Only the view loses it.** Do not remove it from
`NotificationRequested`; the send slice consumes it and reads no state.

Note for the record, not for this plan: the address is also personal data on the customer's own row,
and that is a separate and larger question about the host's model rather than the trait's.

### 14b.2 Add the subject: what the notification was about

The view says a notification happened and how it ended, but not what it concerned. A row can only be
read back against a `reference` whose format is the requester's private business. Add two fields to
the view's state, both descriptive and neither load-bearing:

```rescript
// What this notification was about. `subjectType` is the referenced component's
// name as the deployment registers it; `subjectId` is that row's own id.
subjectType: string,
subjectId: string,
```

They ride on `RequestNotification` and onto the outcome events, alongside `reference`. Empty is a
legal value: a notification about nothing in particular is a real case, and a fabricated subject is
worse than an absent one.

### 14b.3 ⚠️ The prefix cannot be removed from `reference` — it is load-bearing in three places

The obvious move — make `reference` the bare `orderId` and drop the `confirm:` / `ship:` prefixes
that `NotificationIntake_Automation.res` builds — breaks three things, and two of them fail silently:

1. **It is the delivery view's row key.** `NotificationDeliveries_Projection.res` does
   `Set(reference, {…})`. An order that is placed and then ships is two notifications; with a bare
   order id they become one row, and the shipping outcome overwrites the confirmation's. No error —
   just a row that quietly stops being the confirmation's.
2. **It is the automation's TODO row id.** `confirmationKey` / `shippingKey` are the keys `collect`
   emits, and the automation's own comment gives exactly this reason: *"One key per occurrence, not
   per order: an order that is placed and then ships is two notifications, and a shared key would
   let the first one's outcome close the second one's row."*
3. **It is how a TODO row is resolved.** The outcome events echo `reference` and `resolve` matches
   on it. Two rows under one key means the first outcome closes both, so the second notification is
   never sent and nothing records that it was not.

**So the two concerns are different and today they are fused into one string:** a *correlation key*
that must be unique per occurrence, and an *entity reference* that must be the bare id of the thing
the notification is about. Splitting them is the fix — `reference` keeps its documented meaning
("the requester's own key for it, echoed back on whichever outcome follows") and its prefix, and
`subjectType` / `subjectId` carry the entity plainly with no format to decode.

**Do not rename `reference` to free the name for the subject.** It is the trait's vocabulary in
`Notification_Rules` (`Request`, `Requested`, `Suppressed`, `Undeliverable`), in the conformance
suite, in the scaffold and in the host, and its current documentation already describes a
correlation key rather than an entity pointer. The rename would touch every one of those for a
naming preference.

**P0 interaction:** with rules as data, `subjectType` is a per-rule constant and `subjectId` is a
field path into the event, so both are rule fields rather than anything the graft writes by hand.
The reference key stays derived (§13).

## 15. Framework items this depends on

Both are general capabilities that happen to be needed here. Each is separable and may be worth its
own plan; neither should be scoped as a notification feature.

### 15.1 `@sensitive` — a field says it must not leave

An annotation in the ppx, emitted as `x-reventless-sensitive` beside the existing
`x-reventless-semantic` keys in `SuryToJsonSchema.deriveObjectSchema`. It marks a field whose value
must not be rendered into outbound content, and it is read by anything that composes text a person
receives.

**Why this belongs in core rather than with whatever consumes it:** it is a property of the domain
model, declared where the field is declared, and it is wanted by consumers that have nothing to do
with notifications. A marking that exists only in one consumer is a marking the rest of the system
cannot honour.

Fields already carrying a semantic that implies sensitivity (`email`, `phone`) default to masked
without an annotation being added.

### 15.2 A raw-consumption posture on `OutboundTranslationSlice`

Today a slice consumes events through a closed `@schema` variant, so it cannot consume an event type
chosen anywhere but at compile time. The posture: **subscribe to a declared allowlist of logs and
hand the translation `(eventType, payload, meta)` as raw JSON.**

The shape is settled and it is smaller than it looks:

- `OutboundTranslationSlice` already declares its sources **on the Spec** — `Spec.sourceNames`, with
  `[]` meaning this plugin's own DCB log (`OutboundTranslationSlice_Builder.res:115`). It is the only
  consuming component that does. `AutomationSlice` *derives* them from `Automation.mappings`
  (`AutomationSlice_Builder.res:42`), each carrying a closed `sourceEventSchema`, so an automation
  structurally cannot express "subscribe to this log without a typed variant for it".
- The typed decode is a single **value**, not a functor:
  `DcbDecode.makeDecoder(Spec.consumedEventSchema)` returns `{decode, eventTypes}`
  (`OutboundTranslationSlice_Builder.res:64`, consumed at `:179`). A total passthrough decoder is one
  substitution at one call site.
- The semantics already fit: this is the component that reaches an external system through an
  injected capability, with retries, a TODO list, exhaustion handling and `externalSystem` for the
  Event Graph, and it already receives `~capabilities` in `translate`.

Work, and it is three things: an opt-in on the Spec; the decoder swap; and `Plugin_Structure`
reporting `consumedEventTypes` from the declared allowlist rather than from the variant — today it
is `qualify(~prefix=name, eventVariantNames(OTS.Spec.consumedEventSchema))`
(`Plugin_Structure.res:1450`), which for a raw slice would report nothing at all and blank the
component's incoming edges in the Event Graph.

**There is no fourth thing.** An earlier draft of this plan claimed a structural check that every
consumed event be an event of `sourceNames` had to be bypassed. No such check exists — the comment at
`Plugin_Structure.res:503` records deliberately *not* having one, because `consumedEventTypes` drops
payload-less variants and a completeness rule would fire on exactly the events the metadata omits.
Nothing needs relaxing.

⚠️ **Keep the source-name fail-fast.** `OutboundTranslationSlice_Builder.res:128` throws on a
`sourceName` with no matching topic, precisely because `EventTopic.filter` would otherwise silently
drop it and the slice would run on no events. Raw consumption makes that failure *more* likely to go
unnoticed, not less — there is no variant to disagree with either.

⚠️ **Accepted loss: drift detection.** `makeDecoder` warns when a stored event no longer matches the
current schema. A raw consumer has no schema to disagree with, so a field that disappears becomes a
placeholder in rendered output rather than a warning. Whatever consumes raw events needs a
schema-drift check of its own, run against the deployed plugin structures rather than at decode time.

## 16. Order, and the one deadline

```
P0 rules-as-data ─┬─> P4 open vocabulary
                  └─> P1 renderer
P2 provenance                 (independent, one field, any time)
P3 configured table           (a deployment shape, not a code change to P0's producer)
P5 address out / subject in   ✅ DONE [2026-09-02]
15.1 @sensitive               (independent, any time)
15.2 raw posture              (independent; needed by a configured composer, not by P0–P4)
```

⚠️ **P0 cannot meet its own acceptance criterion without P1.** §10's deliverable is that the two
notifications are unchanged, but today's wording is interpolated (`Your order ${item.orderId} is
confirmed`) and P0's `content` holds plain strings — turning `orderId` back into that sentence *is*
the renderer. So "P0 changes only the graft file and the scaffold" below is wrong: P0 either pulls
in P1, and with it `reventless/spec`, or ships a stopgap interpolator P1 then replaces. Settle that
before scheduling either.

⚠️ **P1 before 15.1 is backwards.** The renderer interpolates arbitrary field paths of an event
payload into text a person receives; `@sensitive` is the marking that says which fields must not go.
Building the capability and deferring its guard is the wrong order regardless of the schedule.

P1 is additive and safe at any point.

**P2, P4 and P5 change a published event shape or a projected view's state**, and their cost is a
function of adoption: today the trait is `alpha.3` with one host, both in this repository, so each is
a single-commit change with the host updated in the same commit. Once the trait leaves alpha or a
host outside this repository grafts it, the same three become migrations with event healing and a
projection rebuild.

**P3 is not on that list any more.** With the claim protocol dropped (§13b) it adds no field and no
event — it is a statement about which components a deployment wires, plus the fail-fast in §13.2. It
can happen whenever a configured composer actually exists, and never needs to happen at all for a
deployment that is content with its compiled table.

**P5 is done. P2 is next**, and it is one field: small, independent, and on the deadline only because
it touches a published event. **P4 stays blocked** until §14's ⚠️ is answered: who may write
`posture`, and how that write is audited. That is a decision, not code, and it is not specified
anywhere here.

## 17. Verification

- `pnpm --filter @reventlessdev/trait-notification build`, then a full root build — the scaffold's
  emitted text is compiled by its host, so a scaffold change that does not compile fails in the
  example, not in the trait.
- The notification GWT suites under
  `examples/online-shop-hybrid/ordering/tests/Notification/` plus `Flow/OrderingFlow_GWT` — P0's
  acceptance is that these are unchanged and still green.
- `Notification_Conformance` through the `online-shop-hybrid` binding — unchanged by P2 and P3, and
  that is the check: neither may alter what the competency does, only what it records about itself.
- For P2: assert `origin = Default` reaches the delivery row on a message the compiled table
  produced. A field that is written but never read back is how provenance quietly stops being
  recorded.
- For P3: the assembly-time fail-fast of §13.2 — a plugin wiring both a compiled intake and a
  configured composer must be refused at build or deploy time. Test the refusal, not just the happy
  path; the invariant exists precisely because the failure it prevents is invisible until a customer
  receives two identical emails.
- ✅ For P5: an assertion that placing **and then shipping** one order leaves **two** delivery rows.
  Shipped as `tests/Notification/StateViewSliceStream/NotificationDeliveries_GWT.res` — two
  scenarios, written and run green against the unchanged code first, then re-run with both
  reference keys collapsed to the bare order id to confirm both go red. The expected store is keyed
  by **literal** strings, not by the relay's key functions: a dict built from the derived values
  collapses to one entry exactly when the relay does, and the scenario would keep passing while a
  notification went missing.
  That is the regression the reference key exists to prevent (§14b.3), it is currently guarded by
  nothing but a comment, and it fails silently — one row where two belong, with the later outcome
  overwriting the earlier. Write it before touching the reference at all, so it is a test that was
  green first rather than one written to match whatever the change produced.
- ✅ For P5: a check that `address` appears in no view state. The GraphQL contract golden is that
  check — `Ordering_NotificationDelivery` no longer declares it, and `check:graphql` fails if it
  comes back. The field stays on `NotificationRequested`, which the send slice consumes.
