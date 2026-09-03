# Infrastructure Outside the Capability Model

**Status:** Analysis
**Date:** 2026-09-03
**Subject:** The provider-specific infrastructure the framework provisions that
predates the capability model — the **scheduler** as the worked case
([Scheduler_Adapter.res](../../reventless/core/src/components/Scheduler/Scheduler_Adapter.res),
[ScheduledPublisher_CloudWatchEvents.res](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents.res),
[LocalScheduledPublisher.res](../../reventless/local/src/adapter/Scheduler/LocalScheduledPublisher.res)),
then MCP, auth, the task bucket, live updates, counters, the query store and
monitoring.
**Question:** Three capabilities are declared, gated and provisioned through one model. A good deal of other infrastructure is provisioned some other way, having been built before that model existed. Which of it belongs in the model, what would moving it cost, and where is the boundary?

---

## Summary

- **Two of the eight things surveyed belong in the model; the rest correctly do
  not.** The scheduler and MCP are capabilities built before there was a model to
  put them in. Auth is a separate question, and the task bucket, live updates,
  counters, the query store and monitoring are substrate or seams — §5 gives the
  rule that separates them.
- **The scheduler fits precisely, and is the closest thing to a capability that is
  not one.** It already has the hard half — a provider-neutral port with two
  implementations behind it. What it lacks is the half the capability model adds:
  a declaration, a deploy gate, a modelled failure, and provenance (§2).
- **The gap is not cosmetic.** Because nothing declares it, it is provisioned
  unconditionally — every deployment carries an IAM role granting `events:*` on
  every resource, whether or not anything is ever scheduled (§3.1). Because
  nothing gates it, a task that cannot schedule logs at `info` and continues
  (§3.2).
- **The two implementations disagree about what the vocabulary means**, which is
  the property the capability model exists to protect. `Single` fires at an
  absolute time on AWS and **immediately** in local; `Daily`/`Weekdays` ignore the
  wall clock entirely in local, firing 24h after creation (§3.3). This is a defect
  today, independent of any model change, and should be fixed first.
- **One latent defect falls out of the reading.** The AWS arm emits
  `cron(m h * * * *)` for `Daily`, with `*` in both day-of-month and day-of-week —
  a form EventBridge rejects, and one its own sibling arms avoid by using `?`.
  Unexercised: no example or test uses `Daily`, `Weekdays` or
  `WeekdaysAndSaturday` (§3.4).
- **There is one genuine structural mismatch**, and it is worth being honest
  about: capabilities are called *outward* from a slice's `translate`, and the
  scheduler is wired *inward* into components that fire events. The declaration
  and gate transfer cleanly; putting `schedule` on `Capabilities.t` does not
  (§4.3).
- **`Capabilities.t` is misnamed and should be `OutboundCapabilities.t`.** It
  reads as the roster; it is the two capabilities an outbound translation can
  call, and it is handed to exactly one thing. Direction is the membership rule
  §4.3 arrived at, it predicts the whole roster, and unlike the current name it
  cannot over-claim as the set grows (§6).
- **Three things belong on that record that are not there.** The object store's
  read half (already owed, and the type says so), secrets (no runtime seam exists
  at all), and outbound HTTP — the last scoped as a *broker* rather than a
  provider, because it fails the swap-the-supplier test but would make
  `externalSystem` an enforced declaration instead of a diagram label (§8).
- **The word "capability" carries four meanings in this repository and two more
  outside it**, and only one is a problem. Inside: "platform capability" is
  established (37 uses) and the domain sense is already "competency". Outside, the
  commercial analysis calls the same thing an **infrastructure capability** —
  a deliberate second register for an EA audience, not drift. What needs fixing is
  `GraphQL_FragmentGenerator`'s `serverCapability`, a pure homonym, plus glossary
  entries so nothing arbitrates by accident (§7).
- **The strongest other candidate is MCP**, which is a per-platform boolean
  (`mcpSupported`) where it wants to be a declared need. Auth, the task bucket,
  live updates and counters are surveyed in §5; monitoring is the useful
  counter-example of something correctly kept out.

---

**How this is organised.** §§1–4 work the scheduler end to end, because it is the
richest case and the one that exercises every part of the model — declaration,
gate, provisioning, failure vocabulary, and the one place the analogy breaks. §5
applies the same tests to everything else the framework provisions and says where
the boundary falls. §§6–8 are about naming and growth, all three falling out of
§4.3: §6 argues that `Capabilities.t` is misnamed, §7 cleans up the four senses of
"capability" across the repository, and §8 proposes what else belongs on the
record. §§9–10 are the recommendation and its risks.

