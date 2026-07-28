# Plan: platform capability provisioning — Stage 2 (declaration-driven object stores)

**Date:** 2026-07-28
**Status:** Steps 1–6 executed 2026-07-28. Build green, `reventless-core` 553/553 and the default
suite 1535/1535. **Preview-verified on stack `alpha`, not applied** — the existing store is `(same)`
with 0 replacements and 0 deletions across the whole preview. Teardown and the live legacy-ref fetch
remain open. See [What landed, and what the plan got wrong](#what-landed-and-what-the-plan-got-wrong)
and [Status of each](#status-of-each--2026-07-28).
**Repos:** `reventless-core` only.
**Analysis:** [platform-main-capability-provisioning.md](../analysis/platform-main-capability-provisioning.md) §5.3, §7 Stage 2, §8.
**Builds on:** [platform-capability-provisioning-stage-0.md](./platform-capability-provisioning-stage-0.md)
(framework-provisioned stores) and [done/semantic-type-marker-and-storage-ref.md](./done/semantic-type-marker-and-storage-ref.md)
(the declaration).

## What this closes

Stages 0 and 1 left a deliberate gap, and it is worth naming precisely because it is the whole
reason this stage exists:

```rescript
// catalog — ChangeProductImage.res:13, declares a requirement
ChangeProductImage({productId: string, @storageRef("productImages") imageUrl: string})

// platform-aws — Main.res:19, provisions a bucket
let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.make(~name="online-shop-uploads")
```

Two unrelated strings. Nothing outside tests reads `StorageRef.getStore`, so deleting the annotation
would still leave the bucket, and adding `@storageRef("invoices")` would provision nothing. The
declaration is *stated* but *unhonored*.

Stage 2 makes the declaration the authority: the store a field declares is the store that gets
provisioned, owned by the plugin that declares it, and named after it.

## Gate 1 — the bucket-count ceiling (§5.3)

**Measured 2026-07-28:** 9 buckets in the OSS demo account. AWS's default limit is 100 buckets per
account, adjustable to 1,000 via a quota increase. Note the general bucket-count quota is not
exposed through `service-quotas list-service-quotas --service-code s3` (that returns only
replication/object quotas), so the limit has to be confirmed from the account's Service Quotas
console rather than scripted.

The growth term is `plugins × stores × stacks`, and **stacks is the dangerous factor**: the stack
allowlist already admits `pr-*`, so a per-PR environment multiplies every plugin's every store.
Two plugins with one store each across a handful of long-lived stacks is ~10 buckets; the same
against 20 open PRs is ~40, on top of the framework's own per-stack buckets (host-ui bundle, task
buckets, plugin bundles).

**Decide before writing code**, because it changes the ref grammar:

- **Per-store bucket** — clean IAM boundary, per-store lifecycle, simple deletion. Costs a bucket per
  store per stack against a global namespace.
- **Prefix within one bucket per stack** — one bucket, `{store}/…` prefixes. Bounded count, but
  per-store least-privilege becomes an IAM policy over prefixes rather than over buckets, and a
  store's deletion becomes a prefix sweep rather than a bucket delete.

`StorageRef`'s grammar was deliberately left structural — absolute path, ≥2 non-empty segments, no
traversal — rather than pinning a per-store prefix, precisely so it admits either outcome without a
stored-value migration. Whichever is chosen, the grammar tightens from structural to per-store, and
that tightening is the only ref-format change this stage may make.

**Decision: per-store buckets on production stacks only; every other stack — `alpha`, `beta`,
`pr-*` — shares one bucket with `{store}/…` prefixes.**

Production is the only environment where a bucket boundary is worth its cost, and it is also the
only one that does not multiply: one prod stack, versus an unbounded number of PR stacks plus the
long-lived non-prod ones. That keeps the ceiling flat in the term that actually grows.

Three things have to hold for this to be one model rather than a fork.

### What makes the dual scheme safe: refs must not encode the layout

**Root the object key at the store name in *both* schemes.** The presign service mints
`{store}/{identity}{uuid}/{file}` either way, so the stored ref is `/{store}/{uuid}/{file}`
regardless of which bucket sits behind it. Only the CloudFront origin differs:

```
per-store:  /{store}/*  →  bucket {plugin}-{store}
shared:     /{store}/*  →  bucket {stack}-stores
```

This is not a detail. Refs live in an append-only event log, so a ref that encoded its bucket layout
would make stored values environment-specific and unrewritable — a prod dump restored into a PR
stack would carry refs that cannot resolve. Rooting at the store name costs a slightly redundant
prefix inside a dedicated bucket (`catalog-productImages/productImages/…`) and buys refs that are
identical across every environment. Take the redundancy.

### Naming production explicitly, because this polarity fails open

`ReventlessSeedAws_Reset` warns about exactly this shape at
[:112](../../reventless/seed-aws/src/ReventlessSeedAws_Reset.res#L112): *"Fail-closed name
allowlist. A denylist ('everything except prod') fails open"*. Keying isolation off "is this prod"
inherits that: a **new** production stack whose name is not on the list — `production`, `live`,
`prod-eu` — silently gets the weaker layout, and nothing fails.

That is a real cost of this decision and it is accepted, so it has to be paid down deliberately
rather than left implicit:

- **An explicit, config-overridable list**, defaulting to `["prod", "main"]` — the same default and
  the same CSV-override shape `Util_HostUiDomain` already uses for `hostUiProdStacks`. A team on
  `production` sets one key.
- **Converge the two lists.** `hostUiProdStacks` already encodes "which stacks are production" for
  domain naming. A second, independent list answering the same question is the "two flags that can
  disagree" problem: the fix is one shared notion of a production stack, read by both. Do not add a
  parallel key.
- **Log the chosen layout at deploy time**, per stack, at info level. A silent fail-open is only
  dangerous while it is silent; a line in every deploy makes "prod got shared buckets" visible the
  first time it happens rather than at an audit.

### Protection does *not* follow the layout

Tempting to make one switch decide layout, `protect` and `forceDestroy` together. That is wrong
here, and `alpha` is the counter-example: it declares `reventless:wipeable: "true"`
(`examples/online-shop-hybrid/platform-aws/Pulumi.alpha.yaml`) yet holds hand-entered data.

Those are different claims. `wipeable` authorises the reset tool to empty stores **deliberately**,
after a scope prompt and a typed confirmation. It does not say a field rename may destroy a bucket
by accident. Conflating them would put `forceDestroy: true` and no protection on a stack whose data
people actually care about.

So two independent predicates:

| | layout | `protect` | `forceDestroy` |
|---|---|---|---|
| `prod` | bucket per store | on | off |
| `alpha`, `beta` | shared bucket, `{store}/…` | **on** | off |
| `pr-*` | shared bucket, `{store}/…` | off | on |

Teardown still works where it must: only `pr-*` is destroyed routinely, and only `pr-*` gets
`forceDestroy`. A protected bucket blocks `pulumi destroy`, so protecting PR stacks would leak
exactly the buckets sharing exists to save.

The shared layout also *lowers* the silent-deprovisioning risk (§8) on the stacks that use it:
dropping a store's declaration stops provisioning a prefix, it does not delete a bucket. Per-store —
and therefore the sharp form of that risk — now exists only on prod, which is precisely where
`protect` is on.

The honest cost of sharing is IAM: isolation degrades from a bucket boundary to a prefix boundary,
so a policy-construction bug could cross stores. That is acceptable on non-production stacks and is
the reason prod keeps real buckets.

### Implementation shape

Two pure functions, `Util_HostUiDomain`-style — decidable and unit-testable without touching Pulumi:

```rescript
type storeLayout = PerStore | SharedBucket

/** Production gets a bucket per store; every other stack shares one.
    `prodStacks` defaults to ["prod", "main"] and is config-overridable. */
let layoutFor = (~stack, ~prodStacks) =>
  prodStacks->Array.includes(stack) ? PerStore : SharedBucket

/** Destroy semantics follow disposability, NOT layout: `alpha` shares a bucket
    but still holds data worth protecting. */
let protectionFor = (~stack, ~ephemeralStacks) =>
  ephemeralStacks->Array.includes(stack) ? Unprotected : Protected
```

Everything downstream — bucket creation, `protect`, `forceDestroy`, the presign policy resource —
switches on these variants, so there are two decision points, both named, and the compiler finds
every consumer of each.

`ReventlessInfra.Platform.objectStore` gains `keyPrefix: string` (the store name). Both the presign
service and the served-bucket derivation read it, so the prefix is written once and consumed by both
sides — the same property Stage 0 established for `defaultServedPrefix`, extended per store.

### Legacy refs must keep resolving

Today's refs are `/uploads/…` and the declared store is `productImages`; the 128 existing objects sit
under `uploads/` in `online-shop-uploads`. Moving to `/{store}/…` therefore **breaks every ref
already in the event log**, and an append-only log cannot be rewritten.

Keep serving `/uploads/*` from the existing bucket permanently, alongside the new `/{store}/*`
behaviours. Old refs resolve, new refs use the store name, and no event is touched. Treat the legacy
prefix as a store named `uploads` that happens to predate the declaration, not as debt to be
migrated away.

## Gate 2 — the replacement post-mortem — CLOSED

Recorded here because this stage is where the risk becomes live, and the evidence should not have to
be rediscovered.

The concern: Stage 0 changed how the uploads bucket is constructed (raw Pulumi in `Main.res` → a
framework helper), and a changed logical name would destroy a bucket holding live objects. On the
2026-07-28 deploy of the example stack, `ListBuckets` reported the bucket's `CreationDate` as the
deploy time, which reads as a replacement.

It was not one:

- Deploy log: `~ aws:s3:Bucket online-shop-uploads updating (0s) [diff: ~tags,tagsAll]` — an
  in-place update, tags only, no replace step.
- The bucket holds 128 objects whose oldest `LastModified` is the previous day. Objects cannot
  predate their bucket.

**`ListBuckets`' `CreationDate` is not a reliable "created at"** and must not be used as
replacement evidence. The two signals that are reliable: the Pulumi step verb in the deploy log, and
object `LastModified` timestamps.

This matters for Stage 2 rather than being historical: once a bucket's lifecycle follows a
*declaration*, the replace/destroy path stops being reachable only by editing a line of Pulumi and
becomes reachable by renaming a field. See step 5.

## Naming

A store's bucket must be traceable back to the declaration that required it. Today's
`online-shop-uploads` is not — it names a deployment, not a store, and there is no path from a
`@storageRef("productImages")` field to that string.

**Physical name: `{plugin}-{store}`** (`catalog-productImages`), with Pulumi's suffix for global
uniqueness. The logical name is the same, so the URN is derived from the declaration and a store
rename is a visible replace in review rather than a silent one.

Not to be confused with the framework's other buckets, which keep their existing conventions and are
out of scope here:

- **Task buckets** — `TaskBucket_S3`, named from component + role
  (`importproductsproductimportsbucket`, the `ImportProduct` inbound-translation slice's drop
  bucket). A task bucket is an *ingress* for a slice, not a declared store, and no `@storageRef`
  field points at it.
- **Plugin bundle** and **host-ui bundle** buckets — hosting substrate, not domain storage.

The distinction is worth stating in the module doc: a store is declared by a field's type and holds
values that events reference; a task bucket is wired by a slice and holds transient input.

## Steps

### 1. Collect declared capabilities into `Plugin_Structure`

`Plugin_Structure` already walks component schemas and reads type-carried facts — it calls
`Reference.getTarget` at [:161](../../reventless/core/src/plugin/component/Plugin_Structure.res#L161)
and [:253](../../reventless/core/src/plugin/component/Plugin_Structure.res#L253). Add the same
treatment for `StorageRef.getStore`, collecting a deduplicated set of required stores per plugin.

Walk **commands, events and state** — a store referenced only by a read model still has to exist.
Dedup by `(plugin, store)`: many fields legitimately name one store.

### 2. A `capability` type in `reventless/infra`

```rescript
type capability =
  | ObjectStore({plugin: string, store: string})
  | Geocoding
```

A real variant, in `infra` so both the platform and the plugin stacks reference one nominal type.
Stage 4 grows it; nothing here should make that growth require touching every consumer.

### 3. Provision stores in the plugin stack that owns them

Object stores move out of the platform root into `Plugin_Stack`, beside the plugin's other owned
substrate. `Capability_ObjectStore_S3.make` already applies the house conventions and needs only
the naming change from step 0 plus `~plugin` for attribution — the tags become
`scope=Plugin`, `plugin={plugin}` rather than `scope=Platform`.

The platform keeps only what it needs to *serve*: `deployPlatform` learns the served-store list, not
the buckets themselves.

### 4. Per-store presign, least-privilege

Today one `Upload_Presign_S3` service holds `s3:PutObject` on the single upload bucket
([Platform.res](../../reventless/aws/src/Platform.res), presign provisioning) and mints keys under
one `defaultServedPrefix`. That becomes **one presign service per store** in both layouts — scoped to
the store's own bucket on prod, and to `{bucket}/{store}/*` on a shared stack.

One service per store either way, so the number of services is a function of declarations rather than
of layout. Only the policy's resource ARN differs, which is what keeps the two layouts one model.

This is the step that makes the UI able to bind an upload input to a *declared* store rather than to
a name heuristic — the reventless-ui side is currently blocked on exactly these endpoints not
existing. It is also where `StorageRef`'s grammar tightens: the ref a store's service mints becomes
checkable against that store, closing the last gap left open in Stage 1.

**Do not** collapse this into one service with wildcard write across stores; that reintroduces the
blast radius the per-store split exists to remove.

### 5. `protect` / `retainOnDelete` — before, not after

Provisioned stores carry `protect: true` per
[protecting-prod-infrastructure-resources.md](../analysis/protecting-prod-infrastructure-resources.md)
on every stack except `pr-*`, which carries `forceDestroy: true` instead so teardown works. Per
Gate 1 this follows **disposability, not layout**: `alpha` shares a bucket and is still protected.

This is the step that must not be deferred. Stage 0's bucket could only be destroyed by editing
Pulumi; a per-store bucket can be destroyed by **renaming a field**, because the last
`@storageRef("productImages")` disappearing removes the requirement. Gate 2 showed the current path
is safe today — that safety does not survive this stage without `protect`. Note the sharp form of
this now exists only on prod, since that is the only stack with per-store buckets.

Land step 5 in the same commit as step 3. A bucket that exists for one deploy without protection is
a bucket that can be lost in that window.

### 6. The platform API

```rescript
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~capabilities=[ObjectStore({plugin: "catalog", store: "productImages"}), Geocoding],
  ~hostUi=Default,
)
```

`~capabilities` is still hand-written here — deriving it is Stage 3. The value of writing it by hand
first is that the list is reviewable and the generator has an existing shape to emit.

## What landed, and what the plan got wrong

Executed 2026-07-28. Four corrections, one of which changes the plan's shape rather than its
detail.

### Step 3 was unbuildable as written: the platform provisions, the tags attribute

The plan said object stores "move out of the platform root into `Plugin_Stack`, beside the plugin's
other owned substrate". A plugin's *stack* cannot own them. Three independent reasons, any one of
which is decisive:

- **Deploy order.** Plugin stacks reference the platform stack's outputs, so the platform deploys
  first. A store owned by a plugin stack cannot be fronted by the platform's CloudFront
  distribution without inverting that order or requiring a second platform deploy.
- **The shared layout has no single owner.** Gate 1 puts every non-prod stack's stores in one
  bucket. No plugin stack can own a bucket several plugins' stores live in.
- **Step 6 already said so.** `~capabilities` is a parameter of `deployPlatform`. The platform is
  handed the list; steps 3 and 6 disagreed with each other, and step 6 was right.

So the bucket is created by the platform deploy, and **ownership is expressed in the tags**: a
per-store bucket carries `scope=Plugin, plugin={plugin}`, a shared bucket carries `scope=Platform`
because that is what it is. `Capability_ObjectStore_S3.make` takes `~plugin` and switches its
attribution on it; the legacy hand-written store passes none and its tags are unchanged.

### A served bucket is one bucket with several prefixes, not one prefix

`ReventlessInfra.Platform.servedBucket` carried a single `prefix`, and `Plugin_Stack` created one
CloudFront origin *and one `BucketPolicy`* per entry. Under the shared layout that is a live defect:
S3 permits exactly **one** bucket policy per bucket, so the second store's CloudFront read grant
would silently replace the first store's. It deploys green and 404s half the objects.

`servedBucket` is now `{id, prefixes, …}` — one entry per bucket, carrying every prefix served from
it. One origin, one policy, N cache behaviours. The failure is unrepresentable rather than a rule to
remember.

### The two layouts do not fork in the IAM policy either

The plan expected the presign policy's resource ARN to differ between layouts (the store's whole
bucket on prod, `{bucket}/{store}/*` on a shared stack). Because keys are rooted at the store name
in *both* layouts, `{bucket}/{servedPrefix}/*` is least-privilege in both — a dedicated bucket's
service still cannot write outside its own prefix. One expression, no branch. That is a stronger
form of "the two layouts are one model" than the plan claimed.

`Upload_Presign_S3.make` gained `~name` (defaulting to the previous single-service name, so the
existing service keeps its identity) and its policy tightened from `{bucket}/*` to
`{bucket}/{prefix}/*` — which also narrows the legacy service, correctly.

### `@storageRef`'s attribute position fails silently

`@storageRef("documents") documentUrl: string` marks the field. `documentUrl: @storageRef("documents")
string` attaches the attribute to the *type expression* instead, where the ppx never looks — it
compiles, deploys green, and provisions nothing. Cost an hour of debugging a "collection returns
nothing" that was a mis-typed fixture, not a walk bug. The fixture carries a note at the point of
declaration.

### Also worth recording

- **The prod list is shared, not duplicated.** `Util_HostUiDomain.resolveProdStacks` is the one
  reader of `hostUiProdStacks`; both domain naming and store layout call it. No second key.
- **Legacy refs keep resolving by construction.** The hand-written store is served alongside the
  declared ones rather than replaced — `uploads` is a store that predates the declaration.
  `config.json` keeps `uploadEndpoint` (the legacy service) and gains `uploadEndpoints`, a
  `{qualified-store → url}` map. With nothing declared, `config.json` is byte-identical.
- **`~hostUi=Default`** from step 6's sketch was not adopted; `~hostUiBundle` is unchanged. Renaming
  it is not this stage's business.
- **`pluginStructure.requiredStores`** carries the collected declarations, fully qualified to
  `{plugin}.{store}` and deduplicated, so Stage 3's generator reads a list rather than re-walking
  every component.
- **An app-called `Capability_ObjectStore_S3.make` defaults to `protect: true`** and knows nothing
  about the stack. On a disposable stack a hand-written store would therefore block teardown. Only
  the declared path decides protection from the stack; the hand-written one cannot, which is one
  more reason to declare stores rather than write them.

## Verification

- **The declaration drives it.** Adding `@storageRef("invoices")` to a catalog command and running
  `pulumi preview` shows a new `catalog-invoices` bucket. Removing it shows the bucket *protected*,
  not destroyed. This pair is the plan's reason to exist; nothing before step 5 demonstrates the
  second half.
- **No replacement of the existing store.** `pulumi preview` on the example stack: the bucket that
  exists today must not be replaced by the move into the plugin stack. Ownership moving between
  stacks changes the URN, so this needs an explicit alias or an import — **verify before applying**,
  and use the two reliable signals from Gate 2 (the step verb, and object timestamps afterwards),
  not `CreationDate`.
- **Both layouts, and the teardown.** A non-prod stack gets one shared bucket with `{store}/…`
  prefixes; a prod-named stack gets a bucket per store. Then `pulumi destroy` a `pr-*` stack and
  confirm no bucket is left behind — the leak is invisible to a deploy-only test and is the failure
  the `pr-*` row exists to prevent.
- **`alpha` is protected.** Assert `protect` is set on a stack that shares a bucket — the pairing
  that a single layout-driven switch would have got wrong.
- **Refs are layout-independent.** The same `@storageRef` field produces a byte-identical ref string
  on a per-store stack and a shared stack. Assert on the presigned key, not by eye.
- **Legacy refs still resolve.** An existing `/uploads/…` ref fetches successfully after the stage
  lands.
- Per-store presign writes only to its own bucket (or, on a shared stack, only under its own
  prefix) — assert the IAM policy resource, not just that upload works.
- Tag coverage: every provisioned store discoverable by the `reventless:platform` +
  `reventless:environment` filter pair, as Stage 0 established.
- Full root build green, suite green, no `.res.mjs` churn beyond intended files.

### Status of each — 2026-07-28

Everything provable without infrastructure is done; everything that needs a deploy is not. The
split is worth being blunt about, because the items still open are the ones carrying the
destructive risk.

| Item | State |
|---|---|
| Both layouts, and the per-store/shared naming | ✅ `Util_StoreLayoutTest`, 14 assertions, including the `alpha` shares-a-bucket-and-is-still-protected pairing and the accepted fail-open on an unlisted production name |
| Refs are layout-independent | ✅ asserted on `keyPrefixFor`, which is the single place the ref's prefix is decided |
| The declaration drives it | ✅ preview: the one declared store produces `alpha-stores` + PAB + a `productImages/*` CDN behaviour + `UploadPresign-catalog-productImages` (role, policy, function, URL). Removal-stays-protected is implied by the lock but not separately exercised |
| **No replacement of the existing store** | ✅ **`aws:s3/bucket:Bucket::online-shop-uploads (same) 🔒`** — no property diff, no replace, and **0 replacements and 0 resource deletions in the whole preview**. Judged by the step verb, per Gate 2 |
| Per-store presign writes only its own prefix | ✅ preview: the new policy's resource is `arn:aws:s3:::alpha-stores-…/productImages/*`, and the legacy service *narrows* from `…/*` to `…/uploads/*` |
| Teardown of a disposable stack leaves no bucket | ❌ open — needs an actual `destroy`, and is invisible to a deploy-only test |
| Legacy `/uploads/…` refs still resolve | ⚠️ the `uploads/*` cache behaviour is unchanged in the preview and the bucket is untouched; not yet fetched over HTTP |
| Tag coverage via the platform+environment filter pair | ⚠️ the created bucket carries `scope=platform`, `plugin=""` (shared bucket ⇒ platform substrate, by design); the ambient platform/environment tags are applied by the same helper as today but unverified on the live resource |
| Build + suite | ✅ green; `reventless-core` 553/553, default suite 1535/1535, no `.res.mjs` deletions |

**Preview of record — 2026-07-28, stack `alpha`, not applied.** `0 replacements, 0 deletions`;
`+17 create / ~23 update / -10 delete / 138 unchanged`. Ten of the creates and all ten deletes are
`host-ui-asset-*` `BucketObject`s — the local `reventless-host-shell` dist differs from the one CI
installed, so they are environment noise and would not appear in a CI preview. The seven real
creates are the store bucket, its public-access block, the served bucket policy, and the presign
role/policy/function/URL. CloudFront's `orderedCacheBehaviors` shows a **positional shift**, not a
rewire: the new `productImages/*` behaviour inserts at index 1 and pushes `/remoteEntry.js`,
`/index.html`, `/config.json` down one, each keeping its own cache policy.

Reproducing this locally needs the deploy workflow's environment, or the preview reports false
diffs that swamp the real ones — an unset `REVENTLESS_COGNITO_USER_POOL_ID` auto-provisions a fresh
UserPool, and unset host-UI domain variables tear down the ACM cert and Route53 alias:

```sh
AWS_REGION=eu-west-1 \
REVENTLESS_HOST_UI_BASE_DOMAIN=… REVENTLESS_HOST_UI_HOSTED_ZONE_ID=… \
REVENTLESS_COGNITO_USER_POOL_ID=$(pulumi stack output cognitoUserPoolId) \
REVENTLESS_LAYER_ARN=$(aws ssm get-parameter --name /reventless/layer-arn/alpha \
  --query Parameter.Value --output text) \
pulumi preview --stack alpha --diff
```

The stack lives in **Pulumi Cloud**, not the S3 state backend — `pulumi stack ls` against the S3
backend reports it missing, which reads as "never deployed" rather than "wrong backend".

One infrastructure note found while verifying: the `reventless-core` jest project contributes **no
tests to the default `pnpm test` run** — its `tests/**/*.res.mjs` only exist after the package is
built directly, and the run reports 210 suites either way. That is the dark coverage diagnosed in
`ci-unit-test-coverage-gap.md` and tracked by `untrack-test-mjs-via-root-build-emission.md`; it is
pre-existing and unchanged here. It does mean **core's suite has to be run explicitly**
(`jest --selectProjects reventless-core`) to see these assertions at all.

## Risks

| Risk | Mitigation |
|---|---|
| **Moving the store between stacks replaces it.** The URN changes when ownership moves from the platform root to a plugin stack — the same class of failure Gate 2 investigated, but this time genuinely reachable. | Explicit alias or `pulumi import`. Verify with a preview showing update/import, never replace, before applying to any stack with objects. This is the one step that must not be reviewed casually. |
| **Silent deprovisioning by field rename** (§8). | Step 5's `protect: true`, landed in the same commit as provisioning. Capability removal also becomes a reviewable diff once Stage 3 generates the list. |
| **Bucket ceiling turns out to bind.** | Gate 1 decided before code: only prod gets a bucket per store, and prod does not multiply. Every stack that does multiply shares one. The ref grammar admits both layouts without a stored-value migration. |
| **A new production stack silently gets shared buckets** because its name is not on the prod list — this polarity fails open, by the reset tool's own argument at `:112`. | Accepted, and paid down explicitly: a config-overridable prod list converged with `hostUiProdStacks` (one notion of "production", not two that can disagree), plus a deploy-time log line naming the chosen layout so it is visible on the first deploy rather than at an audit. |
| **Protection wired to layout**, giving `alpha` `forceDestroy` because it shares a bucket — while it holds hand-entered data. | Two independent predicates. `wipeable` authorises a *deliberate* reset, not accidental destruction; only `pr-*` is unprotected. |
| **A PR stack fails teardown** because its buckets are protected, leaking the buckets sharing exists to save. | `pr-*` gets `forceDestroy` and no protection. Covered by a destroy test, not only a deploy test. |
| Per-store presign multiplies Lambdas and Function URLs per stack. | Count them in Gate 1's arithmetic alongside buckets — the ceiling question is not only about S3. |
| A store declared by two plugins. | `(plugin, store)` is the identity; two plugins declaring the same store name get two stores. Cross-plugin sharing is the qualified `@storageRef("other.store")` form, which requires the owner to exist — assert it rather than provisioning implicitly. |

## Out of scope

- Stage 3's inference, `capabilities.json`, `generate-platform` and the `deployPlugin` assertion.
  `~capabilities` stays hand-written here.
- Stage 4's wider provider catalogue.
- Stage 5's `UploadableFile.t` — the annotation stays the declaration form.
- Migrating the example's existing objects to a renamed bucket. If Gate 1 picks per-store buckets,
  the existing `online-shop-uploads` store is a rename, and moving 128 live objects is its own
  exercise — do it deliberately, not as a side effect of this stage.
