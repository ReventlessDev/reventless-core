# Plan: an address is entered once, and the backend finds the point

**Date:** 2026-08-03
**Status:** ✅ **COMPLETE — all ten steps built, deployed and verified on the live `alpha` stack.**
Closed 2026-08-30. The status this replaced had gone stale: it still described step 10 as awaiting a
release and deploy, and blocker 6 as open, both of which had been resolved by deploys that ran while
nobody updated this line.

Verified read-only against the deployed stack on 2026-08-30:

| Claim | Evidence |
|---|---|
| step 10 deployed — the client door open, the Function URL closed | the `geocoderEndpoint` export is **absent** from the stack's 41 outputs and no Function URL resource remains; only `geocoderPlaceIndex` (`online-shop-geocoder`) is left, which the resolver still needs |
| deployed from the branch tip | `deploymentMetadata.gitSha = 989bd1c36`, `2026-08-27T14:48:44Z`, actor `github-actions[bot]` — the current head of `alpha` |
| **blocker 6 closed** — the sweep has a caller *and* a schedule | `builtSlice.sweep` + `runSweeps` exist for a scheduled invocation carrying no records, the entry point reloads unfinished TODO rows from the view table on a cold container, and EventBridge rules `alpha-AllAutomationSlicesSweep-*` are ENABLED at `rate(5 minutes)` |
| blocker 7 closed | fixed in code and carried by the deploys since |

Two durable results worth keeping visible, because other work cites them:

- **D9 is resolved** — geocoding copies the object store's two-door shape. The backend reaches
  `translate` as an injected capability calling the SDK, not an HTTP client; the browser reaches it
  through the platform API's `Query.geocode`.