---

## 1. The worked case: what the scheduler is today

It is a **Component**, not a capability — `ComponentType.Scheduler`, alongside
`Aggregate`, `EventLog` and `QueryDb`. That single fact explains most of the
differences that follow.

The shape is the framework's standard adapter sandwich:

| Layer | Module |
|---|---|
| Spec vocabulary | `Reventless.Schedule` — `rate`, `schedule`, `create`, `delete` |
| Deploy-time types | `ReventlessInfra.Scheduler` — `outputs`, `operations` |
| The port | `Scheduler_Adapter.ScheduledPublisher` (a `make` returning resource + operations) |
| The builder | `Scheduler_Builder.Make(ScheduledPublisher)` |
| AWS | `ScheduledPublisher_CloudWatchEvents` — an IAM role; `PutRule`/`PutTargets` at runtime |
| Local | `LocalScheduledPublisher.Make(Bus)` — `setInterval`/`setTimeout` over the in-process bus |

**It is provisioned unconditionally.** `deployPlatform` "creates the scheduler,
builds each plugin, creates admin components internally"; `makeScheduler()` is
called from the platform path with no condition attached, on both providers.

**It is reached through component wiring, not through `Capabilities.t`.** The
operations travel as a `Pulumi.Output.t<Scheduler.operations>` into
`ExtensionPoint`, `SideEffectHandler` and `Task` at build time. A slice's
`translate` never sees it.

**Schedules are created at runtime, not declared.** A `Task` returns
`CreateSchedule(schedule)` / `DeleteSchedule(id)` as task actions, and an
extension point can call `createSchedule` directly. There is no static schedule
declaration on any spec, which means there is also nothing for a build to collect
into `pluginStructure` — the mechanism the other capabilities' declarations ride
on.

---

## 2. Does it fit the capability model?

Testing it against each property the model asserts:

| Property the model asserts | Scheduler today |
|---|---|
| Infrastructure a plugin needs but does not provision | **Yes** — the plugin asks for a schedule; the platform owns the scheduling service |
| A provider-neutral port, so swapping the implementation is a change of supplier | **Yes, already** — `Scheduler_Adapter.ScheduledPublisher`, two implementations |
| …and the *semantics* survive the swap | **No** — see §3.3 |
| Declared by the component that needs it | **No** — nothing declares it |
| Carried to the platform as provenance (`capabilities.json`) | **No** |
| Refused at deploy when declared and unprovisioned | **No** |
| Failure is modelled, with a retry rule stated once | **No** — `promise<unit>`, throws |
| Absence degrades visibly rather than silently | **No** — §3.2 |

So it satisfies the two properties the adapter pattern already gave it and fails
every property the *capability* model adds. That is the answer to "does it fit at
all": it fits the definition precisely — it is simply an older solution to the
first half of the same problem, built before the second half existed.

The doc-site page frames capabilities as "infrastructure a plugin needs but does
not provision: somewhere to put an uploaded image, something that turns an address
into coordinates, something that puts a mail in front of a customer." *Something
that runs a job at 2am* is the same sentence.

---

## 3. What is actually wrong today

The case for moving it is not tidiness. Each of these is a live consequence of the
missing half.

### 3.1 Provisioned always, because nothing declares it

`ScheduledPublisher_CloudWatchEvents.make` creates an IAM role and attaches a
policy with:

```
actions:   events:*
resources: AllResources
```

plus `iam:PassRole` on itself. Every platform deployment carries this, including
the many that schedule nothing. A declared capability would provision on demand,
the way an object store does — and the wildcard grant is exactly the kind of thing
a security review asks about and nobody can justify, because it is not there for
any plugin in particular.

### 3.2 The absence is silent, which is the failure class the gates exist for

From `Task_Builder`:

```rescript
| CreateSchedule(schedule) =>
  switch operations {
  | Some(operations) => await operations.createSchedule(schedule)
  | None => log.info(~comp="Task", "No SideEffectHandler to create schedule")
  }
```

A task that meant to schedule something and could not writes an `info` line and
reports success. Compare the refusal `CapabilityNeed.unmetMessage` produces, which
names the capability, the component that declared it, and the symptom. The whole
argument for the gate is in that contrast.

### 3.3 The two implementations do not agree about the vocabulary

`Reventless.Schedule.rate` is one type with two readings:

