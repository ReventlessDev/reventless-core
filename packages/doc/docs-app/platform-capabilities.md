---
title: Platform Capabilities
---

# Platform Capabilities

A **capability** is infrastructure a plugin needs but does not provision: somewhere
to put an uploaded image, something that turns an address into coordinates,
something that puts a mail in front of a customer. The plugin **declares** what it
needs in its own vocabulary; the platform **provisions** it; the framework carries
the declaration between the two stacks and refuses a deploy where the two disagree.

Three capabilities are supported today. The mechanism is deliberately open-ended —
the list below is where it has been taken so far, not the limit of what it models.

The reason for the ceremony is the split-stack ordering: **the platform deploys
first and cannot read the plugins' schemas.** So the platform's list is written
before anything can check it against what the plugins actually want, and every
symptom of getting it wrong is silent — an upload input that finds no endpoint and
writes to the wrong bucket, a geocode that answers `Unavailable` until the retries
run out, a confirmation mail nobody notices was never sent. The declaration, the
manifest and the deploy gate exist to turn each of those into a refusal with a name
on it.

## The capabilities supported today

**Three, and the set is expected to grow.** What follows is the roster this
release provisions, not a closed model of what a plugin may ever need — a queue, a
scheduler, a payment processor and a search index are all the same shape of thing,
and each would arrive as another arm here. Treat the list as a fact about the
version you are building against, and see [When the set grows](#when-the-set-grows)
for what a new capability does and does not disturb.

The roster is `ReventlessInfra.Platform.capability` — a real variant, so the
compiler finds every consumer when the set grows:

```rescript
type capability =
  | ObjectStore({plugin: string, store: string})
  | Geocoding
  | Messaging
```

| | **ObjectStore** | **Geocoding** | **Messaging** |
|---|---|---|---|
| What it is | A bucket for values events reference | Address → ranked candidates | Sending a message to a person |
| Declared by | a **field** | a **slice** | a **slice** |
| Identity | `{plugin}.{store}` | the capability | the capability |
| Travels as | `requiredStores` | `requiredCapabilities` | `requiredCapabilities` |
| Reached at runtime | client presign (see below) | `capabilities.geocode` | `capabilities.messaging` |
| Provisioned on AWS | `Capability_ObjectStore_S3` | `Capability_Geocoding_AwsLocation` | `Capability_Messaging` (SES or log) |
| Locally | in-memory / filesystem store | not provisioned — answers `Unavailable` | log transport, prints and sends nothing |
| Deploy gate | `Util_StoreLayout.coverageFor` | `CapabilityNeed.unmet` | `CapabilityNeed.unmet` |

`ObjectStore` is the one carrying an identity beyond its own name, and the reason
is that a deployment has several: two plugins that pick the same store name get two
stores. That mirrors how a field's declaration reads — an unqualified
`@storageRef("productImages")` means *this* plugin's store. A deployment has one
geocoder and one mail sender, so those need no key.

### When the set grows

Adding a capability is a framework change, not something a plugin can do locally —
but almost none of the cost lands on application code, and that is by design rather
than by luck:

- **`Capabilities.t` is a record, not a widening argument list.** A new field
  breaks the handful of places that *construct* it — the platforms, which is
  exactly where a new capability has to be wired anyway — and leaves every
  `translate` reading `capabilities.geocode` untouched.
- **The roster and the need are real variants**, so when the set grows the compiler
  names every consumer that has to be revisited instead of leaving a string
  comparison to fail at runtime.
- **The wire carries strings.** `pluginStructure` and `capabilities.json` persist
  capability names as text, so a plugin built against a newer framework still
  decodes in an older reader. A name the reader does not recognise is reported as
  unrecognised, never folded into a known arm.
- **An older platform does not refuse a newer plugin's unknown need.** The deploy
  gate skips a capability this build cannot evaluate, because refusing over one it
  cannot reason about would be a guess dressed as a check. The capability then
  degrades the way an unprovisioned one always does — `Unavailable`, retried, and
  visible in the sweep.

The practical consequence: pin the framework version you declare against, and
expect a capability that is missing rather than mis-declared to surface as queued
work, not as a crash.

## Two declaration rails

### Fields declare object stores

A field says its value lives in a store, and that *is* the declaration — there is
no separate list to keep in step with it:

```rescript
| UpdateImage({@storageRef("productImages") imageUrl: string})
```

The plugin build walks the command, event and state schemas, collects every such
field into `pluginStructure.requiredStores` (qualified) with
`requiredStoreDeclarations` as provenance, and the platform provisions from the
union across its plugins. The semantic types `UploadableImage.t` and
`UploadableFile.t` declare the same thing through the shared `Semantic.StoredIn`
marker, as does `@offload` for a large value carried inline-or-by-reference.

Two consequences worth knowing before you rename a field:

- **A declaration can destroy infrastructure.** A hand-written bucket could only be
  removed by editing Pulumi; a declared one disappears when the last
  `@storageRef` naming it does. Hence `~protect`, on by default and turned off only
  for stacks that are routinely torn down.
- **Guessing is a lint, never a mechanism.** `Capability_Inference` re-runs the
  UI's field-name heuristics (`imageUrl`, `photo`, `*storageRef`, …) over the same
  schema walk and *warns* about a field that looks like a stored ref but declares
  no store. It never provisions: `imageUrl` is genuinely ambiguous between an
  uploaded object and an external URL, and only its author can say which.

### Slices declare geocoding and messaging

An **OutboundTranslationSlice** — the component that reaches outside the
deployment, and the only one that declares capability needs — exports a value:

```rescript
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = [Messaging]
```

A trait exports its own, so a host names it rather than repeating it:

```rescript
let capabilityNeeds = TraitAddressGeocoding.AddressGeocoding.capabilityNeeds
```

`CapabilityNeed.t` has two constructors, `Geocoding` and `Messaging`. **Object
stores are deliberately not among them** — a store need is already declared by the
field and identified by `(plugin, store)`, which a bare capability name cannot
carry. This type is for the needs no field can express.

It is also **one need however many channels** the platform provisions. Which
channels those are is a runtime answer the provider publishes, not a second
declaration, because a plugin that declared `Sms` would fail a deploy it could
have run on email.

Both spellings persist as **strings**, not enum members, in `pluginStructure` and
in `capabilities.json` — so a plugin built against a newer framework still decodes
in an older reader, and a capability name this build does not recognise is reported
as unrecognised rather than silently dropped into a known arm.

## From declaration to provisioning

1. The plugin build writes **`capabilities.json`** beside the generated
   `Plugin.res` — one entry per capability, keyed by identity, with the declaring
   sites as provenance. Keys are taken verbatim from `pluginStructure`, so the
   manifest is a *rendering* of the structure and never a second scan of the
   sources; the two cannot spell one fact differently. A plugin that declares
   nothing yields an empty list, not an absent file — "declares nothing" is a
   statement, distinguishable from "was never built".
2. `pnpm run generate:platform` unions the manifests the deploy manifest names and
   writes the platform's list:

   ```rescript
   // AUTO-GENERATED — do not edit.
   let capabilities: array<ReventlessInfra.Platform.capability> = [
     // catalog: Products.productImage → productImages
     ObjectStore({plugin: "Catalog", store: "productImages"}),
     // ordering: GeocodeCustomerAddress
     Geocoding,
     // ordering: SendNotification
     Messaging,
   ]
   ```

   The provenance comments are the point: when a capability disappears from this
   list, the diff says which change removed it.
3. The platform root calls the `Capability_*` helper for each and passes the
   handles to `deployPlatform`. After a `@storageRef` change: rebuild the plugin,
   regenerate, review the diff.

## What is injected, and what is not

A slice's `translate` is handed a record with **two** of the three:

```rescript
type t = {
  geocode: Geocoding.search,
  messaging: Messaging.provider,
}
```

Injected rather than looked up, and required rather than optional, because the
alternative is a slot filled at cold start that nothing enforces: ES modules
evaluate imports before the importing module's body, so "the entry point runs
first" is an assumption a bundling change can quietly break. A missing argument
does not compile; an unfilled slot fails on the first real address, in production.

A record rather than a widening argument list, so adding a capability breaks only
the places that *construct* it — the platforms, which is where a new capability has
to be wired anyway — and leaves every `translate` reading `capabilities.geocode`
untouched.

**The object store is the exception, and it is an open seam rather than a
boundary.** Its runtime half today is client-side: the browser gets a per-store
presigned PUT and the minted ref is what the field carries. Plugin code that wants
to read an offloaded value back calls `Offload.resolve(~fetch)`, which has no
injected caller yet — the accessor for it belongs in this record and is not there.
So `Capabilities.t` is where two of three capabilities are reached, not the
definition of what a capability is.

### Unavailable is a modelled outcome

`Capabilities.none` is the capability set of a platform that provisions nothing.
Every call answers `Unavailable`, `translate` maps that to `Error`, the item is
retried and the sweep surfaces it. That is the wanted behaviour for a deployment
that simply has no geocoder: the work stays **queued and visible** rather than
being written off as a verdict on the data — which is what a `NoMatch` would mean.
It is named so that a platform passing it is making a statement rather than filling
in a blank.

## The two deploy gates

**Slice-declared needs** — `CapabilityNeed.unmet` compares what the plugins
declared against what the platform provisioned, and a mismatch refuses the deploy
naming the capability, the component that asked, and what happens if it ships:
every call answers `Unavailable`, the slice exhausts its retries, and a permanent
verdict is recorded against data that is fine, with no error anywhere. Only what
was declared is checked — a plugin that declares nothing is unaffected.

**Stores** — `Util_StoreLayout.coverageFor` is the same set difference with
**three** outcomes rather than two:

| Outcome | Meaning |
|---|---|
| `Covered` | Every declared store is provisioned. |
| `NotAdopted` | The platform provisions *no* stores — it has not adopted capability provisioning at all. |
| `Missing` | The platform provisions some stores but not this one: a missing or misspelled entry. |

Collapsing the first two would force a choice between breaking every deployment
that predates the mechanism and not helping the ones that have adopted it. Being
strict here is worth it because the symptom is silent: the upload input finds no
per-store endpoint, falls back to the legacy single service, and writes to whatever
bucket that serves — a 2xx, a plausible ref, and the wrong destination.

## Messaging channels

The messaging capability is the one with a vocabulary inside it. Three channels are
defined; **one has a transport today**:

| Channel | Address | Status |
|---|---|---|
| `Email` | `Email.t` | Provisioned — SES, or a log transport that prints and sends nothing |
| `Sms` | `Phone.t` | No transport. `messagingSmsSender` is carried so a stack can state the number, but nothing reads it |
| `Push` | `{deviceToken: string}` | Defined only |

A channel appears when a transport does, not when its config key exists — claiming
one ahead of its backend would collect preferences that silently deliver nothing.
So the vocabulary here is also a statement of intent: SMS and push are modelled,
addressed and routed, and what is missing in each case is the provider binding.

A `(channel, address)` pair can be built wrong — `Sms` beside an email address
compiles and fails at the provider — so `recipient` fuses them and the channel is
read back off the value that carries it. A send answers a receipt or one of three
failures, and the split is the retry rule: `Unavailable` retries, while
`UnsupportedChannel` and `Refused` do not. Everything that sweeps a failed send
derives from `Messaging.retriable` rather than re-reading the constructors.

### Read `provider.channels` before offering a choice

The provider publishes what it can attempt:

```rescript
type provider = {
  channels: array<Messaging.channel>,
  send: send,
}
```

**A preference centre must render that list, not the three above.** Offering a
channel nothing can deliver on collects a subscription that never arrives, and
discovering a channel by failing on it costs a real message. `Messaging.supports`
is the check, and it applies the same rule the provider applies internally, so the
two cannot disagree. An empty list means no channel at all — which is the shape
`Capabilities.none` takes, and what the deploy gate exists to catch before it
ships.

This matters because the domain side has its own copy. The notification trait's
`Notification_Rules.channel` mirrors all three — it is the domain's vocabulary,
carrying a host's schema and travelling on the wire, where the platform's is the
capability's — and its subscription matrix is kind × channel over the full set. So
a recipient *can* be recorded as subscribed on a channel this deployment will then
answer `UnsupportedChannel` for. Nothing is wrong with that: the record is a
preference, and the guard is reading `provider.channels` at the point a choice is
offered.

## Configuration

Which transport, which sender, which place index — all of it is per-deployment
configuration rather than code, read off the usual ladder (env var,
`Pulumi.local.yaml`, then `platform:<key>`). See the
[deployment guide](/infrastructure/deployment-guide) for the keys, their defaults,
and what each does when unset.

## See also

- [Domain Traits](./domain-traits.md) — traits that export a `capabilityNeeds` for
  a host to name.
- [Plugin System](./plugin-system.md) — where `pluginStructure` comes from.
- [Deployment guide](/infrastructure/deployment-guide) — the config keys and the
  deploy-time refusals.