- **D3 is calibrated against the live Esri index** — the shipped `0.8`/`0.1` declined correct
  addresses at a 1-in-4 rate and is replaced by `0.97`/`0.01`; see [the measurement
  round](#the-measurement-round-d3-calibrated-against-a-real-index).

⚠️ Noted while verifying, not diagnosed: the live account carries **two** of each scheduled rule
(`alpha-AllAutomationSlicesSweep-0109c4f` and `-abb7702`, and two heartbeats per plugin). Either two
estates share the region or a prior deploy left orphans. Worth a look on its own; it does not affect
anything this plan built.

See [Build log](#build-log) at the foot for what landed and what the build taught that the plan had
wrong, and the rounds below for the full history.
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

**The numbers have since been measured, and the first guess was wrong in an expensive direction.**
`0.8` / `0.1` was written before anything had spoken to a geocoder; against the live Esri index it
declines *correct* addresses. Esri does not spread its scores over 0…1 — everything it returns at all
lands in roughly 0.9…1.0 — so the floor admitted nearly everything and the margin did all the work at
a width that swallows real winners. The calibration is now `0.97` / `0.01`, and the reasoning is
recorded in [the measurement round](#the-measurement-round-d3-calibrated-against-a-real-index) with
the corpus behind it. What D3 argues does not change; what changes is which of its two guards is
load-bearing.

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

#### The framing above is wrong: two callers, two seams

The three options are an honest map of *how* to hand a plugin a geocoder, but they were posed as if
one seam had to serve every caller. It does not, and the framework already demonstrates that — the
review that produced this section turned up two facts that settle it.

**First: geocoding is already a first-class platform capability**, declared alongside the object
store in [`ReventlessInfra.Platform`](../../reventless/infra/src/types/Platform.res):

```rescript
type capability =
  | ObjectStore({plugin: string, store: string})
  | Geocoding
```

So it was never meant to be a foreign system a plugin happens to call. It is something a deployment
declares, the platform provisions, and the framework brokers — the same standing as an object store.

**Second: the object-store capability answers this exact question twice, differently, and both
answers are right for their caller.**

| Caller | How it reaches the capability | Where |
|---|---|---|
| a client (browser, seed, any API consumer) | a GraphQL field — `Upload_Presign(store: ID!, fileName: String!, contentType: String): Upload_Ticket` | [Platform_AdminApi.res:99](../../reventless/core/src/admin/Platform_AdminApi.res#L99) |
| plugin backend code | an injected function — `Offload.resolve(payload, ~schema, ~fetch)` | [Offload.res](../../reventless/spec/src/semantic/Offload.res) |

A client gets a *published, authenticated API surface*; plugin code gets a *function handed to it*.
Neither is a compromise for the other, and nothing about the object store is duplicated by having
both — they are two doors onto one capability.

#### Resolution: geocoding copies both halves

| Caller | Seam | Which option above |
|---|---|---|
| the browser's map picker | a field on the platform GraphQL API | — (none of the three; this is the upload precedent) |
| the geocoding slice | an injected port, calling the AWS SDK directly | option 1 |

This dissolves both objections that were live during the review, because they turn out to be the
same objection to the same mistake — *reusing a browser-facing service for an unattended caller*:

- **the extra hop.** The slice's Lambda proxying through another Lambda to reach a service it could
  call directly was overhead the backend never needed. Gone: the injected port calls the SDK.
- **the public endpoint.** The geocoder Function URL is unauthenticated by necessity — a browser
  cannot sign a request. Routing the unattended path through it made the backend's availability a
  function of whoever else was hitting a public URL. Gone twice over: the backend no longer touches
  it, and the browser half moves behind the platform API's existing Cognito wiring, after which the
  public endpoint has no callers at all.

It also settles `Geocoder_AwsLocation_Backend`, written during the build and unused since. It is not
an orphan and not a proxy target — it is the thing injected into the slice, and the same module the
platform's geocode resolver will call. One module owns the AWS Location call, the `[lng, lat]` order
and the relevance handling; both doors open onto it.

#### The evidence: the object store already does exactly this

Not a design by analogy — a working precedent with two implementations shipped.

**The client door is a GraphQL contract, and it is genuinely portable.** `Upload_Presign` /
`Upload_Release` are registered on AppSync by the AWS platform and on the dev server by the local
one ([LocalUploadResolvers.res](../../reventless/local/src/adapter/LocalUploadResolvers.res)), backed
by [LocalObjectStore.res](../../reventless/local/src/adapter/LocalObjectStore.res) — a process-local
dict of Node buffers, ephemeral by design, served from `/{prefix}/*`. A client cannot tell which it
is talking to, and local's `deployPlatform` ignores `~capabilities` entirely because it provisions
nothing. So "swap the implementation" has already happened once, and the thing that made it possible
was the mutation contract, not an adapter module.

**The plugin door is an injected function**, `Offload.resolve(payload, ~schema, ~fetch)`. Same
capability, different caller, different seam — and no duplication, because both doors open onto the
same stored bytes.

**Three layers, three different portability answers**, worth separating because only one of them is
actually stuck:

| Layer | Portable? | Why |
|---|---|---|
| the ref format `/{prefix}/{key}` | yes, by design | `keyPrefix`'s own comment: rooting keys at the store name keeps a stored ref independent of whether the store got its own bucket or a prefix in a shared one. Refs live in an append-only log; one that encoded its layout would be unrewritable |
| the runtime read/write path | yes — two implementations exist | `~fetch` is injected; `Upload_Presign` is a contract, not a URL |
| the deploy-time handle | **no** | see below |

**The stuck layer, recorded because this work surfaced it and did not create it.**
`ReventlessInfra.Platform.objectStore` sits in the provider-agnostic layer and is S3-shaped:

```rescript
type objectStore = {
  bucketName: Pulumi.Input.t<string>,
  bucketId: Pulumi.Input.t<string>,
  bucketArn: Pulumi.Input.t<string>,                 // AWS-only concept
  bucketRegionalDomainName: Pulumi.Input.t<string>,  // AWS-only concept
  keyPrefix: string,
}
```

There is also no `module type` port for an object store — nothing declares what an implementation
must satisfy; `Capability_ObjectStore_S3` and `Upload_Presign_S3` carry the provider in their names
by convention alone. So the capability is **switchable by platform** (AWS ↔ local, proven) and **not
switchable within one** (S3 → MinIO/GCS on the AWS platform). That may be the right trade — a
platform package arguably *is* the provider choice — but it means the portability story is "pick a
different platform", not "pick a different backend", and an ARN in the neutral layer is where that
would first hurt. Out of scope here; noted so it is not rediscovered.

**And it hands geocoding something it currently lacks: a local story.** Today
`config.geocoderEndpoint` is unset in local dev, so the map picker is click-to-place only and the
search box does not render — address search simply does not exist outside a deployed stack. Under the
two-door shape the local platform registers its own geocode resolver (a stub, a fixture, or
Nominatim) exactly as it registers `Upload_Presign`, and search works in dev without anyone editing
`public/config.json`. Step 9 is therefore not only "move an endpoint"; it closes a dev-experience gap.

#### Sequencing: the halves have very different costs

**Half 1 — the injected port (this repo, self-contained).** Replaces the plugin's
`Service/GeocodingService.res` with a port in `Reventless.Geocoding`, threaded to `translate` the way
`Offload.resolve` threads `~fetch`. No cross-repo dependency. The `translate` signature change is the
same shape as the `~sourceId` change already made in this plan, which touched five call sites and the
GWT harness — that is the measured size of it, not an estimate.

**Half 2 — the platform API field (cross-repo, lockstep).** The shipped host-shell reads
`config.geocoderEndpoint` and builds its client with `Geocoder.fromEndpoint(endpoint)` *inside the
dynamically-imported map chunk*. Moving it to a GraphQL field is a UI change, a UI release, and a
version bump here, in that order — the lockstep cost the geo work has already paid twice. Only once
that lands can the public Function URL and its config key be deleted.

So half 1 goes now and half 2 goes with the next UI change. Until then the browser keeps using the
Function URL and nothing regresses: D2's status-code contract stays worth having, because it is what
lets the two callers share that endpoint safely during the interval.

A small irony worth recording: half 2 removes `geocoderEndpoint` from `config.json`, a key the
[shell-config work](./host-ui-shell-config-choices.md) built plumbing for. That plumbing is not
wasted — `viewModes` was its point — but this particular key is on its way out.

#### Open, and deliberately not decided here

The slice declares `externalSystem = Some("AwsLocation")`, which draws AWS Location as an external box
in the Event Graph. If geocoding is a platform capability the framework brokers, that box arguably
belongs to the platform rather than to this plugin's diagram — the object store is not drawn that
way. Left as-is for now, because AWS Location genuinely *is* a third-party service and the box is not
wrong, only possibly misplaced. Worth a decision rather than a default.

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

**3 — The vocabulary, the policy, and an AWS transport. ✅**
`Reventless.Geocoding` holds `candidate`, `failure` and `confidentMatch` — provider-neutral, so no
transport re-invents the confidence rule. `Geocoder_AwsLocation_Backend` (runtime-pure, no Pulumi in
its cold-start graph) is the SDK-backed transport returning that vocabulary. Per D9 it is the module
*injected into the slice*, and later the one the platform's geocode resolver calls — one owner for the
AWS Location call, the `[lng, lat]` order and the relevance handling.

**4 — The `Customer` aggregate (hybrid example). ✅** As planned.

**5 — The slice (hybrid `ordering` plugin). ✅ (its geocoder call is replaced in step 9)**
`GeocodeCustomerAddress` under `OutboundTranslationSlice/`: `collect` over `Registered` /
`AddressUpdated` keyed `{customerId}:{address}` — keying by customer alone would make a later address
change look like work already done; `translate` per D3–D4; `targetName = Some("Customer")`;
`externalSystem = Some("AwsLocation")`. Reaches its geocoder through a plugin-side HTTP client
(`Service/GeocodingService.res`). Step 7 makes that client actually reach a geocoder; step 9
replaces it with the injected port D9 settled on.

**6 — The read model. ✅** `locationStatus: Pending | Located | Unresolvable` (marked `@status`, so
the generated view sections by it) plus a `@hidden locationNote` carrying the reason. An
`AddressUpdated` resets the row to `Pending` and clears the point — leaving the old pin beside a new
address would show two facts that disagree, with nothing saying so.

**7 — Make it run: the fast path. 🟨 complete in code; unproven until the next deploy.** Its
prerequisites are confirmed on real infrastructure, the geocoder answers correctly, and the three
reasons it could never have run are all fixed — see [the deploy
round](#the-deploy-round-step-7s-wiring-works-and-two-things-behind-it-do-not).

The resolution above is where this ends up. This step is what gets geocoding *working* before it gets
there, chosen so that nothing done here has to be undone.

Everything on the plugin side is already built and committed — the slice, the vocabulary, the
confidence rule, the HTTP client. **The only reason geocoding does not run today is that nothing sets
`GEOCODER_ENDPOINT` on the slice's Lambda** — but setting it turns out to need two small framework
additions first, neither of which existed when this step was first written. So:

**7a — declare the port type now, even though nothing injects it yet.** In `Reventless.Geocoding`:

```rescript
type search = (~text: string) => promise<result<array<candidate>, failure>>
```

and annotate the plugin's `GeocodingService.search` as satisfying it. This costs nothing today and is
what makes the eventual swap mechanical: the injected implementation has to match a type that already
exists, and the call site in `translate` does not change when the provider stops being an HTTP client.
Writing the port down first is the difference between a shortcut and a dead end.

**7b — two prerequisites, because the wiring this step assumed does not exist.**

An earlier draft called the cross-stack read "the main unknown". Checking it found the situation is
worse and simpler than that: *neither end of the wire is there*. Both gaps are small, neither is a
design question, and one of them is needed by step 9 as well.

**Prerequisite 1 — the platform does not export the geocoder URL.** It is computed inside
`deployPlatform`'s `apply` and consumed by exactly one thing: the `geocoderEndpoint` key in
`config.json` ([Platform.res:2047-2105](../../reventless/aws/src/Platform.res#L2047-L2105)). There is
no stack export, so a plugin stack has nothing to read.

*Solution — write side.* One export beside the platform's existing ones, in the same shape as
`Pulumi.Pulumi.export("offloadBucket", offloadBucketName)`
([Platform.res:1413](../../reventless/aws/src/Platform.res#L1413)):

```rescript
// Exported, not only written into config.json, because a plugin stack's
// components need it too — the browser is no longer the only caller.
Pulumi.Pulumi.export(
  "geocoderEndpoint",
  geocoderEndpointOutput->Pulumi.Output.apply(Option.getOr(_, "")),
)
```

Unset ⇒ `""` rather than a missing output, so the read side has one shape to handle rather than two.

*Solution — read side.* The plugin path already builds a `StackReference` from config and reads
platform outputs through it — `objectStores` is read exactly this way at
[Platform.res:179](../../reventless/aws/src/Platform.res#L179). Add a sibling read there. **The typing
gotcha applies**: `getOutput` returns `Pulumi.Output.t<option<'a>>`, so annotate
`Pulumi.Output.t<option<JSON.t>>` and decode inside the `apply`, as the `objectStores` read does — an
`option<Pulumi.Output.t<_>>` is the shape this repo has a standing rule against.

**A constraint worth stating, because it decides where the code goes:** the plugin stacks'
`Main.res` files are **auto-generated** (`// AUTO-GENERATED — do not edit`). So the read cannot live
in an example's stack root; it has to happen inside `deployPlugin`, which is where the existing
`StackReference` already is. That is the right home anyway — a capability endpoint is framework
plumbing, not something a plugin author should be wiring by hand.

**Prerequisite 2 — there is no env-var channel to a slice's Lambda.** `RuntimeHints.t` is
`{memorySize, timeout}` and nothing else. The runtime builder *does* assemble an `envVars` dict
internally
([AutomationSliceRuntime_Builder_Single.res:200](../../reventless/aws/src/adapter/Runtime/AutomationSliceRuntime_Builder_Single.res#L200),
setting `HANDLER_CONFIG`), so there is a place to put one — but nothing lets anything outside
contribute to it. The target is the single shared `AllAutomationSlices` Lambda, so whatever is added
is a deployment-wide knob, which suits an endpoint and would not suit a per-slice secret.

*Two candidate seams already exist. They are not interchangeable, and picking the wrong one is the
mistake available here.*

**Rejected: `commandHandlerConfig`.** It already carries exactly the right field —
`envVars?: dict<string>` on `ReventlessCore.Runtime.commandHandlerConfig`, transport-neutral by
design ("the in-memory platform honors envVars and ignores the rest"), plumbed
`Platform.MakeWithConfig` → `Config.commandHandlerConfig.<flavor>` → `setConfig` → a module ref →
the Lambda. Tempting, and wrong: that path is for values a **human deployer chooses** (memory,
timeout, tuning). The geocoder endpoint is **derived by the framework** from another stack's output.
Routing it through hand-authored config would mean a deployer copying a generated URL into a config
file — precisely the hand-restated value this framework keeps eliminating elsewhere.

**Chosen: `PluginRuntime_Builder.registerConfig`.** That function already exists to carry
framework-derived deploy values into runtime Lambdas — its current parameters are
`~eventTopicArn`, `~pluginReadModelTableName`, `~schedulerRoleArn`, `~schedulerQueueArn`
([PluginRuntime_Builder.res:146](../../reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res#L146)),
which is the same category of value as a geocoder endpoint: computed at deploy time, needed at
runtime, never typed by a person. Add `~geocoderEndpoint=?`, store it in a ref beside the others, and
have `AutomationSliceRuntime_Builder_Single` merge it into `envVars` as `GEOCODER_ENDPOINT` when
non-empty.

*Checked, and it changed the answer.* `registerConfig` is called from `deployPlatform` and assigns its
record wholesale, while the endpoint is only knowable in `deployPlugin` — so extending it would mean a
second wholesale call wiping the first one's fields. The rejection of `commandHandlerConfig` above
stands and turns out to exclude `registerConfig` too. What shipped is the dict this step suggested as
a nicety: `PluginRuntime_Builder.registerCapabilityEnv`, a separate ref keyed by variable name, merged
into `envVars` by both of `AutomationSliceRuntime_Builder_Single`'s finalizers. See the
[build log](#the-step-7-round).

**Prerequisite 2 is not throwaway work — step 9 needs it too.** The injected port still has to tell
the Lambda *which place index* to use, and the entry point is a bundled module reading its
environment, not a serialized closure that could capture the value. So the env channel gets built on
either route. Only prerequisite 1 is specific to the fast path.

That narrows the real comparison between the fast path and the destination: the fast path's *extra*
cost is one stack export, and what it *defers* is the whole runtime-injection question — how the
platform hands a geocoder to `translate` — which is unresolved and is the same question the capability
model ends on. Deferring it to get a working geocoder is the trade this step is making, deliberately.

**7c — thread it.** With both prerequisites in place the wiring is one line each way: `deployPlugin`
reads `geocoderEndpoint` off the platform `StackReference` and passes it to `registerConfig`; the
slice runtime builder puts it in `envVars`. The plugin code already committed — `GeocodingService`
reading `process.env["GEOCODER_ENDPOINT"]` — then works unchanged, which is the point of having
written it against an env var rather than a provider.

**What this knowingly accepts, for now.** The backend shares the browser's public, unauthenticated
Function URL — the coupling D9 rejects. It is tolerable *temporarily* and for a specific reason: the
endpoint already exists and is already public for the browser, so this adds a caller rather than an
exposure, and D2's status-code contract is exactly what lets the two share it safely in the interval.
It stops being tolerable the moment geocoding volume matters or the endpoint is abused, which is why
step 10 exists and is written down rather than left implicit.

**Two runtime assumptions, checked rather than assumed.** The plugin's client does `fetch` from the
slice's Lambda, which only works if two things hold. Both do: the `AllAutomationSlices` Lambda is
built without `~vpcConfig` (unlike the StateViewSlice and Aggregate runtimes, which attach one when a
Postgres selection demands it), so it keeps default internet egress and can reach a Function URL; and
`fetch` is global on the Node 18+ runtime this deploys on. Recorded because a VPC-attached Lambda with
no NAT fails this in a way that looks like a broken geocoder rather than a networking choice.

**Order of work, and where the risk actually is.** 7a has no unknowns and can land immediately. The
two prerequisites are mechanical. The risk is not in any of them — it is that **nothing in this plan
has ever spoken to a real geocoder**, so the first deployed run is the first test of D2's status
contract, D3's relevance threshold against real scores, and the SDK call itself. Expect to find
something there; that is the point of shipping this step rather than mocking further.

**8 — Docs. ✅** The outbound-slice documentation gains its new source model and the
`~sourceId` argument; the geo docs gain the sentence that matters — the picker is the client path,
this slice is the unattended one, and D8 is why they do not collide. The capability docs gain the
shape D9 found: one capability, two doors, a GraphQL field for clients and an injected function for
plugin code — with the object store as the worked example, since it already has both.

**9 — The injected port (D9 half 1). ✅** `GeocodingService` is deleted; `translate` takes
`~capabilities` and calls `capabilities.geocode`, backed on AWS by `Geocoder_AwsLocation_Backend`
calling the SDK directly. The port type from 7a was already the target, so the plugin-side change was
exactly what was predicted: delete a file, accept an argument. Deploy side: the platform exports the
place index, `deployPlugin` registers it as `PLACE_INDEX_NAME`, and the `AllAutomationSlices` role
gains `geo:SearchPlaceIndexForText` on it. `GEOCODER_ENDPOINT` is gone from the slice path; the
browser keeps the Function URL until step 10, which is what makes the two doors independent. See
[the step 9 round](#the-step-9-round-the-capability-becomes-an-argument).

**10 — Geocoding on the platform API (D9 half 2). 🟨 built in both repos; awaits a coordinated UI
release + deploy.** A geocode field on the platform GraphQL API, mirroring `Upload_Presign`,
resolving through the same `Geocoder_AwsLocation_Backend`. The map picker moves onto it; the public
Function URL and `geocoderEndpoint` are deleted. See [the step 10 round](#the-step-10-round-the-client-door-opens-and-the-function-url-closes).

All the code landed:

- **Core, the field.** `geocode(text: String!): [GeocodeCandidate!]` — a Query, since geocoding is a
  read — declared in `Platform_AdminApi` (`geocodeTypes` / `geocodeQueryFields`) beside the upload
  fields and stitched into `domainBaseFragment` on both platforms, so it takes the domain API's
  default `AllowAuthenticated` auth exactly as `Upload_Presign` does.
- **Core, the AWS door.** `Geocoder_AwsLocation_Resolver{,_Ops}.res` mirror `Upload_Presign_S3{,_Ops}`:
  a compiled-EntryPoint Lambda over the shared `Geocoder_AwsLocation_Backend.search`, an IAM grant of
  `geo:SearchPlaceIndexForText`, an AppSync Lambda data source, and one `Query.geocode` resolver on
  the domain API (split mode). Wired in `Platform.res` gated on `cfg.geocoderPlaceIndex`.
- **Core, the local door.** `LocalGeocodeResolvers.register` on the dev domain server (a deterministic
  stub, since local provisions no real geocoder) — so the map picker's search box works offline, which
  closes the dev gap D9 named. The unattended slice path stays `Capabilities.none`; the two doors are
  independent.
- **Core, the deletions.** The public Function URL (`Geocoder_AwsLocation{,_Ops}.res` and its Ops
  test), the `geocoderEndpoint` stack export, and the `geocoderEndpoint` config.json key are all gone.
  The `geocoderPlaceIndex` export stays — it is how the unattended slice path reaches the same index.
  The status-contract test moves to `Geocoder_AwsLocation_Resolver_OpsTest` (unset index throws, empty
  query is `[]`).
- **UI, the client.** `Geocoder.fromShell` replaces `Geocoder.fromEndpoint`: it issues the `geocode`
  query over the shell's authenticated transport, read lazily per search from a kit-owned
  `AutoGraphQL.current` ref that `ShellApp` keeps fresh (the same discipline the presign adapter uses).
  `config.geocoderEndpoint` is deleted; `OptionalModes` builds the geocoder with no endpoint.

**What is left is the deploy — the release and the pin bump are done.** reventless-ui published
`@reventlessdev/reventless-host-shell@3.0.0-alpha.55` (the Release job on the UI push), which carries
the `Geocoder.fromShell` client, and all three examples' host-shell pins are bumped to it (`alpha.54`
→ `alpha.55`, lockfile regenerated). So the order D9 sequenced — publish reventless-ui → bump the pin →
one core deploy — is at its last step: a single core deploy adds the resolver, serves the new bundle,
and removes the Function URL in the same stack update. Doing the deploy before the UI release would
have stranded the old bundle's search; the pin bump on the same deploy is what makes the swap atomic.

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
- **The aggregate-source path has its own GWT** — `~sourceId` reaches `collect` and names the
  customer. Done: `GeocodeCustomerAddress_GWT`, the first test of an outbound slice fed by an
  Aggregate, which is the capability step 1 exists for.
- **A pin correction is not swallowed** — same address, different point, expects an event. Done, and
  it fails against the guard as originally written, which is what makes it worth having.
- **Zero warnings** after a full build, and no `.res.mjs` deletions (`git ls-files --deleted`).

- **D2's status contract is asserted** — `Geocoder_AwsLocation_OpsTest` covers the two arms reachable
  without a live AWS Location call: an unset place index is `502` (a service failure, not a verdict)
  and an empty query is `200` (nothing was asked). Added with step 7, because that is the step that
  first puts an unattended caller on that endpoint.

- **The confidence rule is calibrated against real scores, not invented ones** — a 24-address corpus
  put through the live Esri index, scored against a labelled expectation. `0.97`/`0.01` gets 24/24;
  the shipped `0.8`/`0.1` got 21/24 by declining three correct addresses. Two of those cases are now
  regression tests. See [the measurement
  round](#the-measurement-round-d3-calibrated-against-a-real-index).

**Not covered by any of the above, and worth stating plainly:** every slice test mocks `translate`,
so nothing exercises a real geocoder *through the slice*. The confidence rule is no longer among the
unknowns, but the SDK call from the slice's Lambda, the `~sourceId` collect against a live aggregate
event, and the command round trip back into `Customer` remain unverified — as does the success path
of the Function URL handler. The first deployed run is the first test of those, and now the most
likely place for this design to be wrong.

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

- ~~**The `Task` fallback, if step 1 does not fit.**~~ **Not needed.** Step 1 fit, and the deploy
  plan now shows the slice resolving onto the aggregate's stream. Kept in D1's rejected alternatives
  as the shape to reach for if a *backfill* is ever wanted, which is the one thing the heartbeat
  sweep genuinely does not cover.
- ~~**`DcbValidation` cannot see aggregate producers.**~~ **Fixed properly.** `produced` was built
  from StateChangeSlices alone, so an aggregate's events had no producer and every one of them was
  reported as unproduced — on every deploy, for correct code. `Plugin_Builder` and `Platform_Admin`
  now pass `~aggregateProducedEvents`, and `Dcb_Builder` concatenates them into the produced set for
  the validation call **only** — not into `producedSchemas`, which drives DCB GSI creation and must
  not mint indexes on the DCB table for events that live on an aggregate's own EventLog.
  Verified both ways on the ordering stack: no errors for the correct slice, and renaming a consumed
  variant to `AddressUpdatedTypo` still produces `consumes 'AddressUpdatedTypo' but no slice produces
  it`. So the rule is intact for aggregate-sourced slices rather than switched off for them.
- ~~**`InboundTranslationSlice` symmetry.**~~ **Checked — there is no asymmetry to fix.** Inbound has
  no source model at all: its Spec declares `externalInput`, not a `consumedEvent`, and it is invoked
  through GraphQL rather than subscribed to a stream. The two translation slices differ in
  *direction*, not in source rules, so there is nothing for outbound's source model to be
  inconsistent with. Worth having asked; the answer is that the question does not apply.
- ~~**A relevance threshold that is not a constant.**~~ **Answered** — see
  [the measurement round](#the-measurement-round-d3-calibrated-against-a-real-index). It stayed a
  constant; it just became a *measured* one, and the measurement found the original pair actively
  harmful rather than merely unvalidated. What remains open is narrower and worth stating separately:
  the numbers are calibrated against **Esri**, while `Reventless.Geocoding` is provider-neutral. A
  deployment on a provider that scores on a different curve needs its own pair. They are labelled
  arguments precisely so it can pass them, but nothing today *notices* a provider whose scores do not
  fit — the sharpest version of that is an index returning no `relevance` at all, which
  `confidentMatch` correctly declines and which therefore looks exactly like "every address is
  unresolvable".

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

### The D9 round

The seam was argued three ways before the review found that the question had already been answered —
twice, by the object-store capability, for its two callers. Recorded in D9 because the *wrong* framing
is the instructive part: the three options were all attempts to make one seam serve both a browser and
an unattended Lambda, and every one of them traded something real to do it. What killed the leading
candidate was not a preference but two concrete costs — a proxy hop the backend never needed, and an
unauthenticated public endpoint on the backend's critical path.

### The step 7 round

Both prerequisites landed as specified, and the seam question in prerequisite 2 resolved against the
plan's own first choice once the call sites were checked.

| Half | Files |
|---|---|
| 7a — the port type | `Geocoding.res` gains `type search`; `GeocodingService.search` annotated against it |
| 7b.1 — the export | `Platform.res`: `Pulumi.Pulumi.export("geocoderEndpoint", …)` + `geocoderEndpointRef` for the monolithic case; read in `deployPlugin` off the platform `StackReference` |
| 7b.2 — the env channel | `PluginRuntime_Builder.registerCapabilityEnv` / `capabilityEnv`; merged into `envVars` by both of `AutomationSliceRuntime_Builder_Single`'s finalizers |
| the status contract, now tested | `Geocoder_AwsLocation_Ops.res` + a new `Geocoder_AwsLocation_OpsTest.res` |

**Three things the step had wrong, all found by checking rather than by running.**

1. **`registerConfig` is the wrong function, for a reason the step did not see.** It is called from
   `deployPlatform` and assigns its record *wholesale*; the geocoder endpoint is only knowable in
   `deployPlugin`, so adding a parameter would have meant either a second wholesale call that wipes
   the fields the first one set, or moving a `deployPlatform` concern into `deployPlugin`. The
   forward-compatible dict the step suggested as an optional nicety turns out to be the thing that
   actually fits: `registerCapabilityEnv` is a separate ref with a separate lifetime, keyed by
   variable name so the runtime builders merge a dict they need no knowledge of. The step's reasoning
   for *rejecting* `commandHandlerConfig` — deployer-chosen values versus framework-derived ones —
   was right and is preserved; it just also excludes `registerConfig`.

2. **The obvious shape for the monolithic-mode ref is the one the repo forbids.** Written first as
   `ref<option<Pulumi.Output.t<string>>>` — mirroring `objectStoreEndpointsRef`'s optionality — it
   compiled to `Stdlib_Option.getOr(ref.contents, …)`, and `getOr` is `valFromOption`, whose
   nested-option probe hits the Output proxy and corrupts it. Caught by reading the emitted `.mjs`,
   not by the compiler, which is the point: this is a silent-at-build-time class. Now a plain Output
   with `""` as the sentinel, the shape `inboundSliceReg.auditTableName` already documents.

3. **The Function URL handler violated D2's own contract, on the one path step 7 puts on it.** An
   unset `PLACE_INDEX_NAME` returned `200 []` — indistinguishable from "no such address". D2 names
   exactly this case and says it must not be, but the shipped handler folded it into the empty-query
   arm. On the unattended path that means a misconfigured deployment writes
   `MarkAddressUnresolvable`, unretried, for every address handed to it. Now `502`; the empty-query
   arm stays `200`, because nothing was asked and "no results" is a true and final answer to that.
   `Geocoder_AwsLocation_OpsTest` asserts both, which is the first assertion the wire contract has
   ever had.

**Ordering constraint the export introduces:** the platform stack must be deployed before the plugin
stack for `geocoderEndpoint` to exist. Getting it wrong degrades rather than fails — the plugin reads
`""`, the client reports `Unavailable`, the item retries and the sweep surfaces it — which is what
the empty-string-not-missing-output choice buys.

### The proving deploy: the wiring is confirmed on real infrastructure, and the sweep does not exist

The deploy carrying the five fixes landed green (CI → Release → Layer → Deploy, all success). Every
claim the previous round could only support with `pulumi preview` is now checked against the deployed
resources, read-only:

| claim | evidence on the live stack |
|---|---|
| the aggregate stream reaches the slice (step 1, blocker 2) | `AllAutomationSlices-ace9609` carries an **Enabled** `EventSourceMapping` on `CustomerAggrEventLog-51b40cd` beside the DCB one |
| routing (fault B) | the `outbound` handler whose source is `CustomerAggrEventLog` has `dcbQueueUrl = CustomerAggrCmdTopic-2f9309d`; both DCB-sourced handlers keep `OrderingDcbCmdTopic-01908ac` |
| IAM (fault A) | `AllowLambdaSendSQS` on role `AllAutomationSlices-918b7f5`, `sqs:SendMessage` on **both** command topics |
| flavor (fault C) | `commandQueueIsFifo: false` on all three handlers |
| per-handler streams (blocker 2's fix) | each handler carries its own `sourceUrns`, `sourceUrn` still emitted beside it |
| the env channel (step 7b) | `GEOCODER_ENDPOINT` set to the platform's Function URL |

So the deploy-time half of this plan is done and verified. **The runtime round trip is still
unproven** — nothing has registered a customer since the deploy, and the aggregate's July events are
long past the stream's 24-hour retention, so no event will arrive on its own.

**Blocker 6 — the TODO list is write-only and the heartbeat sweep has no caller.** Looking for the
previous round's stranded item to see whether it would self-heal found that it cannot, and why is
worse than the item:

```
GeocodeCustomerAddressTodo-50d9488
  id=geo-probe-1:Karlsplatz 1, 1010 Vienna, Austria  status=Failed  retryCount=1
```

`maxRetries = 3` and `phase2`'s filter admits `Failed && retryCount < maxRetries`, so this row is
*eligible* for retry and has not been retried once — across two hours and a Lambda replacement. Three
findings behind that, each checkable:

1. **`todoItems` is a module-level `Dict.make()`** ([`OutboundTranslationSlice_Callback.res:76`](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res#L76)),
   populated only by `phase1` from the batch in hand. Warm-container memory.
2. **Nothing ever reads the table back.** `makeSyncTodoItems` is an `Overwrite` *save* only
   ([`AutomationSliceEntryPoint_Ops.res:108-129`](../../reventless/aws/src/adapter/Runtime/AutomationSliceEntryPoint_Ops.res#L108-L129));
   `QueryDbStorage_DynamoDb_Runtime` has a `load`, and the entry point never calls it. So a persisted
   row is a report to observers, not state the slice can act on.
3. **`translatePending` has zero callers** in the whole repo — the builder exposes it
   ([`_Builder.res:226`](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Builder.res#L226))
   and its doc comment says "useful in tests and for heartbeat", and no heartbeat calls it. The plugin
   heartbeat is registration plumbing (`SpecificHeartbeat.connect` emitting Connect commands to the
   platform extension point); it does not sweep components.

**This is the third appearance of one pattern**, and by now that is the finding rather than the
incident: `targetName` was declared and never read, `finish()` was written and never called, and now
`translatePending` is exposed and never called while the table it feeds is never read. A declaration
with no consumer is invisible to every test, because the tests exercise the declaration.

**What it costs this plan.** D4's first row — "retried to `maxRetries`, then swept by the heartbeat" —
holds only *within one warm container*. A transient geocoder failure whose container recycles is
stranded permanently, in a row that reads `Failed` and looks like it is waiting for a retry that
nothing will ever perform. It also undercuts D1's reason for rejecting the `Task` alternative: that
the slice "already owns" the TODO list, retry counter and sweep. It owns two of the three.

**Half fixed: the table is read back now.** `makeLoadTodoItems` in `AutomationSliceEntryPoint_Ops`
scans the slice's view table for `Pending` / `Failed` rows and merges them into `todoItems` ahead of
phase 1, in both pipelines. So a backlog now survives a cold start and is retried on the first event
the next container handles — which is what turns a `Failed` row from a permanent record into work
still queued.

Four choices worth stating, because each was a fork:

- **Once per container, not per invocation.** Within a container the dict is authoritative and
  `phase2` already re-attempts every actionable row on each batch, so re-reading buys nothing and
  costs a scan every time.
- **Memory wins on conflict.** A row already in the dict may be `Processing` or a status this
  invocation just advanced; the stored copy is by definition no fresher.
- **Only `Pending` and `Failed` are read.** `Completed` is the bulk of a mature table and never
  actionable. Retry-exhausted rows are not filtered out — `maxRetries` is Spec-level and not known at
  that layer — but `phase2` drops them, so they are inert rather than wrong.
- **Before phase 1, not between the phases.** Loading after phase 1 would let a stored row overwrite
  one the batch just collected; loading after phase 2 would leave the reloaded backlog sitting until
  the next invocation. The step-order assertion in `AutomationSliceEntryPoint_OpsTest` now pins
  `["restore", "phase1", "sync", "phase2", "sync"]` — and the signature change made the compiler
  flag both call sites in that same test, which is the protocol-as-named-types fix from blocker 4
  doing its job.

**Other half fixed: the sweep now fires on a timer.** An EventBridge rule invokes the shared
automation Lambda every five minutes with the constant payload `{"reventlessSweep":true}`; the entry
point runs every slice's backlog — reload, translate, persist — with no event to trigger it. It had
to be the automation Lambda itself and not the plugin heartbeat's: `todoItems` is per-container state
of a *different* function, so nothing outside that Lambda can sweep it. The rehydration above is what
makes a scheduled invocation useful at all, since it lands on a cold container with an empty dict.

- **The branch lives in the `.mjs` shell**, which is the one file that owns untyped Lambda-payload
  probing (a scheduled event has no `records` — that *is* the discriminator). Everything it dispatches
  to is type-checked: `makeAutomationRegisteredHandler` / `makeOutboundRegisteredHandler` now return a
  `builtSlice` carrying both the stream handler and a `sweep` thunk, and the two share the same
  publish/sync/load closures — so a sweep landing on a warm container reuses the load that container
  already did, and one landing cold does it itself.
- **Sweeps run sequentially and a thrower does not stop the rest.** A sweep exists to recover from a
  failing external call; letting one slice's dead geocoder cost every other slice on the Lambda its
  turn would be a worse version of the problem. Both properties are tested.
- **Five minutes** is short enough that a transient outage clears unattended and long enough that the
  invocations are noise against event traffic (~288/day, most finding an empty backlog).
- **Local is deliberately unchanged.** Its dict lives for the whole process, so the cold-start
  stranding this fixes cannot happen there; the residual "no traffic, no retry" is a dev-only wrinkle
  with an obvious workaround, and a `setInterval` in the dev platform risks holding the Node process
  open under Jest. `translatePending` therefore still has no caller — but it is now the *local*
  handle for a capability the deployed platform has, rather than a promise nothing anywhere keeps.

### The end-to-end run: the loop closes, and the last hop drops the answer

A `Register` command was published directly onto `CustomerAggrCmdTopic` (the aggregate's own topic —
this exercises exactly the hops that were unproven and skips only AppSync auth, which is not under
test). **The whole plan ran, first time, on real infrastructure:**

```
handling command 1/1: Register(geo-probe-3, {email:…})
produced 1 event(s): [Registered(geo-probe-3, …)]      ← aggregate
save: … status=Completed  retryCount=0                  ← slice TODO row, 1.5s later
handling command 1/1: SetLocation(geo-probe-3, {location:{…}})
produced 1 event(s): [LocationSet(geo-probe-3, …)]      ← back in the aggregate
```

and the point is right: `lng 16.372605, lat 48.208728` for `"Stephansplatz 1, 1010 Vienna, Austria"`
is St. Stephen's Cathedral. So `collect` keyed off `~sourceId`, the geocoder answered, `confidentMatch`
at `0.97`/`0.01` accepted it, the command routed to the aggregate's queue (fault B), the role could
send (fault A), the standard-queue flavor was right (fault C), and `SetLocation` passed D5's staleness
guard and produced its event. **Everything steps 1–7 set out to build is now proven against the real
service, including the retry counter reading `0`.**

**Blocker 7 — the read model never sees it, because the event is tagged with the wrong service.**
The row stays `locationStatus: Pending` with no point. The read model *received* the event and
decided it meant nothing:

```
handling event 1/1 from Customer: Registered(geo-probe-3, …) actions:[UpdateWithDefault(…)]   ✓
handling event 1/1 from OutboundTranslationSlice:GeocodeCustomerAddress:
    LocationSet(geo-probe-3, {…}) actions:[]                                                   ✗
```

`ReadModel_Callback` takes `sourceName = context.meta.service`
([:23](../../reventless/core/src/components/ReadModel/ReadModel_Callback.res#L23)) and matches
mappings against it. The stored events show why the two differ:

| event | `service` |
|---|---|
| `Registered` | `Customer` |
| `LocationSet` | `OutboundTranslationSlice:GeocodeCustomerAddress` |

An aggregate **inherits the command's meta into the event it emits**. The slice stamps its published
command with its own name —
[`makeMeta`](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res#L85):

```rescript
Message.generateMeta(~service=`OutboundTranslationSlice:${Spec.name}`)
```

so the resulting event announces itself as coming from the slice, and every mapping keyed on
`Customer` declines it. No error, no dropped message, no retry — `actions:[]` and a 6.5 ms success.

**This is not specific to geocoding.** All three slice callbacks do the same thing
(`AutomationSlice:${Spec.name}`, `OutboundTranslationSlice:${Spec.name}`,
`InboundTranslationSlice:${Spec.name}`), so *any* slice that publishes a command to an aggregate
produces events that the aggregate's own read models silently ignore. It has been latent for the same
reason as the rest of this round's findings: no slice had ever successfully published a command to an
aggregate before today.

**Fixed — and it turned out not to be a new convention but an existing one the slices ignored.**
The API path already does exactly the right thing: `CommandGenerator_Callback` publishes with
`~serviceName=AggregateSpec.name`
([:187](../../reventless/core/src/components/CommandGenerator/CommandGenerator_Callback.res#L187)),
which is why every hand-seeded customer's events carry `service: Customer`. So a command is tagged
with its **target**, the aggregate inherits that into its event, and dispatch works. The slices were
the only publishers stamping themselves instead — and `Spec.targetName`, whose sole consumer until
blocker 5 was a diagram, is precisely the value they needed. Second missing consumer for the same
field, found one blocker later.

All three callbacks now tag with the target: `AutomationSlice` and `InboundTranslationSlice`
unconditionally (their `targetName` is a required `string`), `OutboundTranslationSlice` through
`Option.getOr`, keeping its own name when there is no target — that command goes to the plugin's DCB
topic, where nothing dispatches on `service`, so the fallback preserves existing behaviour exactly.

**The regression test is the point, not the fix.** Every blocker in this plan was invisible to a
green suite, and this one had the additional insult that the *whole feature* worked end to end while
it was broken. `OutboundTranslationSliceCallbackTest` now asserts the published command's
`meta.service` against the fixture whose `targetName = Some("ConfirmPayment")`; confirmed to fail
against the old code with `Received: "OutboundTranslationSlice:ProcessPayment"`, which is the only
evidence that makes a test worth keeping.

*Also learned, and worth a line because it cost a probe:* the command wire envelope is
`{id, meta, command}` ([`toCommandSchema'`](../../reventless/core/src/Message.res#L58)), while
`Message.commandJson` — the publish-side record — spells its payload field `commandJson` and
`toMessageBody` renames it. A body sent with the wrong key is not rejected: `decodeCommand'` uses
`parseJsonTolerant`, so a missing `command` decoded to the payload-less last variant (`Deactivate`)
and the aggregate cheerfully rejected it as `CustomerNotFound`. Tolerant decoding turning a malformed
command into a *different valid command* is worth knowing about independently of this plan.

### The measurement round (D3 calibrated against a real index)

The gate on step 9 was "nothing has ever spoken to a real geocoder". That turned out not to need a
deploy: the place index (`online-shop-geocoder`, `DataSource: Esri`) is live, and asking it directly
answers D3's question without waiting for the slice to run. It was asked, and **the shipped
calibration was wrong in the direction that costs customers**.

**What Esri actually scores.** Not a spread over 0…1. Everything it is willing to return lands in
roughly 0.9…1.0, and genuine ambiguity shows up as an *exact tie* rather than a near miss —
`"Springfield"` returns five states at exactly `1.0`, `"221B Baker"` five towns at exactly `0.8222`.
Meanwhile a *correct* pinpoint match routinely has a plausible runner-up close behind it:
`"Baker Street 221B, London NW1 6XE"` returns the right building, matching postcode, at `0.991` —
with an unrelated Baker Street at `0.962`.

So `ambiguityMargin = 0.1` does not catch more ambiguity. It rejects clear winners. Against a
24-address corpus (12 realistic complete addresses expected to resolve, 12 vague, misspelled, or
nonexistent expected to decline):

| calibration | correct | false declines | false resolves |
|---|---|---|---|
| `0.8` / `0.1` — as shipped | 21/24 | **3** | 0 |
| `0.97` / `0.01` — now | **24/24** | 0 | 0 |

The three false declines were `"Baker Street 221B, London NW1 6XE"` (0.991/0.962),
`"Rue de Rivoli 99, 75001 Paris"` (0.995/0.959) and `"Gran Via 28, 28013 Madrid"` (0.988/0.952) —
in every case the geocoder returned the exactly-right address, with the right postcode, as its top
hit. **Per D4 those become `MarkAddressUnresolvable`, which is deliberately not retried**, so the
defect is permanent per address and silent: a quarter of realistic addresses written off, with the
correct answer having been in hand.

**Why the fix is a higher floor rather than a narrower margin.** Because no margin separates the
remaining cases. `"Kaiserstrasse 12, 4020 Linz"` resolves to *Rainerstraße* 12 — wrong street, right
city — with a gap of `0.031` to its runner-up, *wider* than the correct Baker Street match's `0.029`.
Ranked by margin the wrong answer beats the right one. Ranked by absolute score they separate
cleanly: the wrong matches sit at 0.913…0.958, the correct ones at ≥0.988. So the floor moved up into
that gap and the margin shrank to what it is actually good at — catching ties. `0.96`–`0.98` paired
with `0.005`–`0.02` all score 24/24; `0.97` / `0.01` is the middle of that plateau rather than an
edge of it.

Both constants are now named (`defaultMinRelevance`, `defaultAmbiguityMargin`) and both remain
labelled arguments, because this is an *Esri* calibration sitting in a provider-neutral module — the
tension is real and is recorded in Follow-ups rather than papered over. Two regression tests carry the
measurement into the suite: the correct-match-with-plausible-runner-up case, and the wrong-street case
that explains why the margin alone could not do it.

### The deploy round: step 7's wiring works, and two things behind it do not

The deploy carrying step 7 landed, and checking it turned up the reason this was never going to run —
twice over. Neither was visible from the code the plan had been reasoning about, because both sit
*outside* it: one in a generated file that is committed rather than built, one in the AWS runtime
builder. The first is fixed; the second is now the gate. Both are recorded in full, because the way
each stayed hidden is the reusable part.

**What works, confirmed on real infrastructure.** `AllAutomationSlices` now carries
`GEOCODER_ENDPOINT` pointing at the platform's Function URL. Both of step 7's prerequisites are
therefore proven end to end: the platform stack export, the cross-stack `StackReference` read in
`deployPlugin`, and `registerCapabilityEnv` merging into the slice Lambda's `envVars`. That is the
part the step was least sure of, and it is the part that turned out fine.

**Blocker 1 — the committed composition root never wired the slice. ✅ fixed in `c05641014`.**
`Plugin.res` is generated but *committed*, and CI compiles it directly rather than re-running the
generator (CLAUDE.md says so explicitly). It was never regenerated when step 5 added
`GeocodeCustomerAddress`, so the deployed `HANDLER_CONFIG` listed only `AutoShipOrder` and
`SendOrderConfirmation` — while `GEOCODER_ENDPOINT` sat correctly beside it. The endpoint arrived;
the only component that reads it did not. The generator finds the slice perfectly well: re-running it
adds `GeocodeCustomerAddressSlice` at both `~outboundTranslationSlices` call sites and gives it its
`componentChapters` entry. Until that commit the feature had never been deployed, and no amount of
correct plugin code would have changed it.

*Worth generalising, because the trap is not specific to this slice:* a generated-but-committed file
is only as current as the last person to run the generator, and nothing fails when it is stale — the
build is green, the tests are green, and the component silently does not exist. Every check this plan
listed under Verification passes with the slice absent.

**Blocker 2 — the AWS runtime has no way to feed an aggregate-sourced outbound slice.** This is the
step 1 capability, missing on the deploy side. `AutomationSliceRuntime_Builder_Single` has two
finalizers, and only `finishWithDcbEventLog` is ever called
([Platform.res:808](../../reventless/aws/src/Platform.res#L808)) — the plain `finish()` has no call
site. That finalizer builds exactly one channel:

```rescript
let eventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
  ("DcbEventLog", dcbOutputs.eventTopic),
])
```

and its own comment calls the DCB stream "the sole source for automation/outbound slices". The AWS
`OutboundTranslationSlice_Builder` confirms it from the other end: it accepts `~allEventTopics` and
passes it to the *core* component, but `registerAutomationSlice` records only the name, module paths,
callback type and query-db table — **no source information at all**. So the runtime cannot know a
slice wanted `["Customer"]`, and the Customer aggregate's `Registered` / `AddressUpdated` events live
on the aggregate's own EventTopic stream, never on the DCB log.

Step 1 closed the gap in `reventless-core` and in the local platform — which is exactly why the GWT
suite is green and why this stayed invisible. The AWS *runtime* half was never done. Until it is, the
slice deploys and then waits for events that structurally cannot reach it.

**Blocker 2, resolved — and the shape of the fix was decided by *when* things run.** The obvious
route, teaching `finish()` about aggregate sources, is closed: `storedSpecs` is populated by
`forEventCollector` *inside* a `Pulumi.Output.apply`, so it is still empty when the synchronous
`onDcbSlicesCreated` hook fires. That is the same reason `finish()` is dead code. The topics
themselves, though, are computed *before* that apply in both core builders — the value was available
in time all along and simply had nowhere to go.

So `registerAutomationSlice`, which already runs synchronously, now also carries `~sourceTopics` (the
slice's non-DCB EventTopics) and `~consumesDcbLog`. `finishWithDcbEventLog` unions those into the
channel's `eventTopics`, and each handler gets its own `sourceUrns` array rather than sharing one DCB
URN. The entry point registers a handler under each of its streams — no routing change needed, since
`addToRegistry` already accumulates many handlers per source and the router dispatches on each
record's own `eventSourceARN`.

Both defaults (`sourceTopics = {}`, `consumesDcbLog = true`) reproduce the previous DCB-only wiring
exactly, which is what keeps the two existing slices untouched. `sourceUrn` is still emitted beside
`sourceUrns` so a handler config read by an older entry point still routes its first stream.

*Verified against the real stack, at plan level.* A `pulumi preview` of the ordering stack shows:

| handler | `sourceUrns` |
|---|---|
| `AutoShipOrder` | `OrderingDcbEventLog` — unchanged |
| `GeocodeCustomerAddress` | **`CustomerAggrEventLog`** — the aggregate stream, previously unreachable |
| `SendOrderConfirmation` | `OrderingDcbEventLog` — unchanged |

*What the preview cannot show, and why.* The EventCollector is built inside an `apply`, and a
brand-new resource's outputs are unknown during preview, so that callback never runs — which is also
why `GeocodeCustomerAddress` is absent from the `registered … for …` log there. The
`EventSourceMapping` resources therefore cannot be confirmed ahead of a real deploy. A local preview
additionally diverges wholesale from the CI-deployed graph (it planned 94 deletions, against
workspace packages rather than published ones), so its resource plan is not evidence about anything
beyond the handler config, and it must not be applied.

**Blocker 3 — the DCB validator reports a correct slice as broken.** Deploying now logs, every time:

```
DCB validation error (GeocodeCustomerAddress): Slice 'GeocodeCustomerAddress' consumes 'Registered' but no slice produces it
DCB validation error (GeocodeCustomerAddress): Slice 'GeocodeCustomerAddress' consumes 'AddressUpdated' but no slice produces it
```

`DcbValidation`'s "every consumed event has a producer" rule builds its producer map from DCB slices
only, so an aggregate's events look like nothing produces them. **Not fatal** — `Dcb_Builder` logs the
errors and continues, which is why the deploy succeeds — but it is the same blind spot as blocker 2 in
a third place, and corrosive in a specific way: a deploy that prints `ERROR` for correct code teaches
everyone to skim past `ERROR`. **Fixed** by feeding the aggregates' event schemas in as producers;
see Follow-ups for the shape and for the one place they are deliberately *not* added.

**Blocker 4 — every outbound slice on AWS had been crashing since step 1, and the test said
otherwise.** With the first three cleared, the slice finally received an event — and died on it:

```
found 1 handler(s) for …CustomerAggrEventLog…
TypeError: Cannot read properties of undefined (reading 'TAG')
  at Module.collect (…/GeocodeCustomerAddress_Translation.res.mjs:7:13)
```

Everything up to `collect` worked; the argument was `undefined`. Step 1 changed `phase1` to take
`(sourceId, event)` pairs, but `AutomationSliceEntryPoint_Ops` still emitted bare events. A ReScript
tuple compiles to an array, so destructuring a bare event object yields `undefined` for both halves.
**This was never specific to aggregate sources** — `SendOrderConfirmation` had been failing the same
way on every order since step 1, unnoticed.

*Why the compiler was silent, which is the part worth keeping.* The entry point builds callbacks
dynamically per `HANDLER_CONFIG` entry, from modules it `dynamicImport`s at runtime, so it cannot
name `OutboundTranslationSlice_Callback.T` — the Spec is not known statically. It therefore declared
its **own structural copy** of the callback shape to ascribe at the JS boundary. That copy was a
second source of truth: internally consistent, never reconciled with the original, and silently wrong
the moment core changed. Step 1's "five call sites, all updated" was accurate for every site the
compiler could see; this one was invisible by construction.

*And the test was holding it in place.* `AutomationSliceEntryPoint_OpsTest` covers exactly this
function — and asserted the bare-event shape, against that same drifted local type. The one test that
should have caught the regression was pinning it instead, because it agreed with the copy rather than
with the callback. A test written against a restated type inherits the restatement's errors.

*The fix is structural, not a patched call site.* Each callback module now owns its protocol as named
types — `phase1`, `phase2`, and a `runtime` record — used by its own `module type T` and **aliased**
by the entry point rather than restated. Verified by changing the core type and watching the build
fail. The same treatment went to `AutomationSlice_Callback`, which had the identical hand-written copy
sitting beside it and would have drifted the same way on its next signature change.

**Blocker 5 — the slice geocodes correctly and then cannot deliver the answer.** With blocker 4
cleared the slice ran properly for the first time, and the log records how far it got:

```
save: saved state to GeocodeCustomerAddressTodo-50d9488: id=geo-probe-1:Karlsplatz 1, 1010 Vienna, Austria
failed to publish command: … not authorized to perform: sqs:sendmessage
  on resource: …:OrderingDcbCmdTopic-01908ac
```

**That line is reachable only after `translate` returned `Ok(Some(…))`**, so everything this plan set
out to build is now proven against the real service: `collect` keyed the item with the `~sourceId`
step 1 added, the geocoder was called and answered, and `confidentMatch` at the recalibrated
`0.97`/`0.01` accepted the result and produced a `SetLocation`. D3 and D4 are no longer theoretical.

What fails is the last hop, and it is two faults wearing one error message.

*Fault A — no IAM grant.* The `AllAutomationSlices` role cannot `sqs:SendMessage` to the command
topic at all. This was never specific to geocoding: `SendOrderConfirmation` publishes the same way and
would have hit it identically. It never did, because blocker 4 killed that slice before it could
reach a publish. **Two defects concealing each other** — fixing the first is what exposed the second,
and neither could have been found while the other stood.

*Fault B — the wrong queue.* `makePublishJsons(entry.dcbQueueUrl)` hardwires the plugin's *DCB*
command topic. `SetLocation` targets the **Customer aggregate**, whose commands travel through
`CustomerAggrCmdTopic` to a different handler. So the grant alone would not fix this: it would
faithfully deliver the command somewhere nothing handles it — a silent no-op rather than an error,
which is the worse outcome of the two.

The cause is that **`targetName` has no consumer.** `GeocodeCustomerAddress` declares
`targetName = Some("Customer")`, the Spec has carried the field all along, and nothing in the builder
reads it for routing. It documented an intention the framework never acted on. This is blocker 2's
shape a second time: the DCB direction was built and the aggregate direction was not, and the
declaration that should have exposed the gap was inert instead.

*The deploy-time half is done* (`91f580130`). `Dcb_Builder` resolves the publisher through
`Spec.targetName` against `publishToAggregates` — a dict of per-aggregate publish functions that
`createAggregatesWithoutEventMappers` fills **before** `construct` runs, so the Customer publisher is
in hand when the slice is built. DCB slice publishers register afterwards and are deliberately
absent, since a slice targeting one wants the DCB fallback. That completes the **local** platform,
where the publisher is a captured closure.

*The AWS half is not, and cannot reuse the function.* The Lambda is a compiled `EntryPoint` bundled by
`buildCodeArchive` and configured solely through `HANDLER_CONFIG` — not a serialized closure. That
separation was deliberate: serialized closures mixing layer and runtime `@aws-sdk` versions caused
cold-start 502s. So a `publishJsons` function cannot cross into the Lambda, and the same choice has to
be re-expressed as **data**: which queue, and what flavor.

*Fault C, found while scoping that — and it would have been the next surprise.* `makePublishJsons`
hardcodes `AWS.SQS_FIFO`, and `Util_SQS_Runtime.sendMessages` branches on exactly that to attach a
`MessageGroupId`. Both deployed command topics are **standard** queues (`CommandTopicChannel_SQS.make`
creates them without `fifoQueue`; only the `_FIFO` variant sets it), and SQS rejects a
`MessageGroupId` on a standard queue. So the publish would still fail after routing and IAM were
fixed — and it would fail for `AutoShipOrder` and `SendOrderConfirmation` too, the moment their grant
exists. **Three faults in a row on one path, each hidden by the one before it**, which is what a code
path that has never once executed end to end looks like from the outside.

*The seam for the remainder.* `CommandTopicChannel_SQS.make` is where the queue is created: it holds
the concrete `PulumiAws.SQS.Queue.t` (so `.id` is a flat `Output<string>`, not a field buried inside
an `Output<array<resource>>`), it takes `~owner`, and its module identity already fixes the flavor.
Registering `(url, queue resource, isFifo)` there, keyed by owner name — the plural sibling of
`setDcbQueueUrl` — gives the outbound builder everything it needs: the URL and flavor for
`HANDLER_CONFIG`, and the resource to append to the channel spec so `connectLambda`'s existing
`sqsResources` grant covers it.

*The registry landed one commit before it could work* (`af94d0218`), because registration happened at
queue creation and the queue was created inside `eventLog->Component.operations->Pulumi.Output.apply`
— after every synchronous finalizer had already run. The framing "find a lifecycle point that
observes both" turned out to be the wrong question; the right one was *why is the queue in an apply
at all?* Only the command **handler** needs the event log's operations. The queue needs nothing from
them, so `SpecificCommandTopic.make` is hoisted out of the apply in
`Aggregate_Builder.createCommandTopic` and runs during `createAggregatesWithoutEventMappers` — which
`Plugin_Builder` deliberately calls *before* DCB construction, for exactly this class of reason. The
finalizer's existing lookup then simply finds the entry; no new lifecycle point exists. This also
moves an SQS queue creation out of an apply, which is the repo's own standing rule, and it is why the
queue was invisible to `pulumi preview` on a fresh stack.

*Fault A closes the same way, for the fallback direction.* A slice that resolves no target publishes
to the plugin's DCB command topic — and that queue's `SendMessage` grant was equally missing.
`onDcbCommandTopicCreated` already held the channel synchronously; it now passes the queue resource
to `setDcbQueueUrl`, and the finalizer appends the captured DCB queue(s) to the channel resources
whenever at least one slice kept the fallback. (Accumulated, not singular: the hook fires again for
the async DCB topic when async StateChangeSlices exist, and granting on both is correct.)

*Verified at plan level against the real stack.* A `pulumi preview` of the ordering stack shows all
three faults closing at once and nothing being replaced:

| evidence | detail |
|---|---|
| routing (fault B) | `GeocodeCustomerAddress`'s `dcbQueueUrl`: `OrderingDcbCmdTopic → CustomerAggrCmdTopic`; `AutoShipOrder` / `SendOrderConfirmation` unchanged |
| IAM (fault A) | new `AllowLambdaSendSQS` statement on the `AllAutomationSlices` role, resources `[CustomerAggrCmdTopic, OrderingDcbCmdTopic]` |
| flavor (fault C) | `commandQueueIsFifo: false` on all three handlers — both topics are standard queues |
| URN stability | `CustomerAggrCmdTopic` is an in-place *update*, not a replace — the hoist does not change resource identity |

The one diff the hoist itself causes: the queue gains its `reventless:plugin` tag. `AWS_Tags` reads
the ambient plugin context that `Plugin_Builder` publishes during synchronous construction; a queue
created inside an apply ran after that context was gone, so the tag had been silently missing on
every aggregate command topic. Tags-only, in-place.

*What was tried and abandoned, so it is not retried.* Deriving the URL from
`Builder_Helpers.aggregateResources` does not work. It is an `Output<array<resource>>`, and although
every `resource` field is typed `Pulumi.Output.t<string>`, Pulumi **flattens nested Outputs at
resolution**, so inside the outer apply those fields are already plain strings — `.apply` on one
throws `TypeError: m.apply is not a function`. The types describe the pre-resolution shape and reality
is the post-resolution one; bridging that needs `Obj.magic`, which is barred in `.res`. Capture at
creation sidesteps it entirely.

**A note this plan owes step 6, found while repairing the fallout.** Adding a non-nullable field to a
read model breaks the *entire list query* for every pre-existing row. `locationStatus` is non-null in
the generated schema; the eight seeded customers predate it and carry no such attribute; GraphQL
propagates a null in a non-nullable field up to its parent, and inside a list that nulls the whole
result. So the symptom is **every customer disappearing**, not one field going blank — indistinguishable
from data loss, and alarming out of all proportion to the cause. The rows were repaired in place
(`Located` where a point already existed, guarded by `attribute_not_exists`), no wipe needed. The
general rule belongs with the `pluginStructure` trap it rhymes with: a new required field on a
component with live data needs a backfill planned alongside it.

### The step 9 round: the capability becomes an argument

The plugin no longer reaches for a geocoder; it is handed one. `Reventless.Capabilities.t` is a
record with a `geocode: Geocoding.search` field, `translate` takes `~capabilities`, and
`GeocodingService.res` — the plugin-side HTTP client written for step 7 — is deleted. What replaces
it is not a different client but no client at all: on AWS,
`AutomationSliceEntryPoint_Ops.capabilities` builds the record from `PLACE_INDEX_NAME` and
`Geocoder_AwsLocation_Backend` calls the SDK. Both of D9's objections to the fast path close with it —
the proxy hop through a second Lambda is gone, and the unattended path no longer depends on a public
unauthenticated Function URL.

| Layer | What supplies it | Why |
|---|---|---|
| the AWS Lambda | `capabilities()` from the environment, per call | where the index name is; per call, so a config update needs no cold start |
| the local platform | `LocalCapabilities` → `Capabilities.none` | local provisions no geocoder; `Unavailable` keeps items queued rather than writing addresses off |
| the AWS *deploy-time* builder | `DeployTimeCapabilities` → `none` | inert by construction — the core builder's in-process handler never runs a translation on AWS |

**Four decisions worth keeping.**

1. **A record, not another labelled argument.** Adding a capability later changes the record, which
   breaks the three places that *construct* it — the platforms, which is where a new capability has to
   be wired anyway — and leaves every `translate` reading `capabilities.geocode` untouched. D9's
   stated cost for option 1 was that "the bag accretes"; the record is what keeps the accretion off
   the plugins.
2. **A functor parameter on the core builder, not a mutable slot.** A platform that fails to supply
   capabilities does not compile. That is the property D9 chose injection for, and precisely why it
   rejected the cold-start slot: ES modules evaluate imports before the importing module's body, so
   "the entry point runs first" is an assumption a bundling change can break.
3. **`Capabilities.none` is a statement, not a stub.** Every capability answers `Unavailable`, which
   `translate` maps to a retryable `Error` — so a platform without a geocoder leaves items queued and
   visible instead of recording `MarkAddressUnresolvable`, which would be a false verdict on the
   address.
4. **The grant travels separately from the environment variable.** `registerCapabilityEnv` carries a
   *value*; a role needs a *resource*. So `PluginRuntime_Builder` also gains
   `registerGeocoderPlaceIndex`, and the finalizer attaches the policy — at top level with an
   Output-valued document, not inside an `apply`, because a resource created in an apply callback does
   not reliably register (the defect that intermittently cost the heartbeat Lambda its SQS grant). The
   "was a geocoder provisioned at all" bit is a plain bool beside the Output, because
   `ref<option<Pulumi.Output.t<_>>>` is the shape that corrupts the proxy.

**One predicted knock-on did not happen.** The step expected the GWT harness to absorb the signature
change alongside the two `SendOrderConfirmation` slices. It did not need to:
`OutboundTranslation_GWT` declares its own `translateResult` and mocks the call rather than invoking
`Spec.translate`, and says so in its own header. A harness that *models* a function instead of calling
it is immune to its signature — the opposite of the lesson blocker 4 taught about restated *types*,
and worth recording beside it so the two are not confused. Restating a type the compiler could have
checked is a liability; declining to call a function you are standing in for is not.

### The proving deploy #2: the pin appears

Blockers 6 and 7 and step 9 shipped together and were checked on the live stack. **The plan's
headline verification passes**: a customer registered with nothing but a plain address —
`"Schlossberg 1, 8010 Graz, Austria"` — ended up with

```
locationStatus: Located   lat 47.073780   lng 15.437879
```

which is Schlossberg, Graz. Nobody opened a map. That sentence is the whole plan, and it is now true
end to end on real infrastructure.

| What | Evidence |
|---|---|
| blocker 7 — the event is projectable | the stored `LocationSet` carries `service: Customer`, not the slice's name, and the read model applied it |
| step 9 — the SDK path | `PLACE_INDEX_NAME: online-shop-geocoder` on the Lambda, `AllAutomationSlicesGeocode` granting `geo:SearchPlaceIndexForText`, and **no `GEOCODER_ENDPOINT`** — the Function URL is out of the backend path entirely |
| blocker 6 — the timer | `alpha-AllAutomationSlicesSweep`, `rate(5 minutes)`, ENABLED, target `AllAutomationSlices`, input `{"reventlessSweep":true}` |
| blocker 6 — the shell branch | over 20 minutes: 4 invocations, 2 carrying stream dispatches (the probe) and **2 carrying none** — the scheduled path, which no test can reach. Zero errors, 220–305 ms |
| blocker 6 — rehydration | `restore: reloaded 12 unfinished TODO row(s) from AutoShipOrderTodo-f548350` |

That last line is the one worth dwelling on. Those twelve rows are `AutoShipOrder` items that failed
*before* any of this work and had been unreachable ever since — precisely the stranded state blocker 6
described, found in the wild rather than in a thought experiment. A container that had never seen them
from a stream loaded them from storage and considered them.

**And then correctly declined to retry them:** all twelve sit at `retryCount: 3` against
`maxRetries: 3`, so `phase2` filters them. Loaded but inert, exactly as the loader's design note says
it should be. Which surfaces one cost that is now measured rather than predicted — see Open.

### Open

- **Resolved by the deploy: the wire contract now carries `relevance`.** Before it, the live Function
  URL returned `{label, lat, lng}` and nothing else — which under `confidentMatch` declines *every*
  address, since an unscored candidate is not confident. It now answers
  `{label, lat, lng, relevance}`, so step 2's pass-through and D2's shape are confirmed against the
  real service. Recorded rather than deleted because that stale state is exactly what a
  provider-mismatch looks like from the outside — uniformly unresolvable, with nothing pointing at
  the cause — and it is the failure mode the provider-calibration follow-up warns about.
- **The geocoder is provisioned only inside `switch hostUiBundle`.** So a platform with no host-UI
  bundle has no geocoder to export, even though D9 makes geocoding a platform capability rather than
  a UI feature. Left alone deliberately — moving it is step 10's territory, where the Function URL is
  deleted anyway — but it is why the capability is not yet reachable on a headless platform.
- ~~**Found while wiring the DCB grant, not fixed: async DCB topics overwrite `dcbQueueUrlRef`.**~~
  **Fixed, first-wins as predicted.** `onDcbCommandTopicCreated` fires once per DCB command topic,
  and a plugin with async StateChangeSlices fires it twice
  ([Dcb_Builder.res:380](../../reventless/core/src/components/Dcb/Dcb_Builder.res#L380) then
  [:402](../../reventless/core/src/components/Dcb/Dcb_Builder.res#L402)) — the second (async, FIFO)
  call overwrote the sync topic's URL, and since the AWS hook never passes `~isFifo` the flavor was
  recorded as `false` either way. Any automation/outbound slice in such a plugin would have published
  its command to the async FIFO queue without a `MessageGroupId`, which SQS rejects — fault C's shape
  again, on the queue that had not yet been looked at. `setDcbQueueUrl` now keeps the first URL and
  flavor; the sync topic is created first and is the one a slice's command belongs on. The *grant*
  half was already immune and is unchanged: resources accumulate across both calls, and granting on
  both queues is correct. A no-op for every currently deployed plugin (none combines async slices
  with automation/outbound slices), which is why it rides along with step 7's deploy rather than
  needing one of its own.
- ~~**A slice-published command makes the aggregate's event unprojectable.**~~ **Fixed** — all three
  slice callbacks now tag the published command's `meta.service` with `Spec.targetName`, matching what
  the API path has always done, with a regression test that fails against the old code. See [blocker
  7](#the-end-to-end-run-the-loop-closes-and-the-last-hop-drops-the-answer). Unproven on AWS: the run
  that found it was against the deployed build, so the pin appearing needs one more deploy.
- ~~**The outbound retry/sweep path is unimplemented.**~~ **Fixed, both halves** — see [blocker
  6](#the-proving-deploy-the-wiring-is-confirmed-on-real-infrastructure-and-the-sweep-does-not-exist).
  The TODO table is read back on cold start, and an EventBridge rule sweeps the backlog every five
  minutes, so D4's retry behaviour and D1's reason for preferring an outbound slice over a hand-rolled
  `Task` both hold now. Unproven on AWS until the next deploy — in particular the scheduled
  invocation's shell branch, which no test can reach.
- **Retry-exhausted TODO rows are reloaded forever.** Measured on the deploy: twelve `AutoShipOrder`
  rows at `retryCount: 3` are re-read into memory on every cold container and re-written by every
  five-minute sweep, because the loader filters on *status* and "exhausted" is not a status —
  `maxRetries` is Spec-level and unknown at that layer. Harmless at twelve rows and wrong at scale.
  Two candidate fixes, neither taken here: thread `maxRetries` into the loader's filter, or give an
  exhausted row a terminal status so it stops being `Failed`. The second is probably right, since a
  row nothing will ever retry is not the same fact as a row that failed, and the read model showing
  the difference has value of its own.
- ~~**Step 9 is unblocked and small.**~~ **Done** — see [the step 9
  round](#the-step-9-round-the-capability-becomes-an-argument). It was the size predicted. Unproven on
  AWS: nothing has yet called Amazon Location through the SDK from a slice Lambda, so the new grant
  and `PLACE_INDEX_NAME` are the next deploy's first test. Waiting for step 7 to run first paid off
  exactly as argued — the transport is now the only thing that changed, so a geocoding failure after
  this points at the injection rather than at the design.
- ~~**Step 10 waits on a UI release**~~ — **built in both repos**; see [the step 10
  round](#the-step-10-round-the-client-door-opens-and-the-function-url-closes). All that is left is the
  release + deploy, whose order D9 sequenced and which is user-initiated.

### The step 10 round: the client door opens and the Function URL closes

The last decision was already made — D9 settled that geocoding copies the object store's two-door
shape, and step 10 is that shape built for the client half. Nothing surprising surfaced, because the
precedent it mirrors (`Upload_Presign`) is a working, shipped pattern with both doors; step 10 is the
mechanical application of it plus the deletions the second door makes safe.

| Half | Files |
|---|---|
| the SDL field | `Platform_AdminApi.res` — `geocodeTypes` / `geocodeQueryFields`; stitched into `domainBaseFragment` on AWS and registered on the local domain server |
| the AWS door | `Geocoder_AwsLocation_Resolver{,_Ops}.res` (mirrors `Upload_Presign_S3{,_Ops}`); wired in `Platform.res` gated on `cfg.geocoderPlaceIndex` |
| the local door | `LocalGeocodeResolvers.res` (deterministic dev stub); registered in `local/Platform.res` beside `LocalUploadResolvers` |
| the deletions | `Geocoder_AwsLocation{,_Ops}.res` + its Ops test; the `geocoderEndpoint` export and config.json key; UI `Geocoder.fromEndpoint` and `config.geocoderEndpoint` |
| the UI client | `Geocoder.fromShell` over the shell's authenticated transport (`AutoGraphQL.current`, kept fresh by `ShellApp`); `OptionalModes` builds it with no endpoint |
| the moved test | `Geocoder_AwsLocation_Resolver_OpsTest.res` — unset index throws, empty query is `[]` (the client-door restatement of D2's status contract) |

**Three choices worth keeping.**

1. **A Query, not a Mutation, and it forwards no identity.** Geocoding is a read and is not scoped per
   caller — any authenticated user may resolve any address — so the resolver's request mapper forwards
   only `ctx.args`, unlike the upload resolver which namespaces objects by the verified `sub`.
2. **The status contract narrows because the caller set does.** The Function URL served a browser and
   an unattended translator through one `200`/`502` body-vs-status split. The GraphQL door serves only
   the browser (the slice path reaches the SDK directly), so the contract collapses to
   *value = answer, thrown = no answer* — a no-match is `[]` and a service failure throws, which the
   response mapper turns into a GraphQL error rather than an empty list a browser would read as "no
   such address".
3. **Local finally has a geocoder door, and it is a stub on purpose.** The browser door and the slice
   door are independent, so local can register a working `Query.geocode` (deterministic coordinates
   from the query text) for the map search box while keeping the *unattended* path at
   `Capabilities.none`. Search works offline in dev; nothing pretends the coordinates are real.

**What is left is the deploy.** The safe order is the one D9 wrote down, and two of its three steps are
done: reventless-ui published `@reventlessdev/reventless-host-shell@3.0.0-alpha.55` (the Release job on
the UI push) and all three examples' pins are bumped to it (lockfile regenerated). The last step is one
core deploy that adds the resolver, serves the new bundle, and drops the Function URL in the same stack
update — deferred because a deploy is user-initiated, not because anything is unfinished. Running it
before the pin bump would have stranded the old bundle's search, which is why the bump lands first.