| Rate | AWS (`toScheduleExpression`) | Local (`rateToMs`) |
|---|---|---|
| `Minutes(n)` / `Hours(n)` / `Days(n)` | `rate(n unit)` | `n` × ms — **agrees** |
| `Single(y,m,d,h,min)` | `cron(min h d m ? y)` — fires at that time | `setTimeout(fire, 0)` — **fires immediately** |
| `Daily(h,min)` | `cron(min h * * * *)` — daily at h:min | `setInterval(24h)` — **24h after creation, wall clock ignored** |
| `Weekdays(h,min)` | `cron(min h ? * MON-FRI *)` | `setInterval(24h)` — **weekday filter ignored** |
| `WeekdaysAndSaturday(h,min)` | `cron(min h ? * MON-SAT *)` | `setInterval(24h)` — **day filter ignored** |

Only the three interval rates survive a platform swap. This is the exact hazard
the messaging capability was careful about: `Messaging.fromHeader` is shared by the
SES and log transports *so the two platforms cannot present the same deployment
under two differently-escaped names*, and `Messaging.retriable` states the retry
rule once *so no transport invents its own*. The scheduler has no such shared
function — each implementation interprets `rate` independently, and they diverge.

A developer testing a `Daily(2, 0)` report locally sees it fire 24 hours after
boot, concludes the wiring works, and ships something that behaves differently in
production. Nothing reports the difference.

### 3.4 A latent defect in the AWS arm

`Daily(h, min)` emits `cron(min h * * * *)` — `*` in **both** day-of-month and
day-of-week. EventBridge requires exactly one of those two fields to be `?`; the
sibling arms `Weekdays` and `WeekdaysAndSaturday` do use `?` for day-of-month,
which is internal evidence that the `Daily` arm is simply wrong rather than
relying on some looser rule.

It has never surfaced because it is never exercised. A repo-wide search finds
`Daily`, `Weekdays` and `WeekdaysAndSaturday` in exactly three places: their own
definition and the two implementations. **No caller anywhere** — no example, no
test, no framework component.

Which makes the one place `Daily` does appear worth noting. `Schedule.res` carries
it as the type's documented example:

```rescript
let dailySync: Schedule.schedule = {
  name: "DailyCatalogSync",
  rate: Daily(2, 0),  // 02:00 UTC every day
  payload: `{"action": "sync"}`,
}
```

So the first thing a reader is shown is the arm that would be rejected on AWS and
misinterpreted locally. The correct expression is `cron(min h * * ? *)`. **This
wants confirming against the API before the fix is written** — it is read from the
source, not from a failed deploy.

### 3.5 The resource handle misreports what it is

The AWS arm returns:

```rescript
~name=role.name, ~id=role.id, ~urn=role.arn,
~service="CloudWatchEvents", ~resourceType="aws:cloudwatch:EventRule"
```

The resource created is an **IAM role**, described as an EventBridge rule, with
`urn` carrying an ARN — the comment says so plainly: *"urn carries the CloudWatch
Events role ARN … bundled Lambdas read it via `Scheduler.outputs.resource.urn`."*
Overloading `urn` to smuggle a role ARN through to the runtime is the kind of
thing a typed capability handle exists to replace; and since inventory tooling
discovers resources by these tags and types, the misdescription is not purely
cosmetic.

### 3.6 There is no failure vocabulary at all

`createSchedule` returns `promise<unit>` and throws on an unconfigured queue.
There is no `Unavailable` / `Refused` split, so no caller can distinguish "the
scheduling service is having a bad minute, try again" from "this schedule is
malformed and will never be accepted" — the distinction `Messaging.failure` calls
out as *"expensive in both directions"*.

---

## 4. What it would take to make it a real capability

Staged, cheapest and most independent first. Stages 1 and 2 are worth doing
whether or not the rest happens.

### Stage 1 — Converge the semantics (a bug fix, not a model change)

Give `rate` one interpretation both implementations derive from, the way
`fromHeader` and `retriable` are stated once. Concretely: a
`Schedule.nextFireAfter(~rate, ~from)` in the spec package that the local timer
drives from, and a cron/rate renderer beside it that the AWS arm calls. Fix the
`Daily` expression (§3.4) at the same time, and cover all seven arms with tests —
the four that are currently unexercised are unexercised in both providers.

**This has no dependency on the capability model and should not wait for it.**

### Stage 2 — Model the failure

Add a `Schedule.failure` mirroring `Messaging.failure` — `Unavailable` (retry),
`Refused` (a rate the provider will not accept), and probably
`UnsupportedRate(rate)` for a provider whose vocabulary is narrower — plus a
`retriable` stated once. Change `create`/`delete` to return
`result<_, failure>`. This is what turns §3.2's `info` line into something a caller
can act on.

