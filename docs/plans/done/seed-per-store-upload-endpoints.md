# Plan: seeding a platform that publishes per-store upload endpoints

**Date:** 2026-07-31
**Status:** CLOSED 2026-08-02 — gap closed, **mechanism superseded**. Steps 1–5 were implemented
and unit-tested on 2026-07-31; route B of
[upload-release-path.md](./upload-release-path.md) then removed per-store presign *URLs*
altogether, and with them most of what this plan built. See
[What became of it](#what-became-of-it-2026-08-02). The two AWS verifications it left outstanding
are now subsumed by that plan's acceptance check 7 (seeding end-to-end through the mutation), which
awaits the same deploy.
**Repos:** `reventless-core` only.
**Analysis:** [platform-main-capability-provisioning.md](../../analysis/platform-main-capability-provisioning.md) §7 Stage 2.
**Builds on:** [declared-object-stores-without-host-ui-bundle.md](../declared-object-stores-without-host-ui-bundle.md)
(the `uploadEndpoints` / `objectStores` outputs this plan consumes).

## The gap

A platform that declares an object store now provisions it, serves it, and publishes its presign
URL — and **the seeder still reports the deployment as serving no uploads**. The observed symptom
on a deployed stack whose store is live and addressable:

```
product images: skipped (no upload endpoint / SEED_SKIP_UPLOADS) — imageUrl left absent
```

The store was reachable at the time that line was printed. Nothing about the deployment is wrong;
`ReventlessSeedAws.resolveEndpoints` cannot express a per-store endpoint, so it resolves the empty
string and the data set's upload phase no-ops exactly as it does for a deployment that genuinely
serves none.

`resolveEndpoints` branches on whether the stack publishes a `hostShellUrl`, and **neither arm reads
`uploadEndpoints`**:

```rescript
switch outputs->field("hostShellUrl")->Option.flatMap(asString) {
| Some(hostShellUrl) =>
  let cfg = await fetchConfig(hostShellUrl)
  let uploadEndpoint = resolveField(
    ~envKey="REVENTLESS_UPLOAD_ENDPOINT",
    ~fromSource=fromCfg("uploadEndpoint"),   // singular — the legacy single presign service
    ~human="uploadEndpoint",
  )
| None =>
  // Absent → "" → the data set skips its upload phase.
  let uploadEndpoint = Seed.Prompt.envValue("REVENTLESS_UPLOAD_ENDPOINT")->Option.getOr("")
}
```

- The **host-shell arm** reads `uploadEndpoint`, singular. A platform serving declared stores writes
  `uploadEndpoints` — a map keyed by the qualified `{plugin}.{store}` — and may write no singular key
  at all. The lookup misses and falls through to the env var.
- The **non-host-shell arm** has no stack-output lookup whatsoever. The env var is its only source,
  so a `PlatformOwned` deployment resolves `""` unconditionally no matter what it published.

The second arm is the one that matters, and it is not an edge case: a platform deployed without
`~hostUiBundle` is precisely the topology the preceding plan made serving unconditional *for*. Such
a stack publishes no `hostShellUrl` by construction — it has no host shell — so it takes the arm
that cannot see uploads at all, and it is also the only topology where the per-store endpoint is the
*sole* way to reach the store. The two properties travel together.

### The message is wrong in a way that costs time

`no upload endpoint / SEED_SKIP_UPLOADS` states a fact about the *deployment*. What actually happened
is a fact about the *client*: the deployment serves one and the seeder cannot address it. That
phrasing sends a reader to the platform stack, the bucket, the Function URL and the IAM policy — all
of which are correct — before anything points at endpoint resolution. Whatever else this plan does,
the skip message must distinguish "this deployment publishes no upload endpoint" from "this
deployment publishes endpoints I could not match to a store", and name the keys it saw in the second
case.

## What the platform already publishes

Nothing needs to be provisioned or deployed for this; both outputs exist as of the preceding plan:

| Output | Shape |
|---|---|
| `uploadEndpoints` | `{"{Plugin}.{store}": presignUrl}` |
| `objectStores` | `{"{Plugin}.{store}": {bucketName, keyPrefix, baseUrl}}` |

`Platform.getObjectStoreEndpoints()` is the in-process accessor for a root that needs the same
values; it returns `[]` rather than throwing when nothing is declared, which is the same
"empty is a legitimate answer" stance this plan needs at the seeder.

## The decision this plan turns on

`Seed_Connect.connection` carries **one** `uploadEndpoint: string`, and `Seed.Upload.uploadAsset`
takes `~uploadEndpoint` directly. So a data set cannot say *which* store an asset belongs in — there
is no argument for it. With one declared store the single string is unambiguous and a bare
"use the only endpoint" fix works; with two it silently uploads into whichever store the resolver
picked first.

That is the same failure the UI's store binding was built to prevent: a wrong guess uploads into
another plugin's bucket with a 2xx and a plausible-looking ref. `SchemaAnnotations.qualifiedStore`
returns `None` for an unqualified target rather than guessing a plugin, for exactly this reason. The
seeder should not adopt a weaker rule than the renderer that consumes the same declaration.

So the connection must carry the **map**, and the data set must name its store.

## Steps

**1 — `connection` carries per-store endpoints.**
Add `uploadEndpoints: dict<string>` alongside the existing `uploadEndpoint: string`. Keep both:
the singular one is the legacy single presign service and the local dev server's one upload route,
and the two middle rows of the UI's resolution table are what keep those working unchanged. Same
shape here, same reason.

`SEED_SKIP_UPLOADS` must clear *both*, or it stops being the single reliable knob its comment
promises.

**2 — `resolveEndpoints` reads the map in both arms.**
Host-shell arm: read `uploadEndpoints` from `config.json` next to the singular `uploadEndpoint`.
Non-host-shell arm: read the `uploadEndpoints` stack output — the lookup that is missing entirely
today. Neither is `resolveField`-with-throw: an absent map is a deployment that declares no stores,
which is legitimate and must stay a no-op rather than a failure.

`REVENTLESS_UPLOAD_ENDPOINT` keeps overriding the singular endpoint. Consider whether it should also
short-circuit the map — the argument for is that it is the documented escape hatch when discovery is
broken; the argument against is that a single string cannot express a map, so it can only ever
override *one* store and would need a naming convention to say which. Prefer leaving the map
un-overridable and adding a `REVENTLESS_UPLOAD_ENDPOINT_{PLUGIN}_{STORE}` form only if a real need
appears.

**3 — a data set names the store it uploads to.**
`uploadAsset` gains a way to say `Catalog.productImages` and resolve it against the connection's map,
falling back to the singular endpoint when the map has no such key — the same four-row resolution the
UI's `adapterForField` already documents:

```
declares a store with a matching endpoint  → that store's endpoint
declares a store with no matching endpoint → the legacy single service
declares no store                          → the legacy single service
neither available                          → skip, with a message naming the store it wanted
```

Reusing that table verbatim is deliberate: two clients resolving the same declaration by different
rules is how the qualified/unqualified seam produced a silent wrong-bucket write once already.

**4 — the example data set declares its store.**
`HybridSeedData`'s product-image phase names `Catalog.productImages` instead of taking whatever
single endpoint the connection carried.

**5 — the skip message tells the truth.**
Distinguish the three cases: no endpoints at all, endpoints present but none matching the requested
store (name the store *and* the available keys), and `SEED_SKIP_UPLOADS` set.

## Verification

- A platform **with** a host shell and a singular endpoint seeds images exactly as before — this is
  the regression that matters, since steps 1–3 all touch the path it uses.
- A platform **without** a host shell that declares one store seeds its images, and the resulting
  refs resolve through the store's `baseUrl` from `objectStores`. Before this plan that platform
  cannot upload at all, so there is no "as before" to preserve.
- A data set naming a store the deployment does not serve skips **with the store named**, and does
  not upload into a different store.
- `SEED_SKIP_UPLOADS` skips regardless of which endpoints exist.

The first two need a deployed stack; a unit test over `resolveEndpoints` with synthetic outputs
covers the branch selection, which is where the defect actually lives.

## Implementation (2026-07-31)

All five steps, as written. Three decisions the plan left open, and one thing it did not anticipate.

**The store is resolved at the connection, not inside `uploadAsset`.** Step 3 said "`uploadAsset`
gains a way to say `Catalog.productImages` and resolve it against the connection's map" — but
`uploadAsset` would then need the connection, and `Seed_Connect` already depends on `Seed_Upload`.
So the four-row rule is `Seed.Upload.endpointFor` (pure, takes the store, the legacy endpoint and
the map) and `Seed.Connect.uploadEndpointFor(connection, ~store)` is the one-liner over it that a
data set calls, returning `Ok(endpoint)` or `Error(reason)`. `uploadAsset` stays the transport and
still takes a resolved `~uploadEndpoint`. Same four rows, one fewer thing that has to know about a
connection.

**`REVENTLESS_UPLOAD_ENDPOINT` overrides the singular endpoint only**, as the plan preferred. No
`_{PLUGIN}_{STORE}` form was added.

**The host-shell arm's singular endpoint stopped throwing.** Not in the steps; found while writing
them. That arm resolved `uploadEndpoint` through `resolveField`, which *fails the run* when the key
is absent — and a shell fronting only declared stores writes no singular key, because `config.json`
omits it when the platform has no legacy presign service. So the topology the plan is about had a
second, harder failure waiting one arm over: not "reports no uploads" but "cannot connect at all".
Both arms now resolve it through an `optionalField` that falls back to `""`, which is the same
"empty is a legitimate answer" stance the map needs. A test pins it.

**Tests.** `endpointsFrom` is the pure half of `resolveEndpoints` — the impure half is a
`pulumi stack output` subprocess and a `config.json` fetch, and the branch selection is in neither.
Two new jest projects, 16 tests: `reventless-seed-aws` covers both arms (the map read on each, the
absent-map no-op, the merged/per-plugin endpoint preference, the malformed member, and the
shell-with-no-legacy-service case above); `reventless-seed` covers the four rows and the three skip
messages. Both packages needed a `tests` source dir, `rescript-jest`, a jest project, and a
build-chain entry — appended **last** and in dependency order (`seed-aws` → `seed`), because the
`platform-aws` builds earlier in the chain carry both in their graph and orphan their test outputs.

**Verified.** Full suite 2438/2438 (282 suites), zero warnings. A local hybrid seed run uploads all
16 product images through the dev server's single route while the data set names
`Catalog.productImages` — the "declares a store with no matching endpoint" row, which is the
regression that mattered most since the map is empty there. With `SEED_SKIP_UPLOADS=1` the same run
reports `product images: skipped (SEED_SKIP_UPLOADS is set) — imageUrl left absent`.

**Not verified — needs a deployed stack.** The two AWS bullets under Verification: a host-shell stack
(`online-shop-hybrid-platform-aws`) seeding images exactly as before, and a shell-less stack that
declares one store (`online-shop-aggregates-platform-aws`) seeding images whose refs resolve through
`objectStores.baseUrl`. The second is the one this plan exists for and has never worked; it is also
gated on that example's platform being deployed, which the preceding plan's "Still to do" already
records.

## What became of it (2026-08-02)

Route B moved minting behind the domain API's `Upload_Presign(store, fileName, contentType)`
mutation. A caller now **names the store and gets a URL back**, where before it had to **find the
store's URL**. That inverts the problem this plan solved, so most of its machinery had nothing left
to do and was deleted rather than adapted:

| Step | Fate |
|---|---|
| 1 — `connection` carries `uploadEndpoints` | **Gone.** No per-store URL is published, so there is no map. |
| 2 — `resolveEndpoints` reads the map in both arms | **Gone.** `endpointsFrom` now decides only which GraphQL endpoint each arm takes. |
| 3 — four-row `endpointFor` / `uploadEndpointFor` | **Gone.** There is one endpoint and the store is an argument, so there is nothing to resolve and no way to mis-resolve. |
| 4 — a data set names the store it uploads to | **Survives, and is now load-bearing.** `~store` is the mutation's argument; `HybridSeedData` passes `"Catalog.productImages"`. |
| 5 — the skip message tells the truth | **Partly.** `SEED_SKIP_UPLOADS` still reports itself; the "endpoints present but none matching" case it distinguished can no longer occur. |

The half worth keeping is the one this plan argued hardest for. Its decision section says *"the
connection must carry the map, and the data set must name its store"* — the map was the mechanism
and the naming was the principle, and only the mechanism was contingent on how mint was exposed.
The failure it was defending against (a wrong guess uploading into another plugin's bucket with a
2xx and a plausible ref) is now structurally impossible: an unnamed store is not a wrong store, it
is a missing required argument.

Also retired with the URLs: `config.json`'s `uploadEndpoint`/`uploadEndpoints` fields, and the
platform's `uploadEndpoints` stack output. `objectStores` stays — it carries bucket and prefix, not
an endpoint, and the reset and reconciliation tools both read it.

## Out of scope

- **Multi-store data sets.** Step 3 makes the store nameable; nothing here needs a data set that
  writes to two. The mechanism should not be designed around one that does not exist.
- **Reading the store from the field's schema annotation.** The renderer resolves the store from
  `x-reventless-semantic-target` on the field, and a seeder could in principle do the same instead of
  having the data set name it. That is the better long-run answer — it removes the second spelling —
  but it requires the seeder to hold the component schema at upload time, which it does not today.
  Worth revisiting once a data set has more than one asset field.
