# Plan: the Notification trait

**Date:** 2026-08-30
**Repo:** reventless-core — a new package under `traits/`, a new `Messaging` capability, and the
`online-shop-hybrid` ordering plugin.
**Status:** **Part 1 DELIVERED. Part 2 is the open work.** Everything §1–§6 called blocking has
shipped — see the correction box below. Part 2 turns the competency's wording from code into data,
and lets a second producer take over one stream of occurrences at a time.
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

# Part 2 — the wording becomes data, and a second producer can take one stream at a time

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

**[2026-09-03] Four of those six rows are now data** (P0, §10). What remains in code is the first —
which host events are notifiable — because `AutomationSlice` consumes through a closed `@schema`
variant and cannot do otherwise until 15.2; and the last, the category vocabulary, which is P4. The
idempotency key stopped being hand-written without becoming configuration: it is derived from the
rule's id, so the two key functions collapsed into one derivation.

## 8. What Part 2 changes, in one sentence

The graft file stops containing a `switch` and starts containing **an array of rule values**, and a
message that goes out records which rule wrote it.

Both are worth doing on their own terms:

- **Rules as data** shrinks the graft file to a value and makes the wording readable text instead of
  ReScript interpolation. It also puts this trait within reach of a result the traits programme has
  not achieved for any specimen: a graft that hands over *nothing* hand-written.
- **Provenance** answers a question nothing can answer today: which wording was in force when this
  message was sent. One field, useful whether or not anything else in Part 2 is ever built.

How a *second* producer takes over part of that array without double-sending is §13; why the
decision has to live where it does is §9; and the simpler design that was weighed against it is
§13b.

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

**So the decision to stand aside has to be made downstream, by the component that already decides.**
`NotificationPreferences` folds its own log before every decision; it is the one place that can know
both that a request arrived and that somebody else owns the source it came from. That is what §13
builds, and the constraint above is the whole reason it is built there rather than in the composer
where it would read more naturally.

The alternative is to never ask the question — one rule table per deployment, chosen when the
deployment is assembled, with per-notification granularity living inside that table. That is the
shape `done/monitoring-hook-seam.md` established for this repository, and it is genuinely simpler.
It was weighed and not taken; §13b records why.

## 10. P0 — the rule becomes a value

**Status: ✅ DELIVERED [2026-09-03].** `TraitNotification.Notification_Rule`, the graft's
`defaultRules`, the scaffold emitting the same shape, and
`tests/Notification/AutomationSlice/NotificationIntake_GWT.res`. The two notifications are
unchanged, and so are their reference keys. Six corrections to what is written below:

- **`recipientSource` collapsed to a `recipientPath: string`.** `FixedAddress` was dropped:
  `RequestNotification` addresses a *recipient* and the directory resolves the address, so a fixed
  address is a different door — alerting, §5 — and an arm the host cannot honour is worse than an
  absent one. With one arm left, the variant was noise.
- **The rule carries four fields §10 did not name**, each because something concrete needed it:
  `version`, because §12's `Configured({ruleId, ruleVersion})` has nowhere else to read one;
  `subjectType` and `subjectPath`, which is §14b.3's own note made real (a per-rule constant and a
  field path); and `locale` on each `content`, which `contentFor` selects on.
- **A rule's id *is* the namespace of the references it writes.** §14b.3 says the reference key
  stays derived, and deriving it as `"<ruleId>:<subject>"` reproduces `confirm:o1` / `ship:o1`
  byte-for-byte — so the delivery-view goldens are unchanged — while collapsing the two hand-written
  key functions into one derivation. The cost is that renaming a rule re-keys its delivery rows,
  which is said on the field.
- **`collect` still switches, and cannot stop until 15.2.** An `AutomationSlice` consumes through a
  closed `@schema` variant, so "which host events are notifiable" stays code. What changed is that
  the switch only *destructures*: the dispatch is `Rule.forEvent`, so a second rule on an
  already-notifiable event is a table entry with no arm to add, and two rules on one event are two
  notifications.