### Stage 3 — Declare it

The declaration is where the transfer stops being mechanical, because
**`capabilityNeeds` lives on `OutboundTranslationSlice` and nothing else**. The
components that schedule are `Task`, `SideEffectHandler` and `ExtensionPoint`.

Two options:

- **A — widen `capabilityNeeds` to the components that can schedule.** Honest, and
  it generalises: any future capability reached by a task or an extension point
  needs this anyway. Cost is a spec-surface change on three component types and
  the `Plugin_Structure` walk that collects them.
- **B — infer it from the task actions.** No new surface: a component returning
  `CreateSchedule` declares the need by construction. But it is inference over
  control flow rather than a declaration, and the framework has an explicit
  position on this — `Capability_Inference` warns and never provisions, because
  *"guessing is a poor basis for creating and destroying infrastructure."* A
  `CreateSchedule` in a branch nothing reaches would provision an IAM role.

**Recommend A.** It matches how every other capability is declared, and B trades a
one-time surface change for a permanent inference nobody can audit.

Then the mechanical parts follow the existing pattern: a `Scheduling` arm on
`CapabilityNeed.t` with its `toString`/`fromString`, a `Scheduling` arm on
`CapabilityManifest.kind`, a `Scheduling` arm on `Platform.capability`, and the
generator picking it up — all of which the existing `Geocoding` arm can be copied
from almost verbatim.

### Stage 4 — Gate and provision on demand

Once declared, `CapabilityNeed.unmet` covers it with no new gate code, and
`makeScheduler()` becomes conditional on the platform's capability list. That is
what retires §3.1's unconditional wildcard role.

Note the ordering hazard the model already documents: the platform deploys first
and cannot read plugin schemas, so this only works through the committed
`capabilities.json` manifests and `generate:platform`. A platform regenerated
before its plugins are rebuilt will provision nothing and refuse — which is the
designed behaviour, but it means Stage 4 lands with a regenerate step in the
release notes.

### 4.3 Should it go on `Capabilities.t`? — No

This is the one place the analogy genuinely breaks, and the answer should not be
forced.

`Capabilities.t` is *"what a slice's `translate` is handed"* — a record of
functions a translation calls **outward** on a request it is already handling. The
scheduler runs the other way: it is wired into components at build time and its
job is to fire events **inward** later. A `translate` has no reason to hold it,
and adding a field every `translate` ignores would make the record's stated
purpose false.

So the recommendation splits the model deliberately:

- **The declaration, manifest, gate and provisioning** — adopt in full. These are
  about *whether the infrastructure exists*, and that question is identical for
  every capability.
- **The injection record** — leave alone. Keep the scheduler reaching components
  through the builder wiring it already uses.

Which surfaces something worth recording about the model itself: `CapabilityNeed`
and `Capabilities.t` are two mechanisms that currently happen to have the same
membership, and it is the *declaration* that generalises. The doc-site page
already documents the object store as a capability that is not on the record; the
scheduler would be a second, and two is enough to call it the rule rather than the
exception.

---

## 5. The survey: everything else the framework provisions

Surveyed against the same definition — infrastructure a plugin needs, does not
provision, and could plausibly be absent.

| Candidate | How it is expressed today | Capability-shaped? |
|---|---|---|
| **MCP** | `mcpSupported: McpSupported \| McpNotSupported` — a **static boolean on the platform module**. AWS deploys a Lambda Function URL; local starts a server in `makePlatform` | **Yes, strongly.** A per-platform constant where the other capabilities have a per-plugin declaration. No plugin can say it needs MCP, and no deploy can refuse when it is missing |
| **Identity provider / auth** | `identityProviderId` config; auto-provisions a Cognito pool and its active-role store when unset. `Auth_Adapter` is a real seam | **Partly.** The provisioning choice ("bring your own pool") is capability-shaped, but every deployment needs auth — so the interesting question is *which* provider, not *whether*. Closer to substrate |
| **Task bucket** | `TaskBucket_S3`, wired by a slice; holds transient input | **Weakly.** The doc page already distinguishes it from a store: no `@storageRef` points at it and it is not provisioned from a declaration. Its lifetime is a slice's, not a deployment's |
| **Live updates / subscriptions** | AppSync Events on AWS, in-process bus locally | **Weakly.** Provider-specific with a neutral port, like the scheduler — but it is how the framework's own read path works, not something a plugin opts into |
| **Counter** | `CounterHandler_DynamoDbStream`; `ComponentType.Counter` | **No.** Framework-internal metering, not a plugin-visible need |
| **QueryDb / QueryEngine / Postgres** | Adapter seam, chosen per deployment | **No.** Substrate. Every plugin needs *a* query store; the choice is the deployment's and is not per-plugin |
| **Monitoring** | `Monitoring.res` — a deploy-time inventory hook, no-op unless an extension registers | **No, correctly.** The source states the position: *"Monitoring/alerting itself is deliberately NOT a framework concern; this only exposes the choke point."* Useful as the boundary marker — a seam for someone else's code, where a capability is infrastructure the framework provisions |

