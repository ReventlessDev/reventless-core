# Platform capabilities: one capability, two doors

Some things a plugin needs are not code it can carry. Storing a large file needs a
bucket; turning an address into a point needs a geocoder. Neither belongs in a
plugin package, because a plugin is **provider-agnostic** — it depends on
`reventless-core` and never on `reventless-aws`. A plugin that imported the S3
adapter would be a plugin that only ever deploys to AWS.

So these are **capabilities**: declared by a deployment, provisioned by the
platform, brokered by the framework. They are named in
`ReventlessInfra.Platform.capability`:

```rescript
type capability =
  | ObjectStore({plugin: string, store: string})
  | Geocoding
```

## The shape: two doors, not one seam

The mistake worth naming up front is assuming one seam has to serve every caller.
It does not, because a capability has two callers that want opposite things:

| Caller | Reaches the capability through | Why that one |
|---|---|---|
| a client — browser, seed, any API consumer | a **field on the platform GraphQL API** | a browser cannot import a ReScript module or hold a credential; it can call an authenticated mutation |
| plugin backend code | an **injected function** | a Lambda can hold a function; routing it through a public HTTP endpoint would add a hop and put a browser-facing surface on its critical path |

Neither door is a compromise for the other, and having both duplicates nothing —
they open onto the same provisioned resource.

## The worked example: the object store

Both doors are shipped and both have two implementations, which is what makes this
a precedent rather than an analogy.

**The client door** is `Upload_Presign` / `Upload_Release`, registered on AppSync
by the AWS platform and on the dev server by the local one
(`LocalUploadResolvers.res`, backed by `LocalObjectStore.res` — a process-local
dict of Node buffers, ephemeral by design). A client cannot tell which it is
talking to. The local platform's `deployPlatform` ignores `~capabilities`
entirely, because it provisions nothing. "Swap the implementation" has therefore
already happened once, and what made it possible was the **mutation contract**,
not an adapter module.

**The plugin door** is `Offload.resolve(payload, ~schema, ~fetch)` — the reader is
handed its fetcher rather than looking one up.

### Three layers, three different portability answers

Worth separating, because only one of them is stuck:

| Layer | Portable? | Why |
|---|---|---|
| the ref format `/{prefix}/{key}` | yes, by design | rooting keys at the store name keeps a stored ref independent of whether the store got its own bucket or a prefix in a shared one. Refs live in an append-only log, so one that encoded its layout would be unrewritable |
| the runtime read/write path | yes — two implementations exist | `~fetch` is injected; `Upload_Presign` is a contract, not a URL |
| the deploy-time handle | **no** | `ReventlessInfra.Platform.objectStore` sits in the provider-agnostic layer and is S3-shaped (`bucketArn`, `bucketRegionalDomainName`), and no `module type` declares what an implementation must satisfy |

So the object store is **switchable by platform** (AWS ↔ local, proven) and **not
switchable within one** (S3 → MinIO/GCS on the AWS platform). That may be the right
trade — a platform package arguably *is* the provider choice — but it means the
portability story is "pick a different platform", not "pick a different backend".
Recorded so it is not rediscovered as a surprise.

## Deploy-derived values reach a Lambda as environment

A capability's endpoint is computed by the platform and consumed by a plugin's
runtime, and in split-stack deployments those are two different Pulumi programs.
The path is:

1. `deployPlatform` provisions the resource and `Pulumi.Pulumi.export`s its
   endpoint. Unset ⇒ `""` rather than a missing output, so the read side has one
   shape to handle instead of two.
2. `deployPlugin` reads it — across the platform `StackReference` in plugin mode,
   out of the platform's own module-level ref when platform and plugin are one
   program — and calls `PluginRuntime_Builder.registerCapabilityEnv`.
3. The slice runtime builder merges the registered dict into its Lambda's
   `envVars`.

Step 2 must happen **before** the plugin builds: the slice runtime finalizers fire
from inside `P.make()`, and a variable registered after it is built into nothing.

**Why not `commandHandlerConfig`?** It already carries an `envVars` field, and it
is the wrong channel: that path is for values a *human deployer chooses* — memory,
timeout, concurrency. A capability endpoint is *derived by the framework* from
another stack's output. Routing it through hand-authored config would mean a
deployer copying a generated URL into a config file, which is exactly the
hand-restated value this framework removes everywhere else.

**Never `option<Pulumi.Output.t<'a>>`.** Any generic `Option.*` over an Output
compiles to `valFromOption`, whose nested-option probe hits the Output proxy —
where every property access returns a truthy Output — and corrupts it. Use a plain
Output with `""` as the sentinel.

### Degrading, not failing

A plugin deployed against a platform that provisions none of the capability gets
`""`, and its client reports the capability as unavailable. For geocoding that is
`Geocoding.Unavailable`, a modelled outcome: the item is retried and then surfaced
by the heartbeat sweep. This matters because the platform stack must be deployed
before the plugin stack for the export to exist at all, and the ordinary
consequence of getting that wrong should be a retry, not a failed deploy.

## Geocoding

Same shape, arriving in two halves.

The **policy** — what a candidate is, the two ways a lookup fails, and when a
ranked list is confident enough to store a coordinate — is provider-neutral and
lives in `Reventless.Geocoding`, decided once so no transport re-invents it. The
port is a type:

```rescript
type search = (~text: string) => promise<result<array<candidate>, failure>>
```

The **transport** is provider-specific. `Geocoder_AwsLocation_Backend` owns the
Amazon Location call, the RFC 7946 `[lng, lat]` order, and the relevance handling
— one owner, both doors.

The two failure constructors are not decoration. A caller that cannot tell "no
such address" from "the service is down" turns one outage into a permanent verdict
on every address in flight. The same distinction is what the geocoder Function
URL's status contract carries: `200` with a possibly-empty array is *an answer*;
any other status is *no answer*. A browser reads the body and degrades to "no
results" either way; an unattended caller reads the status and knows whether to
retry. One contract serves both because they disagree only about which half of the
response they read.

### Two paths to a point, and why they do not collide

A geo point can be set by a human with a map picker or by an unattended slice, and
both may be live at once:

- **the client path** — the picker in the host shell. The user places a pin and
  the command carries the point.
- **the unattended path** — an `OutboundTranslationSlice` that geocodes an address
  nobody pinned.

They stay out of each other's way with two guards, doing two different jobs:

- **in `collect`, before the call** — an event that already carries a point yields
  no TODO row. This saves the geocoder *request*, and the request is what costs
  money.
- **in the aggregate, after the call** — a command whose point and provenance
  already match current state returns `Ok([])`. This prevents duplicate *events*,
  and it is the one that survives at-least-once redelivery.

The first alone is not correct under redelivery; the second alone pays for every
duplicate geocode. Both, not either.