- **The wording renders against the todo item, not the raw event.** The item is encoded through its
  own `@schema`, so every field of it is a template path — and the renderer's semantic formatting
  and `@sensitive` withholding apply to it. Rendering from raw events is 15.2's shape, not this one.
- **A row naming a rule this build no longer carries publishes nothing** and is abandoned in
  `onExhausted`, which is what a deployment that dropped a rule asked for. It is the one reachable
  `None` in `process`, and it is asserted.

Fixed in passing: the scaffold emitted an automation `collect` of the wrong arity
(`(event, _ctx)` rather than `(event, ~sourceId as _, _ctx)`), so an emitted intake relay would not
have compiled. Pre-existing, and in text this change rewrote anyway.

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

**Status: ✅ DELIVERED [2026-09-03].** `Reventless.Template` in
`reventless/spec/src/semantic/Template.res`, with 30 assertions in
`reventless/spec/tests/TemplateTest.res`. Four corrections to what is written below:

- **It reads the sury schema, not a derived JSON Schema.** §11 said the default formatter comes
  from what `SuryToJsonSchema.deriveObjectSchema` carries. That is the same mistake §15.1 already
  corrected for `@sensitive`, and for the same reason: `deriveObjectSchema`'s annotation path reads
  `StateAnnotations`, which exists only for a queryable's `@schema type state`, while the renderer
  reads **event payloads**. `Semantic.getFrom` and `Sensitive.isFieldSensitive` read the field's own
  sury metadata, so command and event variants are covered. `Template.variantSchema` takes the arm,
  since a message is about one occurrence.
- **There is no locale or zone handling, and `dateTime` renders as stored.** Formatting is
  locale-independent, which is the rule `Money.format` already states for every formatter here.
  Nothing in the framework carries a recipient timezone, so "a `dateTime` in the recipient's zone"
  had no input to read. Locale belongs where §10 already puts it — choosing which `content` entry
  is rendered, not how a number is shaped — so the renderer takes no locale argument at all.
- **The override vocabulary *is* the semantic vocabulary**, so §11's sketched `| currency` is
  `| money`: the formatter names are `Semantic.Id.*` plus `raw`. A second table of formatter names
  is a second thing to drift, and `currency` already means `Currency.t` in this repo.
- **Withholding shipped with it**, per §16's ordering rule. A path whose schema is marked
  `@sensitive` — or carries the `email`/`phone` semantic — renders `[withheld: <path>]`. A *guard*
  on such a field still renders its body: it emits no value, and refusing it would silently drop
  the body of `{{# if customer.email }}`.

Delivered alongside, because the renderer needed them and they belong on the types: `format` on
`Percent`, `Bytes` and `Duration` (`Money`, `DateRange` and `GeoPoint` already had one), and
`Semantic.unionVariant`, extracted from `Sensitive.variantFieldNames` so both readers find an arm
the same way.

New in `reventless/spec/src/semantic` — **not** in the trait. It is a pure function of
(template, payload, field schema) and it reads the semantic vocabulary that already lives
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

Iteration is **bounded** (`Template.maxItems`, 100) and says how many items it left, so a template
rendered against an unexpected list cannot compose a message of unbounded length. A path is refused
at *parse* time when it is item-relative outside an `each`, when an `each` nests inside an `each`,
when a block is left open or closed by the wrong word, and when a formatter is outside the
vocabulary — the error names the offending token in each case.

**The part worth building carefully.** The *default* formatter comes from the field's semantic
annotation, which `SuryToJsonSchema.deriveObjectSchema` already carries (it is annotation-aware,
unlike `S.toJSONSchema`). A `@money` field renders as currency, a `dateTime` in the recipient's zone,
a `percent`/`duration`/`bytes` by its own rule — with no formatter written in the template. This is
the whole argument for rendering on top of an annotated schema rather than raw JSON, and it is
cheap only because the annotations are already there.