### Ranking

1. **MCP** — the clearest case after the scheduler, and cheaper: it has no runtime
   vocabulary to converge (no §3.3 problem) and no injection question (no §4.3
   problem). It needs a declaration, a manifest arm and a gate, and it is done.
   Today a plugin exposing MCP-shaped surface on a platform built with
   `McpNotSupported` simply has no server, with nothing said at deploy.
2. **Scheduler** — this document. Highest value because of §3.1 and §3.3, but the
   most work.
3. **Auth** — worth a separate analysis rather than a capability arm. The question
   there is whether "bring your own identity provider" wants to be a declared
   capability or stay a provisioning config, and it turns on multi-tenancy
   questions outside this scope.

Nothing else on the list should move. The pattern in the "no" rows is consistent
and worth stating: **substrate every plugin needs is not a capability.** A
capability is something a deployment can coherently not have, which is what makes
a declaration meaningful and a refusal possible.

---

## 6. The record is misnamed

§4.3 concluded that the scheduler should adopt the declaration and the gate but
not go on `Capabilities.t`. That conclusion exposes a naming problem that is
already true, before anything moves.

### What the name claims, and what the type is

`Capabilities.t` reads as *the capabilities*. It is not. It is handed to
**exactly one thing** — `OutboundTranslationSlice.translate` — and nothing else in
the framework receives it. `Plugin_Structure` states the coupling plainly:

> slices are handed `Capabilities.t`, so only they can declare.

Its membership is already a strict subset of the capability model's, and the gap
is documented in the type's own comment: the object store is a capability, is
declared, is provisioned, is gated — and is not on the record. Adding the
scheduler would make two. A name that says "all of them" while meaning "the two an
outbound translation can call" is the kind of thing that reads fine to whoever
wrote it and wrong to everyone else.

### The axis is direction, and §4.3 already found it

The reason the scheduler should not go on this record is that it runs the other
way: capabilities here are called **outward** by a translation handling an item;
the scheduler is wired **inward** into components so it can fire events later.
That is not an observation about the scheduler — it is the membership rule for the
record, stated while looking at one candidate.

It predicts the rest of the roster correctly and without special pleading:

