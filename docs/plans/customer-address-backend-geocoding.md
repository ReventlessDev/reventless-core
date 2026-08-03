# Plan: an address is entered once, and the backend finds the point

**Date:** 2026-08-03
**Status:** IN PROGRESS — steps 1–8 built and green (full suite 301 suites / 2721 tests; the one
red, `LocalAuthHttpTest`, is a port-binding flake under full-suite load and passes alone and with
its whole project). **D9 is resolved** (two callers, two seams). Step 7's fast path is wired end to
end in code but **has never run against a real geocoder** — that is the gate on step 9, which is
otherwise ready. Step 10 waits on a UI release. See [Build log](#build-log) at the foot for what
landed and what the build taught that the plan had wrong.
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

**7 — Make it run: the fast path. ✅ wired; unproven against a live geocoder.**

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

**9 — The injected port (D9 half 1). ⬜ after step 7 runs.** Replace `GeocodingService`'s HTTP call
with the real injection: thread a geocoder to `translate` the way `Offload.resolve` threads `~fetch`,
supplied by the platform and backed by `Geocoder_AwsLocation_Backend` calling the SDK directly. The
port type from 7a is already the target, so the plugin-side change is deleting a file and accepting an
argument. Deploy side: the slice's Lambda gains place-index read permission and the index name,
replacing `GEOCODER_ENDPOINT`. Knock-on: the two existing outbound slices and the GWT harness absorb
the `translate` signature change — the same shape as step 1's `~sourceId`, which touched five call
sites.

**10 — Geocoding on the platform API (D9 half 2). ⬜ deferred, cross-repo.** A geocode field on the
platform GraphQL API, mirroring `Upload_Presign`, resolving through the same
`Geocoder_AwsLocation_Backend`. The map picker moves onto it; the public Function URL and
`geocoderEndpoint` are then deleted. Lands with a UI release, not before — see D9's sequencing for
why the interval is safe.

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

**Not covered by any of the above, and worth stating plainly:** every slice test mocks `translate`,
so nothing exercises a real geocoder. D3's relevance threshold against real scores and the SDK call
itself remain unverified, as does the success path of the Function URL handler. The first deployed
run is the first test of them, and the most likely place for this design to be wrong.

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

### Open

- **Step 7 is wired but unproven.** Every code path exists and compiles; nothing has spoken to a real
  geocoder. The first deployed run is still the first test of D3's relevance threshold against real
  scores and of the SDK call itself, and it is the gate on step 9.
- **The geocoder is provisioned only inside `switch hostUiBundle`.** So a platform with no host-UI
  bundle has no geocoder to export, even though D9 makes geocoding a platform capability rather than
  a UI feature. Left alone deliberately — moving it is step 10's territory, where the Function URL is
  deleted anyway — but it is why the capability is not yet reachable on a headless platform.
- **Step 9 is ready and blocked only by evidence.** The port type it targets exists (7a), and the env
  channel it needs is built and shared with step 7. What remains is deleting `GeocodingService`,
  accepting an argument in `translate`, and granting the Lambda place-index read.
- **Step 10 waits on a UI release** — cross-repo, and the interval is safe by D9's sequencing.