## 12. P2 — provenance, and a fourth outcome

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

**S2 — a fourth non-send outcome.** `NotificationDeferred({recipientId, reference, sourceKey})`.
The trait is already strict that the ways of not sending stay distinct facts: `Suppressed` (they
declined) and `Undeliverable` (nobody reachable) exist separately because collapsing them "would
hide every delivery gap behind a legitimate preference". A request not acted on because *another
producer owns this source* is a third thing by the same argument.

It is load-bearing rather than tidy. The relay resolves its TODO row on an outcome; without this one
a deferred request spends its whole retry budget and is abandoned with nothing in the log to say
why.

⚠️ **The field is `sourceKey`, not `sourceId`, and this is the one place the two names differ.**
A produced `sourceId` here would give the slice two candidate partitions — it already produces
`recipientId` — so it would resolve to neither; and worse, it would stop `sourceId` counting as a
*consumed-but-not-produced* key, which is precisely what makes the claim read cross partitions at
all (§13). The value is identical; only the fact is descriptive. Same class of trap as `subjectRef`
in §14b.

## 13. P3 — the handover

**Status: substantially built [2026-09-02], one gap open — §13.4.**

A second producer of notification requests takes over a *stream of occurrences* — one
`"<log>:<eventType>"` at a time — and the compiled table of §10 stands aside for exactly that stream
and no other. Everything unclaimed keeps being served by the compiled table, with no configuration
anywhere and no behavioural change.

### 13.1 Two slices, and the split is forced

The claim set lives in its own `NotificationSourceClaims` StateChangeSlice, **not** on
`NotificationPreferences` which is the component that reads it. That looks like one slice too many
until the reason is stated:

> A slice's DCB partition is inferred from the `*Id` fields its **own events** declare. A slice
> producing both `recipientId` and `sourceId` facts has two candidate partitions and resolves to
> neither.

Split, each side produces one key — preferences are per recipient, claims are per source. The
reading side then sees `sourceId` as a key it **consumes but does not produce**, and that is exactly
the shape from which the framework infers a cross-partition read. The split is not tidiness; it is
what makes the read happen at all.

Both slices fold the *same* `Notification_Rules.t` value, with `Claimed` / `Released` added to the
trait's own `op` and `fact`. The claims slice consults no posture — no arm reads one — but still goes
through `Rules.decide`, so the idempotence rule lives in the trait rather than being restated per
host.

### 13.2 What each piece does

| Piece | Where | Role |
|---|---|---|
| `ClaimNotificationSource({sourceId, by})` | claims slice, `@noApi` | A second producer takes over a source. `by` is provenance |
| `ReleaseNotificationSource({sourceId})` | claims slice, `@noApi` | Hands it back; the compiled table resumes on the next occurrence |
| `origin` on the request | preferences slice | `Default` (compiled table) or `Configured({ruleId, ruleVersion})` — §12 |
| `NotificationDeferred` | preferences slice | The compiled table standing aside, as a fact — §12 |

`decide` answers a `Default`-origin request for a claimed source with `Deferred`; a `Configured`
request always goes through. Both claim commands are idempotent — re-claiming what you hold and
releasing what nobody holds each publish nothing — so there is no refusal to make, which is why
`ClaimRefused` is declared but unreachable.

Neither command is a client door. A caller who could claim a source would be silencing everybody
else's notifications from it.

### 13.3 The acceptance criterion

**With nothing claimed, every `Default` request is decided exactly as before.** It is asserted in
`Notification_Conformance` rather than assumed, alongside a claim on one source leaving every other
source alone — the assertion that says the mechanism is per source and not a table-wide off switch.

### 13.4 ⚠️ Open: nothing releases a claim

