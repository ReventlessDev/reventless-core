# Plan: declared object stores without a host-UI bundle

**Date:** 2026-07-29
**Status:** **Steps 1–3 implemented, released and deployed 2026-07-29. Step 1 is live-verified;
step 2's `PlatformOwned` arm is not, and no deployment exercises it.** Build green;
`reventless-aws` 376/376 (36 suites, +5 new), `reventless-core` 553/553, default suite 2264/2264.
The serving decision was extracted to `Util_StoreLayout.servingFor` so it is a unit-testable
three-way choice rather than a condition buried in `deployPlatform` — see
[What landed](#what-landed). Step 2's live verification is outstanding: it needs a deploy, and no
preview can show that a bucket policy grants what it claims.
**Repos:** `reventless-core` only.
**Analysis:** [platform-main-capability-provisioning.md](../analysis/platform-main-capability-provisioning.md) §5.3, §7 Stage 2.
**Builds on:** [platform-capability-provisioning-stage-2.md](./done/platform-capability-provisioning-stage-2.md)
(declaration-driven object stores).

## The gap

Stage 2's guarantee is that **the store a field declares is the store it uploads to**. That holds
only when the platform also deploys the host-UI shell. A platform deployed *without*
`~hostUiBundle` provisions the stores and can neither address nor serve them.

The asymmetry is not in the provisioning — it is in what consumes it. In `Platform.deployPlatform`:

- `declaredStoreServices` and `declaredServedBuckets` are computed **unconditionally**. The bucket,
  its public-access block, the per-store presign Lambda, its prefix-scoped IAM policy and its
  Function URL are all created whether or not a host UI is deployed.
- Every consumer of that work sits inside `switch hostUiBundle { | None => () | Some(cfg) => … }`:
  - `storeUploadEndpointsOutput` → the `uploadEndpoints` map in the host shell's `config.json`,
  - `declaredServedBuckets` → `~servedBuckets` on `Plugin_Stack.makeUiBundleDistribution`, which is
    what creates the CloudFront OAC origin *and* the per-bucket `BucketPolicy` granting read.

So with no host-UI bundle the result is a **write-only store nobody can name**: no endpoint is
published anywhere, and because the bucket is created with `blockPublicPolicy: true` and gets its
read grant only from that distribution, no object in it is readable by anything.

This is not hypothetical shape-guessing — it is what the code does today. It matters because
deploying the UI from its own stack is a supported topology: `makeUiBundleDistribution` is public,
takes `~servedBuckets`, and is designed to be called by a stack that is not the platform. The one
thing such a stack cannot do is *learn what the platform provisioned*.

### Why the existing accessors don't cover it

`getApiConfig()` and `getSplitApiOutputs()` exist for exactly this reason — a root that needs values
`deployPlatform` computed internally. There is no equivalent for stores: `declaredStoreServices` and
`storeUploadEndpointsOutput` are locals in `deployPlatform`, and nothing exports them. A root cannot
re-export what it cannot reach.

## The decision this plan turns on

Stores are provisioned by the platform stack; the distribution that serves them may not be. **S3
allows exactly one bucket policy per bucket**, and `makeUiBundleDistribution` writes one per served
bucket. Two distributions in two stacks serving the same store therefore *cannot* both write it —
the second silently replaces the first's grant and breaks the first's reads.

That constraint rules out the tempting answer ("export the served-bucket descriptors and let each
consumer wire its own origin") as a general mechanism, and it is the reason this plan is not simply
"add a stack output".

Three options:

1. **Export endpoints only.** The platform publishes `uploadEndpoints`; serving stays the host-UI
   branch's job. An external UI can upload but still cannot read back what it wrote unless the
   platform also deploys a shell. Half a fix, and the half that fails is invisible until an image
   renders.
2. **Export endpoints and served-bucket descriptors, and let the consumer own the policy.** Works
   for exactly one serving distribution per store, and corrupts silently with two. The failure is a
   broken image, not an error.
3. **Export endpoints, and give the platform a way to serve its own stores independently of the
   shell.** The bucket policy stays with the stack that owns the bucket — one writer, by
   construction — and the consumer needs only a URL prefix.

**Recommendation: option 3**, with option 1's export as the first step since it is needed either way.
Ownership of the policy should not move to whoever happens to build a distribution; the bucket's
stack owns the bucket's policy, which is the same reasoning that moved store provisioning to the
platform in Stage 2 (*What landed, and what the plan got wrong*).

## Steps

### 1. Export the declared store topology as stack outputs

Immediately after `declaredStoreServices` / `declaredServedBuckets` are built — **outside** the
`hostUiBundle` switch — export:

- `uploadEndpoints`: `{plugin}.{store}` → presign Function URL. Same key grammar and same name as
  the `config.json` field, so there is one vocabulary rather than two.
- `objectStores`: `{plugin}.{store}` → `{bucketName, keyPrefix}`. A consumer building asset URLs
  needs the prefix, and per-store refs are rooted at `/{store}/…`, so a CDN-fronted consumer needs
  one entry per prefix rather than one global upload path.

Omit both entirely when nothing is declared, so a deployment that declares no stores keeps a
byte-identical output set. That is the same discipline the `config.json` emission already follows.

Add `getObjectStoreEndpoints()` alongside `getSplitApiOutputs()` for symmetry, returning `[]` rather
than throwing when called before `deployPlatform` — it is a legitimate "nothing declared" answer,
unlike `getApiConfig()`'s "called too early".

**Verify:** a platform with no declared store exports neither key; one with a declared store exports
both, and `pulumi preview` on an existing stack shows no resource changes — outputs only.

### 2. Serve declared stores from the platform stack

Give the platform its own read path for declared stores, independent of `~hostUiBundle`: a
distribution (or origin set) owned by the platform stack, with the per-bucket `BucketPolicy` written
by the same stack that creates the bucket.

Export the resulting public base URL per store as part of `objectStores` (a `baseUrl` field). A
consumer then needs no bucket identity at all — it needs a URL — which is both a smaller contract
and one that cannot collide.

When `~hostUiBundle` *is* passed, keep today's behaviour: the shell's distribution serves the stores
same-origin, and `config.json` is unchanged. Two serving paths for one store is exactly the
bucket-policy collision above, so this is either/or, decided by whether the platform deploys a
shell.

**Verify:** deploy a platform with a declared store and no `~hostUiBundle`; PUT through the presign
URL, then GET the object through the exported `baseUrl`. Both must succeed. Then deploy one *with*
`~hostUiBundle` and confirm the preview is byte-identical to before this plan — the host-UI path is
the one that already works and must not move.

### 3. Document the topology

The choice between "platform deploys the shell" and "UI deploys separately" now has a consequence
for stores, and nothing states it. Record in the capability analysis which side owns serving in each
case, and that the bucket policy is the reason it cannot be both.

## What this deliberately does not do

- **No inference.** `~capabilities` stays hand-written; joining it to `pluginStructure.requiredStores`
  is Stage 3 and is unaffected by this plan.
- **No change to the ref grammar.** Refs stay `/{store}/…` in both bucket layouts. This plan changes
  only who can *resolve* a ref to a URL, not what a ref is.
- **No change to the host-UI path.** A platform that passes `~hostUiBundle` should see no diff.

## Risks

| Risk | Mitigation |
|---|---|
| **Step 2 introduces a second distribution per platform**, with its own cost and its own domain, for deployments that already have one. | It is created only when stores are declared *and* no host-UI bundle is passed — the case that today produces an unusable store. Deployments with a shell keep exactly one distribution. |
| **Two stacks write a `BucketPolicy` for the same bucket** and silently overwrite each other, breaking reads with no error. | The whole reason ownership stays with the bucket's stack in option 3. If option 2 is chosen instead, this must become an explicit documented constraint, because the symptom is a broken image and nothing logs it. |
| Exporting `objectStores` invites consumers to reconstruct S3 URLs from `bucketName` directly, bypassing the CDN and hitting a bucket that blocks public policy. | Export `baseUrl` in step 2 and prefer it in docs; `bucketName`/`keyPrefix` exist for IAM and lifecycle reasoning, not for addressing. |
| A platform that declares stores today and is redeployed after step 1 shows an output-only diff that looks like drift. | Expected and harmless — call it out in the step's verification so it is not mistaken for a resource change. |
| **Core's own unit tests do not run in its default suite.** | Run `jest --selectProjects reventless-core` when judging this change; a green default suite is not evidence. |

## What landed

Steps 1–3 as written, with one addition the plan did not call for.

**The serving choice became a function.** The plan described the mutual exclusion in prose and would
have left it as a two-armed condition inside `deployPlatform`, where nothing can test it. It is now
`Util_StoreLayout.servingFor(~hasHostUiBundle, ~declaredBucketCount) : NoStores | HostShell |
PlatformOwned`, next to `layoutFor` and `protectionFor` — the module already exists to make exactly
these decisions pure and testable. Making the return a three-way variant is what stops "both" from
being expressible; the five new tests assert each arm, including the two orderings that could
plausibly have gone the other way (a shell wins over several buckets; declaring nothing outranks
having a shell).

That mirrors the reasoning already recorded on the `servedBucket` type, which groups prefixes per
bucket so that two policies for one bucket cannot be written *within* one distribution. This is the
same argument one level up: across distributions.

**Shapes, as built:**

```
uploadEndpoints : { "{plugin}.{store}": "https://…" }
objectStores    : { "{plugin}.{store}": { bucketName, keyPrefix, baseUrl? } }
```

`baseUrl` is present only under `PlatformOwned`. Under `HostShell` the object is addressable
same-origin, and a base URL would be a second and wrong way to reach it.

**`makeServedBucketDistribution` throws on an empty bucket list** rather than building a
distribution with no origins. CloudFront requires a default cache behaviour and there is no neutral
origin to point it at with no bundle behind it; the first served bucket takes it, and every real
path is matched by its own `{prefix}/*` behaviour first, so the default is reached only by a request
no store claims — which 404s at S3, the correct answer. `servingFor` already prevents the empty
call, so the throw is a guard on a second caller, not a reachable path today.

## Follow-on: the §6 coverage assertion (2026-07-29)

Not in this plan's steps, added because executing it produced the failure it prevents. The analysis's
§6 recommended "B as the mechanism, C as the safety net" — `deployPlugin` failing when the platform's
exported capability set does not cover what the plugin requires. That safety net was unbuildable
until step 1, because there was no exported capability set to compare against. There is now.

`deployPlugin` reads the platform's `objectStores` output through the existing `platformStackRef` and
compares its keys against `pluginStructure.requiredStores`. The decision is
`Util_StoreLayout.coverageFor`, pure and tested, returning **three** outcomes rather than two:

| Outcome | When | Response |
|---|---|---|
| `Covered` | every declared store is provisioned | nothing |
| `NotAdopted(missing)` | the platform provisions **no** stores | warn |
| `Missing({missing, provisioned})` | it provisions some, but not these | **fail the deploy** |

The third arm is the one that matters and the split is the reason it is safe to ship. A platform
provisioning nothing has not adopted capability provisioning; failing it would break deployments that
work today. A platform provisioning *some* stores but not this one has adopted it and has a missing
or misspelled entry — which is exactly the case-slip that shipped in the example, where both sides
had a `productImages` store and neither matched.

Matching is **exact**. Case-insensitive or suffix matching would "fix" that slip by silently binding
to the wrong store, and two plugins may legitimately name a store the same — the same reasoning the
UI plan used when it rejected suffix-matching.

The check is folded into the `sourceApiAssociationId` export rather than left as a free-standing
`apply`, for the reason the merge gate already is: a dangling `apply` is not guaranteed to be
evaluated, and a check that might not run is not a check.

## Live state (2026-07-29, alpha)

Deployed at 07:16 UTC, which included step 1–3's commit. `pulumi stack output` on
`online-shop-hybrid-platform-aws/alpha`:

```
uploadEndpoints : { "catalog.productImages": "https://qctf…lambda-url.eu-west-1.on.aws/" }
objectStores    : { "catalog.productImages": { bucketName: "alpha-stores",
                                               keyPrefix: "productImages" } }
```

**`bucketName` was the logical name, not the physical one — fixed 2026-07-29.** The live value above
reads `alpha-stores`; the bucket in S3 is `alpha-stores-507202d`. Pulumi auto-names the resource, and
[Platform.res:1589](../../reventless/aws/src/Platform.res#L1589) put `Util_StoreLayout.bucketNameFor`'s
string into the exported record instead of `storeHandle.bucketName`, the `Output` carrying the
resolved name. Uploads were unaffected — the presign service was already wired from the physical
handle — so this was visible only in the export, which is precisely where the Risks table says the
field exists "for IAM and lifecycle reasoning". An IAM policy written against
`arn:aws:s3:::alpha-stores` grants nothing.

`objectStoreEndpoint.bucketName` is now `Pulumi.Output.t<string>`; the tuple carries the logical name
(which still groups the served view, where it is correct) *and* the physical one. The two are
different strings and only one of them exists in S3 — the type now says so. Found while checking
whether a second platform on `alpha` would collide on a bucket name; it would not, and that is the
same auto-naming suffix that made the export wrong.

That verifies step 1 end-to-end: both keys are exported, under the `{plugin}.{store}` grammar, and
`objectStores` carries **no `baseUrl`** — which is the `HostShell` arm of `servingFor` behaving as
designed, since alpha passes `~hostUiBundle`. So the arm that was already the working path is
confirmed live; the arm this plan added is not.

**Two facts about that output are not yet reconciled with the repo:**

- The key is `catalog.productImages`, lowercase — the state `b16dcc1c6` fixed. That commit is pushed
  and published, but **deploy is `workflow_dispatch`**, so it has not been applied. Alpha still runs
  the pre-fix capability list.
- The §6 coverage assertion (`8f2b6e6ca`) is unpushed. Once it ships, a plugin deploy against the
  *current* alpha compares required `Catalog.productImages` against provisioned
  `catalog.productImages` and returns `Missing` — a hard deploy failure. That is the check doing
  exactly its job, but it makes an ordering constraint: **redeploy the platform before any plugin
  stack deploys with the check in it.**

## The shell-less example (2026-07-29)

`online-shop-aggregates` is now the repo's `PlatformOwned` case. Three things changed together,
because any one alone is incoherent:

- **`Product` declares an image.** `@storageRef("productImages")` on the `Add` and `UpdateImage`
  command inputs and on the `Products` read model's `imageUrl`. Events carry the ref as a plain
  string — the annotation describes an input, which is the convention hybrid already follows.
- **The platform declares the store** and drops `~hostUiBundle`.
- Downstream constructions of `Product.Add`/`Added` were updated (import task, EP mapping GWT, the
  cross-plugin flow GWT), and `UpdateImage` got the same three arms the other update commands have,
  including the idempotent no-event case.

Choosing this example over `online-shop-dcb` buys a second thing: `requiredStores` derives from
aggregate command/event schemas and read model state as well as from slices, and until now only the
slice path had an example. This covers the aggregate path.

Build green, zero warnings; full suite 2295/2295 (276 suites), `reventless-core` + `reventless-aws`
956/956.

## Step 2 verified on AWS (2026-07-29)

Deployed `online-shop-aggregates-platform-aws/pr-verify` — a platform with a declared store and no
`~hostUiBundle`. The `PlatformOwned` arm executed for the first time. Stack outputs:

```
uploadEndpoints : { "Catalog.productImages": "https://m7wtpw…lambda-url.eu-west-1.on.aws/" }
objectStores    : { "Catalog.productImages": { bucketName: "pr-verify-stores-3da07dd",
                                               keyPrefix: "productImages",
                                               baseUrl:   "https://d15sqe85qvbyp4.cloudfront.net" } }
hostShellUrl    : absent
```

Three things that could only be seen from a real deploy:

- **`baseUrl` present, `hostShellUrl` absent** — `servingFor` selected `PlatformOwned`, and the
  platform stack built its own distribution rather than borrowing a shell's.
- **`bucketName` is `pr-verify-stores-3da07dd`** — the physical auto-named bucket, confirming the
  export fix. The logical name would have been `pr-verify-stores`.
- **The round trip closes.** POST to the presign URL returned
  `storageRef: /productImages/02dd8c31-…/verify.txt`; a PUT to the presigned URL returned 200; a GET
  of `{baseUrl}{storageRef}` returned 200 `text/plain` with byte-identical content.

The last one is the whole point of deploying: the bucket blocks public policy and takes its read
grant solely from the `BucketPolicy` that distribution writes, and no preview can show that a policy
grants what it claims. It does.

## Still to do

  **An example now reaches the arm; nothing deploys it yet.** Until 2026-07-29 all three example
  platforms passed `~hostUiBundle` (hybrid with a payload, the other two with `{}`) and only hybrid
  declared a store, so every configuration in the repo resolved to `HostShell` and `PlatformOwned`
  had never been compiled into a deployable stack, let alone applied.

  `online-shop-aggregates` is now that stack: it omits `~hostUiBundle` entirely and declares
  `Catalog.productImages`. Confirmed from the emitted entry point rather than the source —
  `Main.res.mjs` reads `deployPlatform(version, undefined, capabilities)`, so `servingFor` gets
  `hasHostUiBundle: false` with one declared bucket and returns `PlatformOwned`. That is the same
  read-the-generated-JS check used above for the host-UI path.

  What remains is genuinely a deploy: no `online-shop-aggregates` stack has ever existed
  (`pulumi stack ls` is empty), so the PUT/GET round trip needs a first-ever `pulumi up` standing up
  a full platform (~180 resources, on the order of hybrid's) rather than diffing an existing one.

  **The stack name is the decision, not the timing.** `Util_StoreLayout.protectionFor` treats only
  the `pr-` prefix as ephemeral; every other name, `alpha` included, gets `Protected` store buckets
  that block `pulumi destroy` by design. Verifying on `alpha` would therefore leave a second
  permanent platform in the account whose store bucket cannot be torn down without manually
  flipping protection. So the verification runs on a `pr-verify` stack:

  1. `.github/workflows/deploy-online-shop-aggregates.yml` — manual dispatch, added 2026-07-29.
     The Pulumi stack name is the branch name, so `--ref pr-verify` deploys the `pr-verify` stacks.
  2. `Pulumi.pr-verify.yaml` for all three stacks (platform, catalog, ordering), with
     `platform:stack` and the ordering→catalog `interstack` dependency repointed. Without these the
     plugin stacks cannot resolve the platform's outputs.
  3. Deploy, PUT through the presign URL, GET through the exported `baseUrl`, then `pulumi destroy`.

  The layer-ARN lookup falls through to `alpha`'s SSM parameter for any unrecognised branch, which
  is what this wants — the verification is of the serving path, not of a fresh layer build.

  **Why not wait for Stage 3.** Stage 3 changes who *writes* the capability list, not what the
  serving path does. It would generate the same list this example now holds by hand, for a
  `PlatformOwned` arm that has still never executed — so the dependency runs the other way round:
  verifying the arm is what makes Stage 3's generated output trustworthy.
- **The aggregates plugin stacks never compiled.** Both plugin jobs of that first deploy failed:
  `project 'main' could not be read: … ordering-aws/src/Main.res.mjs: no such file or directory`.
  Pre-existing and unrelated to this plan — hybrid's `catalog-aws`/`ordering-aws` track a generated
  `Plugin.res` composition root plus both `.res.mjs` outputs, and the aggregates equivalents were
  never generated or committed. Nothing caught it because nothing had ever deployed that example,
  and the root `build` chain does not cover `*-aws` plugin roots (only `platform-aws` and
  `platform-local`), so the outputs exist only if tracked. Generated via each package's own
  `prebuild` → `generate-plugin` and committed. `online-shop-dcb` has the same gap, still open.

  Consequence for this plan: the `deployPlugin` coverage assertion has still never run on AWS. The
  platform half is verified; the check that reads its output is not.

- ~~**Confirm the host-UI path is untouched.**~~ **Done 2026-07-29, from the emitted JS rather than
  from the source.** In `Platform.res.mjs` the whole `hostUiBundle` branch differs only in ReScript's
  temporary numbering (`match$1`→`match$2`), shifted because the new serving decision introduces a
  binding earlier in the function. The `makeUiBundleDistribution` call is byte-identical, arguments
  and `~servedBuckets` included. So a host-UI platform's only resource-level change is Lambda source
  hashes, which any framework change produces. This is the cheap check that generalises: read the
  generated JS for the path you did *not* mean to touch.
- ~~Note that a push to `alpha` publishes *and* deploys, with no review step between preview and
  apply.~~ **Half true, and the wrong half was the worry.** A push to `alpha` publishes
  automatically (`release.yml`), but `deploy-online-shop-hybrid.yml` is `on: workflow_dispatch` only
  — both of today's deploys were manual. So there *is* a human step before apply. The real hazard is
  the opposite one: publish and deploy drift apart silently, which is why alpha is currently running
  a capability list two commits behind the repo.