| | Direction | On the record? |
|---|---|---|
| `geocode` | outward — a call, then an answer | yes |
| `messaging` | outward | yes |
| Object store *read* (`Offload.resolve`) | outward | **should be** (§8 #1) |
| Object store *write* (presign) | outward, but the **browser** makes it | no — no translation calls it |
| Scheduler | inward — fires events later | no (§4.3) |
| MCP | inbound — an agent calls the deployment | no |

### Proposal

Rename the module `Capabilities` → **`OutboundCapabilities`**, type stays `t`,
parameter stays `~capabilities`.

- **It names the rule, not a mechanism.** Someone asking "does my new capability
  go here?" gets an answer from the name: does a translation call out to it?
- **It cannot over-claim, which was the original defect.** `Capabilities.t` fails
  because unrecorded capabilities exist. `OutboundCapabilities` covers exactly the
  outward-facing ones, and every capability that is not on the record is not
  outward-facing — so the name stays true as the set grows.
- **It ties to where it is used.** The one component that receives it is the
  **Outbound**TranslationSlice, whose items are `outboundItem`s. The record is the
  outbound services that slice can reach.
- **It keeps the family.** These are capabilities — declared through
  `CapabilityNeed`, provisioned through `Platform.capability` — and a different
  noun would suggest they are a different kind of thing.

Alternatives considered:

| Name | Why not |
|---|---|
| `BrokeredCapabilities` | "Brokered" is the codebase's own word (`[]` means a service the framework "does not broker"), but it names *how* the framework participates rather than *which* capabilities qualify. It also invites the question of what an unbrokered capability would be — there is no such thing |
| `TranslationCapabilities` | Precise and cannot over-claim, but says *who receives it* rather than what membership means, so it stops predicting anything the moment a second recipient appears |
| `RuntimeCapabilities` | Reads well against the build/deploy/run phases, but over-claims in exactly the old way: the object store's presign and the scheduler's operations are reached at runtime too, and neither is on the record |
| `ProvidedServices`, `PlatformServices` | Drop the capability family for no gain, and "platform" is already heavily loaded (`ComponentType.Platform`, `deployPlatform`, the platform stack) |
| `Providers` | Collides badly. "Provider" already means the cloud provider (AWS, local) throughout the docs and adapters, and `Messaging.provider` is a member's own type |
| `Ports` | Taken — "port" is the extension-point / extension contract between plugins |
| `ExternalServices` | Collides with `externalSystem`, which names the *unbrokered* box on a slice's spec — the opposite of what is on the record |

**Cost is small.** Six sites in core name the type
(`OutboundTranslationSlice`, its `_Callback` and `_Builder`,
`AutomationSliceEntryPoint_Ops`, `LocalCapabilities`, and a doc reference in
`CapabilityNeed`). Slice authors write `~capabilities` or `~capabilities as _` and
are untouched; field access (`capabilities.geocode`) is unchanged. It is a
published type in `reventless-spec`, so it is a breaking change for any downstream
that annotates it — a `major`, or a deprecating alias for one release.

---

## 7. The word "capability" carries four meanings

Renaming one type (§6) does not fix the vocabulary around it. A survey of every
`capabilit*` identifier in `reventless/` and `traits/`, and of the prose in
`docs/` and the doc site, finds four unrelated senses plus one borrowed one.

| Sense | Where it lives | Weight | Verdict |
|---|---|---|---|
| **A. The declared, provisioned thing** | `Platform.capability`, `CapabilityNeed`, `CapabilityManifest`, `Capability_*` provisioning modules, `capabilities.json`, `capabilityNeeds`, `requiredCapabilities` | 253 `capability` + 176 `capabilities` occurrences; **37** uses of the phrase "platform capability" in prose | **The primary sense.** Keep |
| **B. The record a translation is handed** | `Capabilities.t` | 43 | A *subset* of A → `OutboundCapabilities.t` (§6) |
| **C. What a domain does** | "competency", in the traits docs | 33 uses, all trait-related. **"business capability" appears zero times anywhere** | **Already solved** — just not written down |
| **D. What a generated query supports** | `GraphQL_FragmentGenerator.serverCapability` = `{filterFields, sortFields}`, plus `emptyCapability`, `deriveServerCapability` | 15 + 2 + 2 | **An unrelated homonym.** Rename |
| **E. The MCP protocol's own field** | `{capabilities: {tools, resources}}` in the MCP server instances | 2 sites | Borrowed vocabulary. **Leave alone** |

Two of these are already fine and one is the actual mess.

**Two senses live outside this repo and must be reconciled, not ignored.** The
commercial analysis works the enterprise-architecture reading at length and
reserves three registers — **business capability** (the archetype altitude),
**component/data capability** (the UI's `isCapable` altitude), and
**infrastructure capability** (this model). Sense A here and "infrastructure
capability" there are the same thing under two names; rule 1 below settles which
belongs where.

One inherited claim needs correcting rather than propagating: that analysis
attributes the phrase "infrastructure capability" to this repo's
`platform-main-capability-provisioning.md`. **It does not appear there** — that
document uses "capability" 31 times and the qualified phrase zero times. The term
was coined in the commercial reading, not adopted from here.

### The rules

**1. Inside this repository the term is "platform capability." Externally it is
"infrastructure capability," and both are correct.** "Platform capability" appears
37 times here and "infrastructure capability" zero, and the identifiers agree with
the majority: `Platform.capability` is the roster type and the doc-site page is
*Platform Capabilities*. But the qualified external form is a deliberate,
already-taken decision in the commercial analysis, where the word sits in a
three-register EA taxonomy and "platform" would collide with *platform
engineering*. These are two registers for two audiences, not a drift to fix:

| Audience | Term | Why |
|---|---|---|
| This repo — code, API, doc site | **platform capability** | The type is `Platform.capability`; the platform is what provisions it |
| EA / commercial / positioning | **infrastructure capability** | Contrasts with business and component capabilities at other altitudes; "platform" is taken by platform engineering |

Both glossaries should say the two name the same thing. What must not happen is a
*third* phrase, or either one used where the other's audience reads it.

**2. Bare "capability" is fine where the module says which sense.** Inside
`Capability_Messaging`, `CapabilityNeed` or `capabilities.json`, sense A is the
only reading available. In prose that spans concerns — a plan, an ADR, a commit
message — qualify it. The failure mode is not ambiguity inside a file; it is a
document that says "capability" four paragraphs apart meaning two things.

**3. Inside this repo the domain sense is "competency," and it is not a synonym
for "business capability."** A **domain trait packages a competency**; a **plugin
is a bounded context**. Neither is a platform capability:

> A **competency** is something the *domain* does — deciding whether to notify a
> recipient, keeping an ordered set of attachments. A **platform capability** is
> infrastructure the *deployment* provides — a mail sender, a geocoder. A trait
> that needs one *declares* it; they are never the same thing.

`trait-notification` is the clean illustration: notification is a competency, and
it declares the `Messaging` platform capability. Collapsing the two words makes
that sentence unsayable.

**But "competency" is not simply the small end of "business capability," and the
commercial analysis already fixes the correspondence differently.** There, a
business capability maps to a **domain archetype** — *"a capability bundled with
its canonical realization pattern"* — at the strategic altitude. A competency is
neither that nor a sub-part of it: it is a **supporting** capability that many
core ones share (notification, attachments, document handling all appear on real
capability maps as supporting nodes), shipped as compiled rules rather than as a
map node. So the relationship is two axes at once — competency sits *below*
archetype on decomposition and *beside* it on core-versus-supporting — which is
why neither "higher-level" nor "lower-level" describes it cleanly.

That is a gap in the register list, not a conflict: the commercial analysis
reserves three registers (business, component/data, infrastructure) and
**competency is not among them**, though this repo uses it 33 times. Proposed as a
fourth, and owned by this repo, since traits are a framework construct.

**4. Rename `serverCapability` → `queryFeatures`.** It means "which fields this
generated list query can filter and sort by" and has no relationship to sense A at
all — it is a homonym that happens to sit two directories away from the real
thing. `emptyCapability` → `noQueryFeatures`, `deriveServerCapability` →
`deriveQueryFeatures`. Confined to `GraphQL_FragmentGenerator`, `QueryDbListQuery`
and `Plugin_Helpers`; internal, so no published-type break.

**5. Leave MCP's `capabilities` alone.** It is the protocol's field name, it
appears only where an MCP server is constructed, and renaming it would make the
code disagree with the spec it implements. Worth a comment so nobody "fixes" it.

### Where the rules live

The doc site has a `glossary.md` with entries for Adapter, Aggregate,
AutomationSlice and Plugin — and **no entry for Capability, Competency or Domain
Trait**, which is why nothing currently arbitrates. Three entries there, plus the
cross-links, is the whole enforcement mechanism:

- **Platform capability** → sense A, pointing at the *Platform Capabilities* page
- **Competency** → sense C, pointing at *Domain Traits*, and saying explicitly
  that it is not a capability
- **Domain trait** → the packaging of a competency

### Cost

Rule 4 is the only code change: three files, ~19 identifier sites, no published
type. Rules 1–3 and 5 are prose and glossary. None of it blocks or is blocked by
§6, and none of it touches the capability model's behaviour.

---

## 8. What else belongs on the record

The membership rule from §6 — *a translation calls out to it* — screens
candidates.
The two current members share four properties worth testing against: called
**outward** during a translation, **provider-specific with a neutral port**, the
**deployment** picks the provider, and **absence is coherent** so a declaration
and a refusal both mean something.

### Strong

**1. Object store read — the acknowledged hole.** `Offload.resolve(~fetch)` needs a
fetch and has no injected caller; the type's own comment says *"the accessor for
it belongs in this record."* This is not a proposal so much as an outstanding
item: the store is already declared, provisioned and gated, and only the read half
is missing. Highest confidence of anything here, and it closes the asymmetry the
doc-site page currently has to explain.

**2. Secrets.** An outbound call to a service the deployment chose needs that
service's credential, and **there is no runtime secrets seam today** — nothing in
the spec or core adapters resolves one. It passes every test: provider-specific
(Secrets Manager, SSM, a mounted file, an env var locally), the deployment owns
the choice, absence is coherent, and the failure splits the same way messaging's
does (unreachable → retry; denied → do not). It is also the natural partner to
#3 — an HTTP broker without credentials only covers unauthenticated calls, which
is not many.

**3. Outbound HTTP — but as a broker, not a provider.** The user-facing case for
this is real and the framing matters, because it **fails the swap-the-supplier
test**: a fetch is a fetch, and there is no second implementation the deployment
would choose between. What it passes is a different test. Today `translate` calls
out directly, which means no timeout or retry policy the framework can state
once, no egress control, no attribution of the call, and a test seam that requires
mocking whatever module the author happened to use.

The strongest argument is that it would make an existing declaration real:
`externalSystem: option<string>` already sits on every outbound slice's spec,
naming the external box drawn in the Event Graph and Context Map. It is a diagram
label and nothing more. If brokered HTTP were keyed by the declared external
system, the picture would be derived from a constraint the runtime enforces rather
than from a string somebody remembered to set.

Recommend it, scoped as a broker — one timeout/retry policy, egress keyed by
`externalSystem`, and a recorded/replayable implementation for tests — and named
so nobody expects a provider choice behind it.

### Speculative but coherent

**4. Model inference.** Bedrock vs a hosted API vs a local model is a genuine
deployment choice, absence is coherent, and the failure split is the familiar one.
The framework already ships MCP, so an outbound slice wanting a classification or
a summary is not a stretch. Worth revisiting once #2 exists — inference without
brokered credentials is not usable anyway.

### Rejected, and why the boundary is there

| Candidate | Why not |
|---|---|
| **Clock / deterministic time** | A test seam, not infrastructure a deployment provisions. Nothing is refused at deploy for want of a clock |
| **Payments, shipping rates, tax** | Domain competencies — that is what traits are for. A payment trait would *declare* Http and Secrets; it is not itself a capability |
| **Push / SMS** | Not new capabilities. They are channels of `Messaging`, and the model already says one need however many channels |
| **Queue / event publishing** | The framework's own substrate, not something a plugin reaches outward for |

The pattern matches §5's: a capability is something the deployment can coherently
not have, and something the framework can stand in the middle of. A domain
competency that happens to call an API is a trait; substrate every plugin needs is
substrate.

### Sequencing

Growth here is cheap by construction — the record's own comment explains that
adding a field breaks only the platforms that construct it and leaves every
`translate` untouched. So the order is driven by dependency, not by cost:
**#1** (already owed), then **#2**, then **#3** (which wants #2 to be useful),
with **#4** left open. Do the §6 rename first if it is going to happen at all: it
is a one-time breaking change, and doing it before three new members land is
cheaper than after.

---

## 9. Recommendation

- **Do Stage 1 now, on its own.** The semantics divergence (§3.3) and the `Daily`
  cron (§3.4) are defects in shipped code and have no dependency on anything here.
- **Do Stage 2 next.** A modelled failure is worth having even if the scheduler
  never becomes a declared capability, and it is what makes §3.2 fixable.
- **Take Stages 3–4 together, after MCP.** MCP is the cheaper proof that the
  declaration path generalises beyond `OutboundTranslationSlice`; doing it first
  de-risks the surface change that Stage 3 Option A requires.
- **Do not put `schedule` on `Capabilities.t`** (§4.3).
- **Rename the record before growing it** (§6). It is a one-time breaking change
  and it is cheapest now — six sites in core, and no slice author affected.
- **Write the vocabulary down** (§7). Three glossary entries and one homonym
  rename (`serverCapability` → `queryFeatures`); no behaviour, no published type,
  and it stops a second phrase for sense A from taking hold.
- **Close the object store's read half** (§8 #1). It is already owed, the type
  says so, and it removes the exception the doc-site page currently has to
  explain.
- **Treat secrets as the next real member** (§8 #2), and outbound HTTP after it,
  scoped as a broker rather than a provider (§8 #3).

## 10. Risks

- **Stage 4 changes what a platform provisions.** Removing the unconditional role
  from a deployment whose plugins do schedule, because a manifest was not
  regenerated, breaks scheduling at runtime rather than at deploy. The gate catches
  the declared case; the risk is a plugin that schedules and has not yet been
  rebuilt to declare it. Sequence the release so declaration ships and is adopted
  before provisioning becomes conditional.
- **Stage 1 changes local timing behaviour** that developers may have
  (unknowingly) calibrated against. A `Daily` that starts firing at the configured
  hour instead of 24h after boot is a fix, but it will look like a regression to
  anyone who built around the old reading.
- **§3.4 is read from source, not reproduced.** Confirm against EventBridge before
  writing the fix.
- **The §6 rename is a published-type break.** `Capabilities.t` ships in
  `reventless-spec`; the six sites are the ones in this repo, and any downstream
  that annotates the type breaks with them. A deprecating alias for one release
  costs little and removes the argument for never doing it.
- **§8 #3 invites scope creep.** A brokered HTTP client is a small thing that
  wants to become a large one — connection pools, circuit breakers, a
  request-signing framework. The scope that earns its place is the four things
  named: one timeout/retry policy, egress keyed by `externalSystem`, attribution,
  and a replayable test implementation. Anything past that should be argued
  separately.