`ReleaseNotificationSource` exists, is idempotent and is exercised by the GWT suite, but **no
production code calls it** — the only references outside `lib/` are tests. A claimed source therefore
stays claimed for as long as the deployment lives, and a claimant that goes away takes its
notifications silent with it.

Silence is the failure this competency is careful about everywhere else — it is the whole reason
`Suppressed` and `Undeliverable` are separate facts — so leaving this open contradicts the trait's
own standard. The plugin lifecycle already does this exact shape for UI fragments, where
deregistration rides **both** graceful disconnect and heartbeat timeout; a claim wants the same two
triggers for the same reason.

**Do this before the mechanism is used for anything.**

### 13.5 Do not grow it

No claim expiry, no priorities between claimants, no partial or conditional claims. The mechanism
serves one future feature well — batching, where a scheduler-driven producer legitimately needs
per-event sends for a source to stand down — and it is not a general foundation. In particular it is
**deployment-scoped**: a `sourceId` carries no tenant, so a source cannot be claimed for one tenant
and left compiled for another. Per-tenant configuration belongs in a rule table, not in the claim
key.

## 13a. 🚨 [2026-09-03] The two designs answer different questions

§13 and §13b read as if only one of them can be right, and the record disagrees with itself about
which: the commit that introduced §13b (*"the wording table is a deployment's choice, not a
negotiation between two producers"*) rejected the claim protocol, while the text below rejects the
table. Both were written in good faith about **different questions**, and neither wins outright:

- **Where the wording comes from** — §13b's answer, and it is the right one. §9's constraint holds:
  a composing automation cannot read configuration, so per-notification granularity belongs *inside*
  one table rather than between two producers. Nothing to arbitrate.
- **How a scheduler-driven producer stands down the per-event sends** — §13's answer, and the table
  cannot give it. `admin-configurable-notifications.md` §8.1 is explicit: *"a digest cannot simply be
  another row in the rule table — it is scheduler-driven rather than event-driven, so it is
  necessarily a separate component."*

So "one producer, always" is true for rules and false once digests exist. §13 stands as built; §13b's
argument is carried into P0, where it belongs. Read §13b as *rejected for the wording table*, not as
a rejection of the claim protocol.

⚠️ **The prerequisite neither section names: there is no door.** The competency exposes no
ExtensionPoint — *no trait in the repo ships one* — `RequestNotification` is `@noApi`, and an
Extension's write actions reach only its own plugin's delegate. Nothing in any of the four repos
designs how a foreign plugin issues a `Configured` request, and nothing constructs one outside tests.
So the claim mechanism has no possible counterparty today, and **the door comes before §13.4**:
releasing claims that nothing can make guards nothing.

## 13b. Rejected — one table per deployment

The simpler design, weighed and not taken. Recorded because it is the obvious question to ask of
§13, and because it would have been the right answer at a different moment.

**What it was.** No claims, no `Deferred`, no `sourceKey`. A deployment composes from the compiled
array *or* from a configured table, never both, decided when the deployment is assembled — the
`done/monitoring-hook-seam.md` shape, with a table of values in place of an implementation. The
configured table starts as a copy of the compiled defaults, and per-notification granularity lives
inside it: an administrator edits one row and leaves the rest at their seeded values.

**Why it is attractive.** It reaches the same administrator experience — the two are indistinguishable
from the console — with none of §13's surface: no fourth outcome, no fourth arm on the relay's
`resolve`, no second slice, no cross-partition read, no claim events. Fewer concepts for every future
reader of the trait.

**Why it was not taken.**

- **It needs a seeding mechanism that does not exist.** The compiled array lives in the host plugin
  and cannot be imported across a plugin boundary, so the defaults would have to be published as data
  at connect time. Without that, a switchover silently stops every notification the deployment used
  to send — the same silence §13.4 warns about, but by construction rather than by omission.
- **It needs an assembly-time check that does not exist.** Two producers wired at once means
  duplicate notifications with nothing to stop them, so the invariant "compiled intake *or* configured
  composer, never both" needs a fail-fast to be real.
- **Seeded rows drift.** A copied rule stops tracking later improvements to the compiled default;
  under §13 an unclaimed source keeps tracking it forever, with no bookkeeping.
- **§13 was already built and correct** when the comparison was made. Replacing working, tested code
  with a design carrying two unbuilt pieces and one unenforced invariant is more work for a slightly
  smaller concept count.

**The honest summary:** greenfield, this was the better call — §13 solves a harder problem than the
requirement, and the extra capability (per-entry switching at runtime, reversible with no redeploy)
is invisible to an administrator. It lost on cost-to-finish, not on merit.

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

**✅ [2026-09-03] That warning is built.** `GraphQL_FragmentGenerator.classifyKeyField` splits the
ladder's `None` into `Ambiguous` and `NoCandidate`, `keyFieldGapMessage` says what the gap costs,
and `Plugin_Structure` warns per view beside `recordRetired` / `recordLifecycle`. `resolveKeyField`
keeps its signature, so no call site moved.

⚠️ **It warns on `Ambiguous` only, and the measurement is why.** The over-broad first cut — warning
on `NoCandidate` too — fired on six views across the example plugins, and every one was correct and
none was a defect: a read model over an aggregate keeps the row's id on the **row key** rather than
in its state, so having no `*Id` field is its ordinary shape. A rule that fires on most read models
gets silenced, and then it is not guarding the case it was built for. `Ambiguous` is the accident
this section describes — the view *had* a key and a second `*Id` field took it away — and it fires
nowhere in this repository today, which is what a guard against a future mistake should do.

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

**Status: ✅ DELIVERED [2026-09-03].** `Reventless.Sensitive` in spec, `SensitiveInference` in the
ppx, `x-reventless-sensitive` out of `SuryToJsonSchema`, and the `email`/`phone` default. Two
corrections to what is written below:

- **It is not a `deriveObjectSchema` *annotation*, and could not be.** That function's annotation
  path reads `StateAnnotations`, which exists only for `@schema type state` on a queryable — while
  P1 renders from **event payloads**. A marker carried that way would be absent from exactly the
  schemas the renderer reads. It follows the `Owner` mechanism instead: sury metadata on the field's
  own schema, threaded into the walk as `~sensitive` beside `~owners`, so it reaches command and
  event variant fields too. `Sensitive.variantFieldNames` is the form the renderer wants — one
  occurrence, one arm.
- **It composes rather than replaces, and runs after `OwnerInference`.** Same reasoning as `@owner`
  running after the tag passes: a field carries at most one `@s.matches`, so a pass that injected
  early would be skipped by the auto-tagger and silently drop the field's DCB tag. Unlike `@owner`,
  any number of fields per record may carry it.

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

**Status: ◐ the metadata half is DONE [2026-09-04]; the posture itself is deferred — see §18.**
`outboundTranslationSliceDef.consumedSources` publishes `Spec.sourceNames` verbatim, `[]` included,
and `[]` keeps its declared meaning of "this plugin's own DCB log". Two things follow:

- **The third of §15.2's three work items is now a slot that already exists**, so the raw posture
  no longer has to invent a shape for a consumer in another repository at the same time as it
  changes the decoder. That was the whole reason to split it out — the Event Graph consumer lives
  outside this repository, and a shape it cannot be tested against is the risky half.
- **It earns its place without the raw posture.** `consumedEventTypes` names event types and not
  where they came from, and §15.2 already notes that two sources sharing an event-type name are
  indistinguishable. In `online-shop-hybrid/ordering` that is not hypothetical:
  `AnnounceRecipientContact` and `GeocodeCustomerAddress` both consume `Ordering.Registered`, one
  from the `Customer` aggregate's topic — and `SendNotification` reads `[]`, its own DCB log.

⚠️ **Adding a field to `pluginStructure` is survivable but not free of thought.** The tripwire
`PluginDefinitionRequiredScalarsTest` fires on the array's *element* — a bare required scalar — and
the answer is the one `traitDeclarations` already recorded: the array is `js_nullable` and new, so
no persisted payload carries it, a stored structure heals to null, and the element is never reached.
The frozen corpus cannot vouch for that on its own: every fixture in it carries
`"outboundTranslationSlices":[]`, so no stored payload has an outbound slice to be missing a field.
That gap is now covered by an explicit `parseJsonTolerant` assertion beside the encoder tests.

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
P0 rules-as-data                           ✅ DONE [2026-09-03]
  └─> P4 open vocabulary                   blocked on §14's decision, not on P0
P1 renderer                                ✅ DONE [2026-09-03]
P2 provenance + deferred ──> P3 handover   ◐ SUBSTANTIALLY BUILT — gap at §13.4, and see §13a
P5 address out / subject in                ✅ DONE [2026-09-02]
15.1 @sensitive                            ✅ DONE [2026-09-03]
15.2 consumedSources metadata              ✅ DONE [2026-09-04]
15.2 raw posture                           LAST — nothing needs it until a rule table is configured
§18 the digest, in-plugin                  ← NEXT: the claim mechanism's first counterparty
```

**P0's dependency on P1 was settled by shipping P1 first**, and no stopgap interpolator was needed.
§10's deliverable was that the two notifications are unchanged, and their wording moved from a
ReScript template literal (`Your order ${item.orderId} is confirmed`) to a rule's `content` string
(`Your order {{ orderId }} is confirmed`) rendered by `Reventless.Template` — same sentence, same
delivery rows, same reference keys.

⚠️ **P1 before 15.1 would have been backwards**, and was not: `@sensitive` landed first and the
renderer withholds on it. The renderer interpolates arbitrary field paths of an event payload into
text a person receives, so building the capability and deferring its guard would have been the
wrong order regardless of the schedule.

**P2, P4 and P5 change a published event shape or a projected view's state**, and their cost is a
function of adoption: today the trait is `alpha.3` with one host, both in this repository, so each is
a single-commit change with the host updated in the same commit. Once the trait leaves alpha or a
host outside this repository grafts it, the same three become migrations with event healing and a
projection rebuild.

**P0, P1, P5 and 15.1 are done, and P2+P3 are substantially built** — wired into `Plugin.res` on
both paths, with the conformance assertions written. **What is still open on the handover is §13.4:
nothing releases a claim.** Finish that
before the mechanism is used for anything; a claimant that disappears currently takes its
notifications silent with it.

**P4 stays blocked** until §14's ⚠️ is answered: who may write `posture`, and how that write is
audited. That is a decision, not code, and it is not specified anywhere here.

## 17. Verification

- `pnpm --filter @reventlessdev/trait-notification build`, then a full root build — the scaffold's
  emitted text is compiled by its host, so a scaffold change that does not compile fails in the
  example, not in the trait.
- ✅ The notification GWT suites under
  `examples/online-shop-hybrid/ordering/tests/Notification/` plus `Flow/OrderingFlow_GWT` — P0's
  acceptance was that these are unchanged and still green, and they are, with one exception that
  had to move: `NotificationDeliveries_GWT` derived its two keys from the relay's
  `confirmationKey` / `shippingKey`, which the rule table replaced. It now derives them through
  `Rule.byId`, so it still asserts derived keys against **literal** expectations — a rule id that
  no longer exists yields a reference matching neither literal, rather than a lookup passing
  quietly.
- ✅ For P0: `tests/Notification/AutomationSlice/NotificationIntake_GWT.res`, which mirrors the
  relay 1:1 as example-plugin tests do. Written against the finished table and then verified
  *negatively* — an unparseable template and a mistyped category key were introduced, and three
  scenarios went red with the reason named. The category assertion is load-bearing because
  `categoryOf` falls back to the first kind declared, so only a rule whose kind is **not** that one
  can catch a typo; the shipping rule is that assertion. One scenario covers the whole table rather
  than the two rules with scenarios, so a third rule added with a broken template cannot ship in
  silence.
- `Notification_Conformance` through the `online-shop-hybrid` binding — unchanged by P2 and P3, and
  that is the check: neither may alter what the competency does, only what it records about itself.
- ✅ For P2/P3: the four `Notification_Conformance` assertions — nothing claimed decides as usual, a
  claimed source defers a `Default` request, a claim on one source leaves others alone, and a
  `Configured` request goes through a claimed source. The first is the acceptance criterion; the
  third is what proves the mechanism is per source rather than a table-wide off switch.
- For §13.4, when it lands: assert that a claimant disconnecting releases its claims and the compiled
  table resumes. Test the **timeout** path as well as the graceful one — a producer that crashes is
  the case the release exists for, and it is the one a graceful-disconnect-only test will not
  reach.
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
- ✅ For P1: `reventless/spec/tests/TemplateTest.res`. The two load-bearing properties are asserted
  directly rather than left to inspection — **totality** (a missing path, a path through a scalar
  and an `each` over a non-list each render a placeholder; a parse failure is a `result`, never a
  throw) and **withholding** (an annotated field, an annotated *optional* field whose marker sits
  inside sury's wrapper, an unannotated `email`, and one arm of an event union). The formatter
  assertions drive `Money` / `Percent` / `Bytes` / `Duration` through a template with no formatter
  written, which is the claim §11 makes about rendering on an annotated schema.

---

## 18. 🚨 [2026-09-04] The door §13a asks for may not be needed — build the digest instead

§13a stopped the P2/P3 line on one observation: nothing can issue a `Configured` request, because
the competency exposes no ExtensionPoint. That is true and the conclusion drawn from it is too
strong. **A second producer inside the same plugin needs no door at all.**

`RequestNotification` is `@noApi`, which closes the *client* door and nothing else. The intake relay
already publishes it to `NotificationPreferences` from inside the ordering plugin; a digest
component would publish it the same way, and claim its source through `NotificationSourceClaims`
exactly as §13.2 describes. The door §13a names is needed only for a producer in a **foreign**
plugin — and the feature the claim mechanism was built for (§13.5: batching) is a digest of *this*
plugin's own notifications, which belongs in this plugin.

**So the next step is the digest, not the door.** It is the only remaining item that is neither
blocked on a decision nor speculative:

- It gives the claim mechanism its first real counterparty, which is what §13a says has to come
  before §13.4.
- It makes the release question concrete, and it will probably **contradict §13.4's assumption**.
  That section borrows the plugin-lifecycle shape — graceful disconnect plus heartbeat timeout — but
  a same-plugin producer never disconnects; its claim outlives it as a fact in the log. The trigger
  is more likely a lease or a re-assertion, which §13.5's "no claim expiry" would have to bend for.
  Better to learn that from a claimant than to design a release for a lifecycle that does not apply.

⚠️ **Watch for the outcome that vindicates §13b.** The digest may never need to claim anything: with
rules as data (P0), a rule can say a source is the digest's and the per-event relay simply does not
fire for it. Being scheduler-driven makes the digest a separate *component*; it does not stop the
table from deciding whether the event-driven half runs — which is the step §13a's defence of §13
skips. If that is what building it shows, the claim mechanism can be left dormant rather than
extended, and §13.4 becomes a bug in unused code rather than a gap to close.

**And 15.2 moves to last.** A same-plugin digest is compiled alongside the events it reads, so it
needs no raw consumption. The only thing that does is a rule table arriving at runtime naming event
types nobody compiled — which needs both the door *and* §14's vocabulary decision first. The
metadata half shipped (§15.2) precisely so the posture, whenever it comes, lands in a slot that has
already been checked against its out-of-repo consumer.
