# Plan: an address is entered once, and the backend finds the point

**Date:** 2026-08-03
**Status:** IN PROGRESS — steps 1–6 built and compiling; step 7 (deploy wiring) open and **blocked on
the D9 decision**, step 8 (docs) not started. See [Build log](#build-log) at the foot for what landed
and what the build taught that the plan had wrong.
**Repos:** reventless-core. A UI-repo change is *anticipated* (D7) but not required by this plan and
not scheduled here.
**Builds on:** [semantic-geo-point.md](./semantic-geo-point.md) (the declared point) and
[host-ui-shell-config-choices.md](./host-ui-shell-config-choices.md) (what made the picker reachable
at all). Both concern the *client* path; this plan is the other one.

## The shape today

A customer's address and a customer's location are two independent facts, set by two independent
commands, with nothing relating them:

| Fact | Written by | Entered how |
|---|---|---|
| `Customers.address` | `Register` / `UpdateAddress` | free text, unverified |
| `Customers.location` | `SetLocation` | a human opens the map picker and searches or clicks |

The picker's search box is its own query string — it is not bound to the `address` field and does not
observe it. So the address is typed twice, in two places, at two times, and `UpdateAddress` leaves
the pin exactly where it was with nothing detecting the drift.

**What is wanted:** a human enters one unverified address string. The backend geocodes it and sets
the point. Later, a UI extension may geocode client-side before the command is sent — and when that
day comes the backend must not geocode the same address again.

## The finding: neither slice component can do this as-is

`OutboundTranslationSlice` is the component designed for exactly this job — an async `translate` that
calls an external service, a tracked TODO list, `maxRetries`, a heartbeat sweep, and an optional
command published back into the system. Its own doc comment describes the shape:

```
Event(s) -> TODO List (read model) -> Translator -> External Service
                                                  -> Command (optional)
```

But it consumes **only** the plugin's DCB event log. Its builder constructs the EventCollector over a
single hard-wired topic
([OutboundTranslationSlice_Builder.res:80-89](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Builder.res#L80-L89)):

```rescript
let allEventTopics = Dict.fromArray([(dcbEventLogName, dcbEventTopicOutputs)])
```

`Customer` is an Aggregate. Its `Registered` / `AddressUpdated` events are on the Customer
EventTopic, never on the DCB log, so this slice cannot see them.

`AutomationSlice` has the opposite halves. It *does* subscribe to any combination of sources —
`Mapping.Make`'s first argument matches an Aggregate `Spec.name` or a DCB source name, validated
against the plugin-wide topic dict
([AutomationSlice_Builder.res:100-121](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Builder.res#L100-L121))
— but its `process` is synchronous and pure. It returns a command; it cannot call a geocoder.

So the capability is split across two components and this feature needs both halves.

## Decisions

### D1. Give `OutboundTranslationSlice` the source model `AutomationSlice` already has

The gap is a framework gap, and closing it makes every outbound slice usable from aggregates — not
just this one. The precedent is sitting in the adjacent builder: `AutomationSlice_Builder` already
takes `~allEventTopics`, derives a source set from the per-source `Mapping.Make` modules, validates
each source name against the topic dict with a message naming the available keys, and filters. The
outbound builder needs the same threading and the same multi-source mapping shape.

Two alternatives, both rejected, and why:

- **Re-model `Customer` as a DCB slice** so it writes to the DCB log. That is a storage-consistency
  decision being made for a UI feature's convenience. `docs/guides/aggregate-vs-dcb-decision-guide.md`
  exists to stop exactly this; a customer's lifecycle is self-contained and stays an Aggregate.
- **A scheduled `Task` sweeping customers that have an address and no point.** No framework change —
  `setup` receives a query engine and a task callback can `PublishCommands`, so this genuinely works.
  It is rejected as the primary shape because it is polling rather than event-driven, and because it
  re-implements by hand the TODO list, retry counter and sweep the outbound slice already owns. It
  stays as the **fallback** if D1's framework work is out of budget: same `translate` logic, same
  commands, different trigger.

**The honest cost:** D1 is core framework work with its own tests, not app work, and it is the
largest item in this plan. Everything else is small by comparison.

**What was actually built is simpler** — a flat `sourceNames` list rather than per-source `Mapping`
modules, because an outbound slice has no per-source `resolve` to vary. See step 1 for the reasoning
and the limit it accepts.

### D2. The geocoder must be swappable — and the plugin must not know which one it is

**Superseded in part by D9**, which decides *how*. This decision records *why* it is not a free
choice, because the obvious implementation is blocked.

The obvious thing — `translate` calls the AWS Location adapter — does not compile, and the reason is
architectural rather than incidental. A plugin package is **provider-agnostic**: it depends on
`reventless-core`, never on `reventless-aws`. A plugin that imported the AWS adapter would be a
plugin that only ever deploys to AWS.

So geocoding needs a *seam*: the plugin says "geocode this address", something else decides that
Amazon Location is what answers. D9 picks the seam. What is settled here is what sits on the
plugin's side of it regardless: the vocabulary (`candidate`, `failure`) and the confidence rule
(`confidentMatch`), which are identical for every provider and therefore belong in
`Reventless.Geocoding` — decided once, so no transport re-invents "is this match good enough".

Whichever seam D9 picks, the geocoder's **error contract** has to change. As shipped,
[Geocoder_AwsLocation_Ops.res](../../reventless/aws/src/adapter/Geocoder/Geocoder_AwsLocation_Ops.res)
returned `200 []` for **every** failure: a thrown SDK error, an unset `PLACE_INDEX_NAME`, an empty
query, and a genuinely unknown address were indistinguishable to the caller.

That is correct degradation for a search box — a form should not explode because geocoding is down.
It is fatal for an unattended translator, because "no such address" and "AWS Location is down" become
one signal, and a single outage would mark every address in flight permanently unresolvable.

So the response gains a status-code contract: `200` with a (possibly empty) array is *an answer*;
any other status is *no answer*. A browser reads the body and degrades to "no results" whether or not
it checks the status, so nothing on that side changes; an unattended caller reads the status and
knows whether to retry. One contract serves both because they disagree only about which half of the
response they read.

Per the repo's bindings convention the `@aws-sdk/client-location` externals — previously inline in
the Ops file — move into `rescript-aws-sdk`, and `Relevance` is added there so D3 is expressible at
all.

### D3. Confidence is part of the answer, not a detail

The current bindings carry `place = {Label, Geometry}`. `Relevance` is neither bound nor returned,
and the handler asks for `maxResults: 5` and hands back a ranked but unscored list.

An unattended translator taking `results[0]` cannot tell a pinpoint match from a vague one. "Springfield"
resolves to a confident marker in the wrong state — a plausible pin drawn without an error, which is
precisely the failure mode `GeoPoint.t` was introduced to eliminate one level down. Binding
`Relevance` and applying a threshold is therefore not an enhancement; it is what makes the automated
path safe enough to run unattended.

Below threshold, or several candidates clustered near the top, is **not** a point. It is D4's third
outcome.

### D4. Three outcomes, mapped onto `translate`'s result type

`translate` returns `result<option<command>, string>`, where `Error` drives the retry counter. That
gives exactly the three arms this needs, and the mapping matters:

| Outcome | Returns | Effect |
|---|---|---|
| transient — timeout, throttle, 5xx | `Error(msg)` | retried to `maxRetries`, then swept by the heartbeat |
| resolved above threshold | `Ok(Some(SetLocation({location, resolvedFrom})))` | the point is set |
| no match, or ambiguous per D3 | `Ok(Some(MarkAddressUnresolvable({address, reason})))` | recorded as a fact, **not** retried |

The third row is the one worth being deliberate about. It is a *success* of the translation that
reports a negative outcome. Modelling it as `Error` would retry a permanently bad address forever;
modelling it as `Ok(None)` would leave `location: None`, which already means "not geocoded yet" — and
a state that means two things is a state nobody can act on.

### D5. A point always travels with the address it belongs to

The aggregate's state grows `location` and `locationResolvedFrom: option<string>` beside `address`.
`AddressUpdated` clears both, and *that* is the re-geocode trigger — the one piece of state that makes
the whole loop decidable. `locationResolvedFrom` also records an address that was *tried and failed*
(D4's third outcome), which is why it is a separate field from `location` rather than derivable from it.

The rule the whole design turns on: **whoever supplies a point supplies the address it belongs to.**
Two commands satisfy it from opposite sides, and they are not interchangeable:

| | `SetLocation({location, resolvedFrom})` | `SetAddressLocation({address, location})` |
|---|---|---|
| Written by | the geocoding slice | a UI |
| Surface | `@noApi` | in the API |
| Writes `address`? | no | yes |
| `resolvedFrom` means | "this is the address I geocoded" | n/a — the address *is* the payload |
| If the address has moved on | **ignored as stale** | applies; the caller is the authority |

That last row is why one command cannot serve both. The slice's answer is a *report about a past
address* and must lose to a subsequent change; a human's is an *assertion about the present* and must
win. Same payload shape, opposite staleness rules.

**`resolvedFrom` is therefore a staleness token, not only provenance.** A `SetLocation` whose
`resolvedFrom` no longer equals the current address returns `Ok([])`. Without that check a late
geocoder answer for `"123 Main"` lands after someone has changed the address to `"789 Pine"`, and the
row shows the new address beside the old address's pin — a disagreement with nothing to flag it.

### D6. `SetLocation` stays `@noApi`; a UI corrects through `SetAddressLocation`

Variant-level `@noApi` drops a command from the generated mutations while leaving internal publishing
through the command topic untouched (precedent:
[PluginSpec.res:12-24](../../reventless/core/src/plugin/lifecycle/PluginSpec.res#L12-L24)).

The earlier version of this decision accepted "no UI path to fix a wrong pin" as a cost. It does not
have to be one. `SetAddressLocation` gives a UI everything it needs — including the pin-only fix,
which is just the same address with a new point — while D5's invariant means a client never has a
reason to send a bare point. So `SetLocation` stays internal not by sacrifice but because nothing
outside wants its shape.

**`SetAddressLocation` emits its own event, `AddressLocated({address, location})`.** Emitting
`AddressUpdated` instead would put the row straight back into the slice's `collect`, spending a
geocoder request on an address a human just pinned by hand and then racing the machine's answer
against theirs. `AddressLocated` is not in the slice's `consumedEvent`, so the slice stands down.

`location` on it is **required**. Optional would make `SetAddressLocation({address, location: None})`
a second spelling of `UpdateAddress`, and a caller would have two ways to say one thing. Instead the
command carries the intent:

| Intent | Command | Geocoder runs? |
|---|---|---|
| new or corrected address, find the point | `UpdateAddress` | yes |
| the address is right, the pin is wrong | `SetAddressLocation` (same address, new point) | no |
| both wrong, and the client already has the point | `SetAddressLocation` | no |

`MarkAddressUnresolvable` stays `@noApi` — it is the machine's verdict on its own attempt, not
something a caller asserts.

### D7. Forward-compatibility lives in `collect`, not in the schema

`Register` does **not** gain an optional `location` in this plan. If it did, AutoUI would render a
full maplibre map inline on the register form — the geo input is registered against the `GeoPoint`
semantic and binds to any such field — and that picker's search box is a separate string from
`address`, so a user would type the same address twice on a single form. That is worse than the
two-step it replaces.

When the UI extension lands and a client can supply a point, the UI switches command — `UpdateAddress`
becomes `SetAddressLocation` — rather than starting to fill in a field, and `Registered` gains its
optional point *then*, and the slice's `collect` returns `[]` for any event that already carries one. `collect` is
the single place the question "did the client already geocode this?" is asked, and answering it there
means the slice needs no reshaping on that day — only one more arm in a function that already exists.

### D8. Two skip guards, doing two different jobs

Both, not either:

- **`collect`, before the call** — an event that already carries a point yields no TODO row. This is
  the guard that saves the geocoder *request*, and the request is what costs money.
- **The aggregate, after the call** — a `SetLocation` whose point and `resolvedFrom` already match the
  current state returns `Ok([])`, per the repo's idempotency convention. This is the guard that
  prevents duplicate *events* and it is the one that survives at-least-once redelivery.

The first alone is not correct under redelivery; the second alone pays for every duplicate geocode.

### D9. How the plugin reaches a geocoder — the seam itself

D2 established that the plugin cannot name a provider. So something has to hand it one. There are
three ways to do that, and they differ in *when* the provider is chosen and *what catches the
mistake* when it is chosen wrongly.

The question to keep in view while reading: **at what moment does this deployment decide that Amazon
Location is the geocoder, and what happens if that decision never gets made?**

#### Option 1 — pass the geocoder in, as an argument

The framework hands `translate` the services it may use, the way `Offload.resolve(payload, ~schema,
~fetch)` already takes its uploader as an argument rather than looking one up.

```rescript
// the port, in Reventless.Geocoding
type search = (~text: string) => promise<result<array<candidate>, failure>>

// the slice
let translate = async (id, item, ~services) =>
  switch await services.geocode(~text=item.address) { … }
```

Whoever starts the Lambda decides which implementation goes in the bag. The plugin never names one.

- **Chosen when:** the framework builds the services bag, at startup.
- **If it's never chosen:** it will not compile. The bag is a required argument.
- **Cost:** `translate`'s signature is framework-owned, so *every* outbound slice in every repo
  absorbs the change. And the bag accretes — geocoder today, mailer and SMS gateway later — so the
  framework ends up curating a list of services it did not want to have an opinion about.

#### Option 2 — a slot the framework fills at startup

`Reventless.Geocoding` holds a mutable slot. The Lambda entry point fills it during cold start,
before any handler runs. `translate` reads it. This is what the UI side does: `MapMode.init` puts a
geocoder into a `ref` that the map's command input reads later.

```rescript
// framework entry point, at cold start
Geocoding.provider := Some(awsLocationSearch)

// the slice, later
switch await Geocoding.search(~text=item.address) { … }
```

- **Chosen when:** cold start, in the entry point.
- **If it's never chosen:** nothing complains at build time. `translate` finds an empty slot and
  fails on the first real address, in a Lambda, in production.
- **Cost:** that hole is not hypothetical. ES modules evaluate imports *before* the importing
  module's body, so "the entry point runs first" is an assumption, not a guarantee — and a new
  entry-point variant or a bundling change can quietly break it. This repo has already paid for two
  bugs of exactly this shape (a deploy-time import reaching a Lambda's cold-start graph, and a
  serialized closure mixing SDK versions). A slot that must be filled before first use is a promise
  with nothing enforcing it.

#### Option 3 — the seam is the HTTP contract, and the deployment points it at a provider

Geocoding already crosses a network. So make *that* the boundary: the plugin calls whatever URL its
environment gives it and speaks a small documented contract — a JSON array of
`{label, lat, lng, relevance}`, `200` for an answer, anything else for no answer.

```rescript
// the plugin — provider-agnostic by construction
let search = async (~text) => {
  let url = `${endpoint()}?q=${encodeURIComponent(text)}`
  …
}
```

Nothing is injected, because there is nothing to inject. The platform already computes the geocoder's
URL (it writes it into `config.json` for the browser); the same value goes into the slice's Lambda
environment. Swapping Amazon Location for Nominatim, a commercial API, or a stub in dev is a change
of *URL*, not of code — and a plugin written against this contract runs unchanged on a platform that
has never heard of AWS.

- **Chosen when:** deploy time, by the stack that sets the environment variable.
- **If it's never chosen:** the plugin gets no endpoint and returns `Unavailable` — which is already
  a modelled outcome (D4), so it retries and the sweep surfaces it, rather than crashing.
- **Cost:** the contract is a wire format, so it is checked when it is called, not when it is built.
  A provider swapped behind the URL that answers a different shape fails at the first request. That
  is the standard trade for any adapter that crosses a network, which every other remote adapter here
  already makes.

#### Recommendation: option 3

It is the only one of the three where the *deployment* chooses the provider, which is what
provider-independence has to mean in practice — a plugin that runs on a non-AWS platform without
being recompiled. Option 1 gets that too but bills every existing outbound slice for it and starts
the framework down the road of curating a service catalogue. Option 2 is the cheapest to write and
the one whose failure mode is invisible until production, which is the wrong thing to be cheap about.

It also settles what looked like a loose end. `Geocoder_AwsLocation_Backend` is not an orphan under
option 3 — it is the implementation *behind* the URL, running in the geocoder Lambda the platform
already provisions. That makes D2's status-code contract the load-bearing piece of this whole design
rather than a tidy-up: it is the seam.

Option 1 stays the obvious escalation if a future service genuinely cannot be reached over HTTP, or
if a compile-time guarantee is worth the churn. That is a decision to make when there is a second
service, not now.

## Steps

**1 — `OutboundTranslationSlice` takes aggregate sources (`reventless/core`, `reventless/infra`). ✅**
Thread `~allEventTopics` into `OutboundTranslationSlice_Builder` and let the Spec name its sources.
Existing single-DCB-source slices must keep compiling unchanged — `SendOrderConfirmation` in two
examples is the regression check.

*Built smaller than planned, deliberately.* The plan said "mirror `AutomationSlice`'s per-source
`Mapping` modules". That machinery exists because an automation needs a **`resolve` per source** — a
different event completes the item depending on where it came from. An outbound item is resolved by
its own `translate` succeeding, so the only thing that varies per source is the *decode*, and the one
`consumedEvent` union already covers that. So sources are a flat `let sourceNames: array<string>`
(`[]` = this plugin's DCB log, preserving every existing slice) rather than a mapping set. Known
limit, written into the Spec's doc comment: two sources sharing an event-type name are
indistinguishable.

*One thing the plan missed.* `collect` received only the decoded event, so it could not know **which
entity** the event was for. DCB events name their own subject in the payload (`OrderPlaced({orderId,
…})`); an Aggregate's event does not, because the aggregate id is what addressed it. `collect` now
takes `~sourceId` from the envelope. This is a breaking signature change for existing slices — five
call sites, all updated.

**2 — Location bindings (`rescript/aws-sdk`). ✅** `@aws-sdk/client-location` externals moved out of
`Geocoder_AwsLocation_Ops.res` into the bindings package, with `Relevance` added so D3 is expressible.
The Function-URL handler now returns `502` on a service failure (body still `[]`) and carries
`relevance` through — see D2 for why one contract serves both callers.

**3 — The vocabulary, the policy, and an AWS transport. ✅ (final placement pending D9)**
`Reventless.Geocoding` holds `candidate`, `failure` and `confidentMatch` — provider-neutral, so no
transport re-invents the confidence rule. `Geocoder_AwsLocation_Backend` (runtime-pure, no Pulumi in
its cold-start graph) is the SDK-backed transport returning that vocabulary. **D9 decides what this
module is for**: under option 3 it is the implementation behind the geocoder URL; under options 1–2 it
is the thing injected into the slice.

**4 — The `Customer` aggregate (hybrid example). ✅** As planned.

**5 — The slice (hybrid `ordering` plugin). ✅ (its geocoder call depends on D9)**
`GeocodeCustomerAddress` under `OutboundTranslationSlice/`: `collect` over `Registered` /
`AddressUpdated` keyed `{customerId}:{address}` — keying by customer alone would make a later address
change look like work already done; `translate` per D3–D4; `targetName = Some("Customer")`;
`externalSystem = Some("AwsLocation")`. Currently reaches its geocoder through a plugin-side HTTP
client (`Service/GeocodingService.res`), which is option 3's shape — **confirm or replace per D9.**

**6 — The read model. ✅** `locationStatus: Pending | Located | Unresolvable` (marked `@status`, so
the generated view sections by it) plus a `@hidden locationNote` carrying the reason. An
`AddressUpdated` resets the row to `Pending` and clears the point — leaving the old pin beside a new
address would show two facts that disagree, with nothing saying so.

**7 — Deploy wiring. ⛔ blocked on D9.** What gets threaded depends on the seam: option 3 needs the
platform's geocoder URL in the slice Lambda's environment (`GEOCODER_ENDPOINT`), read across stacks
the way other platform outputs already are; options 1–2 need place-index read permission on the
slice's own Lambda instead. Follow the existing capability threading either way rather than inventing
a second path to the same resource.

**8 — Docs. ⬜ not started.** The outbound-slice documentation gains its new source model and the
`~sourceId` argument; the geo docs gain the sentence that matters — the picker is the client path,
this slice is the unattended one, and D8 is why they do not collide. If D9 lands on option 3, the
geocoder wire contract is documentation, not a comment: it is the port.

## Verification

- **`translate` unit-tested through `whenTranslateMocked`** — the three D4 outcomes, and specifically
  that a service failure retries while a no-match does not.
- **`collect` GWT** — an `AddressUpdated` yields a row; an event already carrying a point (D7's
  future shape, testable ahead of the UI) yields none.
- **Aggregate GWT** — a redelivered `SetLocation` with matching point and `resolvedFrom` yields
  `Ok([])`; one with a changed address yields the event.
- **The two existing single-source outbound slices still compile and pass** — step 1's real risk is
  regression, not the new capability.
- **End to end on the hybrid** — register a customer with a plain address, and the pin appears
  without anyone opening a map. This is the whole plan in one sentence and it is the check that
  matters.
- **Zero warnings** after a full build, and no `.res.mjs` deletions (`git ls-files --deleted`).

## Out of scope

- **Client-side geocoding.** D7 names its shape and stops there. It is a UI-repo change with its own
  plan, and this plan is deliberately built so that it arrives as one `collect` arm.
- **A remediation UI for unresolvable addresses.** D6 removes the only current path and accepts the
  gap; giving it back is a real design question about who is allowed to override a geocoder.
- **Address normalisation.** The geocoder returns a canonical `label` and this plan discards it,
  storing only `resolvedFrom` (what was typed). Writing the canonical form back over a user's address
  is a product decision, not a technical one.
- **Batch re-geocoding of existing customers.** The heartbeat sweeps *pending* items, not historical
  ones. Backfilling is the `Task` shape from D1's rejected alternatives, which is why it stays
  documented there.

## Follow-ups

- **The `Task` fallback, if step 1 does not fit.** Same `translate` body, same commands, a schedule
  instead of a subscription. Worth writing down before it is needed, because the decision point is
  step 1 and not later.
- **`InboundTranslationSlice` symmetry.** If outbound gains aggregate sources, inbound's source model
  is worth the same look — not because anything needs it today, but because two translation
  components with different source rules is the kind of asymmetry that gets discovered by accident.
- **A relevance threshold that is not a constant.** D3 picks one number. What it should be is an
  empirical question this plan has no data for, and the first real corpus of addresses is what
  answers it.

## Build log

What landed, and what building it taught that the plan had wrong. Recorded here rather than folded
silently into the decisions above, because two of these were the plan being mistaken about the
framework rather than choices between known options.

### Landed and compiling (full build clean, zero warnings)

| Area | Files |
|---|---|
| outbound slice takes aggregate sources | `OutboundTranslationSlice.res` (spec), `_Builder.res`, `_Callback.res`, the `infra`/`core` module types, `Dcb_Builder.res`, the AWS pass-through builder |
| `~sourceId` threaded to `collect` | the same, plus `OutboundTranslation_GWT` / `Flow_GWT` and five existing call sites |
| Location bindings | `rescript/aws-sdk/src/Location.res`, `Geocoder_AwsLocation_Ops.res` repointed and given its status-code contract |
| geocoding vocabulary + policy | `reventless/spec/src/semantic/Geocoding.res`, tested in `reventless/core/tests/api/GeocodingTest.res` |
| AWS transport | `reventless/aws/src/adapter/Geocoder/Geocoder_AwsLocation_Backend.res` |
| the aggregate, the slice, the read model | `Customer.res`, `Customer_Behavior.res`, `GeocodeCustomerAddress{,_Translation}.res`, `Customers{,_Projections}.res`, `Service/GeocodingService.res` |

### What the plan had wrong

1. **The framework change was smaller than budgeted.** D1 called `AutomationSlice`'s mapping
   machinery the thing to copy. Copying it would have been cargo cult: the per-source structure
   exists to give each source its own `resolve`, and outbound slices resolve on translate success.
   A flat source list does the whole job.
2. **`collect` could not name its subject.** The plan assumed an event carries enough to build an
   outbound item. True for DCB events, false for aggregate events, and invisible until the first
   aggregate-sourced slice existed — which is this one. Fixed by threading the envelope's id.
3. **`translate` could not call the AWS adapter at all.** The plan's step 3 assumed it could. Plugins
   are provider-agnostic and cannot depend on `reventless-aws`, so the whole seam question (D9) was
   forced by a compile error rather than foreseen. That is the one that changed the design.

### The correction round (D5/D6 revised)

Reviewing D6 surfaced a defect that would have shipped: the idempotency guard compared only the
address, and the aggregate state did not carry the point at all — so a human correcting a wrongly
placed pin for an unchanged address matched the guard and got `Ok([])`, their edit discarded with no
error. The guard existed for machine retries and silently forbade the human path it was never asked
about.

A second, related hole was live at the same time: nothing dropped a *stale* machine answer. After
`AddressUpdated` cleared the provenance, a late geocoder result for the previous address was accepted
and pinned the row's new address at the old one's point.

Both are fixed, and the fix reshaped the command surface — see the revised D5/D6. `SetLocation` stays
`@noApi`; `SetAddressLocation({address, location})` is the client-facing pair; `resolvedFrom` became a
staleness token; the aggregate state carries `location`. The seed moved to `SetAddressLocation`,
which is the honest shape for it — it always knew both halves, and sending them together also stops
the slice spending a geocoder request per seeded customer.

### Open

- **D9 is undecided** and steps 7–8 wait on it. Step 5's geocoder call is currently written in
  option 3's shape (recommended); options 1 and 2 would replace `Service/GeocodingService.res` with
  an injected port.
- **Nothing has run against a real geocoder.** Every test mocks `translate`, so the wire contract in
  D2 — `200` is an answer, anything else is not — is asserted nowhere. It is the first thing a
  deployed run would exercise, and the first thing likely to be wrong.
