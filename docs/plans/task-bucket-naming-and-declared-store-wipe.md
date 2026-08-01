# Plan: task-bucket names, wiping declared object stores, and plugin-qualified store prefixes

**Date:** 2026-08-01
**Status:** Not started.
**Repos:** `reventless-core` only.
**Touches:** `reventless/core` (task bucket naming, registration warning), `reventless/aws` (bucket
destroy semantics, store prefixes, serving, presign), `reventless/seed-aws` (reset),
`examples/online-shop-hybrid` (task declarations + reset targets).

Four changes. The first two are independent defects found while reading one `seed:reset` dry run
against the deployed `alpha` stack of `examples/online-shop-hybrid`; Parts 3 and 4 close the
store-name collision that Part 2 has to defend against:

```
  catalog  (online-shop-hybrid-catalog-aws)
    DynamoDB tables:
            87  CatalogDcbEventLog-…
             …
    S3 buckets:
             0  importproductsproductimportsbucket-699dee6      ← Part 1: unreadable name
                                                                ← Part 2: the product images
                                                                          are missing entirely
```

The product images live in `alpha-stores-507202d/productImages/` and never appear under this scope.

| part | what | where it bites |
|---|---|---|
| 1 | readable task-bucket names | deploy-time naming |
| 2 | wipe declared object stores per plugin | operator tool |
| 3 | refuse colliding store prefixes early | deploy gate + registration warning |
| 4 | qualify store prefixes with the plugin | deploy-time layout + serving + presign |

Each lands as its own commit. Parts 1 and 2 are independent of everything else. Part 3 is worth
having on its own — it converts a late, opaque failure into an early, named one — and Part 4 then
*relaxes* the rule Part 3 enforces, without Part 3's code changing (see Part 4, "How this relaxes
Part 3").

---

# Part 1 — Task bucket physical names

## The gap

[`Task_Builder.res:176`](../../reventless/core/src/components/Task/Task_Builder.res#L176):

```rescript
let bucketStem = bucketSpec.bucketName->Option.mapOr("", pascalCase)
let name = taskName ++ bucketStem ++ "Bucket"
```

For the hybrid catalog's `ImportProducts` task declaring `bucketName: "product-imports"`, that
composes `ImportProductsProductImportsBucket`, which the AWS provider lowercases for S3 into
`importproductsproductimportsbucket-699dee6`.

Three defects compound in that one line:

1. **Stutter.** The task name and the bucket id restate the same two nouns, and the `Bucket` suffix
   restates the resource type — which `aws:s3/bucket` and the `reventless:role=Bucket` tag already
   carry.
2. **PascalCase in a lowercase namespace.** PascalCase carries word boundaries for DynamoDB, which
   preserves case. S3 does not, so the name collapses into an unreadable run-on. The framework's own
   S3 names already know this: [`Util_StoreLayout.bucketNameFor`](../../reventless/aws/src/util/Util_StoreLayout.res)
   emits kebab (`{plugin}-{store}`, `{stack}-stores`) through the same `S3.Bucket.make(~name)` path.
   Task buckets simply never got the same treatment, so kebab is the established house rule for S3
   logical names here, not a new convention.
3. **No qualifier.** Nothing in the name identifies the plugin or the project. This is observable
   today: the account holds two buckets whose base names are byte-identical and which differ only by
   Pulumi's random suffix — one from `online-shop-hybrid-catalog-aws`, one from another deployment's
   catalog project. Only the `reventless:platform` tag tells them apart.

## The rule

| declaration | name |
|---|---|
| bucket with no `bucketName` | `{plugin}-{task}` → `catalog-import-products` |
| bucket with a `bucketName` | `{plugin}-{task}-{bucketId}` → `catalog-import-products-product-imports` |

All segments kebab-cased and lowercased; no `Bucket` suffix. `{plugin}` comes from
`ResourceAttribution.current.contents.plugin` — the same ambient context
[`AWS_Tags.makeDict`](../../reventless/aws/src/adapter/AWS_Tags.res#L55) already reads — and is
omitted when a task is constructed outside any plugin.

The remaining stutter in the example is the *declaration's*, not the framework's: a task called
`ImportProducts` whose only bucket is named `product-imports`. Step 4 fixes that at the source
rather than adding a de-stutter heuristic to the framework.

### Why not route this through `ResourceNaming`

`Task_Builder` already receives `~resourceNaming: ReventlessInfra.ResourceNaming.operations`, so it
looks like the seam for this. It is not: `ResourceNaming` is a *runtime* interface (only
[`ScheduleOps`](../../reventless/core/src/util/ScheduleOps.res) consumes it), its `validateName` is a
character-sanitiser with no plugin context, and most implementations are the identity function.
Composing a deploy-time name there would overload a seam that means something else.

### Why not keep the URN and set the physical name only

`S3.Bucket.args` has a `bucket` field, so the physical name could change while the Pulumi resource
name stays `ImportProductsProductImportsBucket`. Rejected: setting `bucket` explicitly makes *us*
responsible for global uniqueness, whereas Pulumi's autoname suffix already provides it and is what
the declared-store buckets rely on. It is also a replace either way (see Migration below), so the
URN churn buys nothing.

## Steps

1. **Add `kebabCase` beside `pascalCase`** in [`Task_Builder.res:6`](../../reventless/core/src/components/Task/Task_Builder.res#L6) —
   splitting PascalCase/camelCase on case boundaries and normalising existing `-`/`_` runs, so both
   `"ImportProducts"` and `"product-imports"` reduce to the same shape. Pure; unit-tested.
2. **Compose the new name** at `Task_Builder.res:176`, joining the plugin (when ambient), the task,
   and the bucket id (when declared). Keep `bucketSpec.bucketName` as the untouched **runtime lookup
   key** into `Task.bucketNames` — only the emitted resource name changes, so no handler is affected.
3. **Guard the length.** S3 caps bucket names at 63 characters and Pulumi appends `-` plus 7 hex, so
   the composed name has a 55-character budget. Exceeding it must raise a deploy-time error naming
   the task and telling the developer to shorten the task or bucket id. Do **not** truncate —
   truncation silently manufactures collisions between two long names sharing a prefix.
4. **Drop `bucketName` from the three example tasks** —
   [`online-shop-hybrid`](../../examples/online-shop-hybrid/catalog/src/Task/ImportProducts.res#L10),
   `online-shop-aggregates`, `online-shop-dcb` — each of which declares a single bucket whose id
   restates its task. Verified safe: the string `"product-imports"` is read by nothing in the repo;
   it exists only to be concatenated into the bucket name. Note this also renames the bucket's
   side-effect Lambda from `ImportProductsProductImportsSideEffectHandler` to
   `ImportProductsSideEffectHandler` ([`TaskRuntime_Builder_PerBucket.res:22`](../../reventless/aws/src/adapter/Runtime/TaskRuntime_Builder_PerBucket.res#L22)) —
   a Lambda replace, no data at risk.
5. **Unit-test the rule** in `reventless/core/tests/` (`kebabCase` round-trips; plugin-present and
   plugin-absent composition; named and unnamed buckets; the length guard firing).

## Migration hazard — read before deploying

**Any bucket-name change is a replace**, and [`TaskBucket_S3.make`](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L125)
sets no `forceDestroy`. A replace against a task bucket holding even one object fails the deploy with
`BucketNotEmpty`.

6. **Thread `forceDestroy` into `TaskBucket_S3.make`**, gated on
   [`Util_StoreLayout.protectionFor`](../../reventless/aws/src/util/Util_StoreLayout.res) —
   `Unprotected` (the `pr-*` prefixes) gets `forceDestroy: true`. This mirrors exactly the judgement
   the store buckets already make, and without it every PR stack wedges on the first deploy after
   this change.
7. **Protected stacks (`alpha`, `dev`, production) need a manual drain** before the rename deploy:
   confirm the task bucket is empty (`aws s3 ls`), or empty it, then deploy. `alpha`'s currently
   reads 0 objects, so it lands clean today — but that is a fact with a shelf life, so re-check
   rather than assume.

## Verification

- Unit tests from step 5 green.
- `pulumi preview` on the hybrid `alpha` stack shows the task bucket, its two notifications and its
  role policy as **replace**, and no other resource replacing.
- After deploy: the bucket reads `catalog-import-products-<suffix>` and the next `seed:reset` dry run
  prints that name.

---

# Part 2 — Declared object stores in `seed:reset`

## The gap, which is two gaps

Discovery in [`ReventlessSeedAws_Reset.res:166-214`](../../reventless/seed-aws/src/ReventlessSeedAws_Reset.res#L166-L214)
filters purely on `reventless:platform` + `reventless:environment`. `reventless:platform` is the
**deploying Pulumi project**, and a declared store's bucket is created by the *platform* deploy
([`Platform.res:1574`](../../reventless/aws/src/Platform.res#L1574)). On a non-production stack
`Util_StoreLayout.layoutFor` returns `SharedBucket`, so [`Platform.res:1578-1581`](../../reventless/aws/src/Platform.res#L1578-L1581)
deliberately passes `~plugin=None` — one bucket serves every plugin, so no single plugin can own it —
and the bucket lands tagged `platform=<platform project>`, `scope=platform`, `plugin=""`.

Consequences, in both directions:

- **Under-wipe.** `1) domain`, the documented default, empties the catalog's event log and read
  models and leaves every product image behind — objects whose referencing events no longer exist,
  while the next seed mints fresh UUID keys on top. This is precisely the failure the
  [`Capability_ObjectStore_S3` header](../../reventless/aws/src/capability/Capability_ObjectStore_S3.res#L1-L11)
  warns about, reached by a different route: correct tags, wrong scope split.
- **Over-wipe.** `4) platform` *does* reach the bucket, but `emptyBucket` empties a whole bucket, so
  it destroys every plugin's objects — and it also truncates the platform's own tables (the plugin
  registry and the UI-fragment registry), which forces a redeploy before a re-seed. It is a
  workaround, not a fix.

## The mapping already exists

The platform stack exports it ([`Platform.res:1701-1719`](../../reventless/aws/src/Platform.res#L1701-L1719)).
Read from the deployed hybrid `alpha` stack:

```
$ pulumi stack output objectStores --json --stack alpha
{ "Catalog.productImages": { "bucketName": "alpha-stores-507202d",
                             "keyPrefix":  "productImages" } }
```

Plugin, bucket and prefix — everything a per-plugin wipe needs, keyed by `{plugin}.{store}`. And the
client side is already in place: [`ReventlessSeedAws.stackOutputs`](../../reventless/seed-aws/src/ReventlessSeedAws.res#L79)
reads stack outputs, and [`ListObjectVersionsCommand.input`](../../rescript/aws-sdk/src/S3.res#L56)
already accepts `Prefix`. **No new bindings and no new AWS API calls.**

## Store-name collisions

`Util_StoreLayout.keyPrefixFor(~store)` returns the **bare store name**, not a plugin-qualified one.
In a shared bucket, two plugins both declaring `productImages` therefore land on one
`productImages/` prefix, and no prefix-scoped wipe can tell whose objects are whose. Only
`Catalog.productImages` exists today, so this is latent — but a per-plugin wipe makes the prefix the
unit of ownership, which turns a latent ambiguity into a live data-loss path.

Qualifying the prefix to `{plugin}/{store}` *is* available and is Part 4 of this plan. An earlier
draft ruled it out on the grounds that `Util_StoreLayout` forbids a prefix that encodes layout —
that reading was too broad. The invariant is that a prefix must not encode **bucket layout**, which
varies per stack and would stop a production dump from resolving when restored into a PR stack.
Plugin and store are stack-invariant, so a qualified prefix satisfies it. The real constraint is
already-minted refs, which Part 4 handles by grandfathering.

Either way the reset must **detect and refuse**, fail-closed like every other gate in the file —
it is the tool that destroys data, so it must not depend on an upstream check having run:

- Within one bucket, no store's `keyPrefix` may **equal or contain** another's. Equality is the
  cross-plugin collision; containment matters because the delete prefix is `"{keyPrefix}/"`, so a
  store rooted at `a` would wipe one rooted at `a/b`. Testing containment rather than equality is
  what keeps this correct once Part 4 gives prefixes path structure.
- Reject an empty `keyPrefix`, and reject a **store name** containing `/` — a store may not
  hand-roll its own nesting. The composed prefix may contain `/` after Part 4; the declared name may
  not.
- A violation aborts the run naming every implicated `{plugin}.{store}`, the bucket and the shared
  or containing prefix, and both checks run **before** any counting, so it fails long before a
  delete is issued.

## Steps

1. **`target` gains `plugin?: string`**, defaulting to `label`. The `objectStores` key segment is the
   plugin's own name (`Catalog`) while the target label is the operator-facing one (`catalog`);
   case-folding and hoping would violate the file's stated posture that the caller declares the
   topology and the reset never guesses it. Update the hybrid
   [`SeedAwsReset.res`](../../examples/online-shop-hybrid/platform-aws/src/SeedAwsReset.res#L24-L28)
   targets accordingly.
2. **Resolve the stores.** Read `objectStores` from the `Platform`-group target's stack via
   `ReventlessSeedAws.stackOutputs`, regardless of which scope was selected — reading is side-effect
   free. Absent output (a platform declaring no stores) is normal and yields an empty list. **A
   `targets` array with no `Platform` entry must log that stores could not be resolved**, not skip
   silently — a silent skip is the current bug.
3. **Parse and validate** into `{qualified, plugin, store, bucketName, keyPrefix}`, then run the
   collision and prefix checks above.
4. **Attribute** each store to the selected target whose `plugin` matches. Stores belonging to
   unselected targets are simply not wiped.
5. **Count per store** — extend `countBucket` with `~prefix=?`, passing `"{keyPrefix}/"`. Fold the
   counts into the run total so the `total == 0` early exit and the confirmation prompt's object
   count both include images.
6. **Exclude store buckets from every target's plain bucket list**, matched by physical bucket name
   against the resolved set. This is the load-bearing step: it stops `platform` scope from emptying
   the shared bucket wholesale and makes a store reachable *only* through the plugin that declared
   it. Scope the exclusion to buckets named in `objectStores` — a platform's own upload bucket that
   no declaration points at stays a plain platform-scope bucket and keeps being emptied wholesale.
7. **Empty per store** — extend `emptyBucket` with `~prefix=?`.
8. **Re-check tags before deleting.** A store bucket arrives by stack output rather than by tag
   discovery, so gate 4 must still apply: confirm the bucket carries `reventless:platform` +
   `reventless:environment` for the platform project before issuing a delete. The existing `discover`
   call already returns exactly this set for a selected platform target; when the platform is not
   selected, make the one extra RGT call.
9. **Gate on both stacks.** The objects belong to a plugin but the bucket belongs to the platform
   project, so require `reventless:wipeable` on the plugin target's stack **and** the platform's
   before deleting. Refusal messages stay distinct per cause, as `gateTarget` already does.
10. **Extract the pure parts** — parsing, attribution, collision detection, prefix validation — as
    top-level functions and unit-test them in `reventless/seed-aws/tests/` (precedent:
    `EndpointResolutionTest.res`; `reventless-seed-aws` is already a declared jest project). Cases:
    collision refused; nested/empty prefix refused; plugin attribution incl. the explicit `plugin`
    override; missing `objectStores` output; missing `Platform` target.

## Report format

Counts before, confirmation after — for stores specifically, not just folded into the run total.

Dry run gains a third section per target:

```
  catalog  (online-shop-hybrid-catalog-aws)
    DynamoDB tables:
            87  CatalogDcbEventLog-…
    S3 buckets:
             0  catalog-import-products-…
    Object stores:
            14  Catalog.productImages   alpha-stores-507202d/productImages/
```

The wipe phase reports what it removed, per store:

```
Emptying catalog …
  truncated CatalogDcbEventLog-…
  emptied catalog-import-products-…
  emptied Catalog.productImages — 14 object(s) removed from alpha-stores-507202d/productImages/
```

And the existing post-wipe verify — which today only proves a global `remaining == 0` — gains a
per-store line, so "all images were wiped" is an observed fact rather than an inference:

```
  verified empty: Catalog.productImages — 0 object(s) remain under alpha-stores-507202d/productImages/
```

A non-zero remainder keeps the existing behaviour: fail with the count and tell the operator to
re-run.

## Verification

- Unit tests from step 10 green.
- Dry run on the hybrid `alpha` stack, scope `1) domain`: the catalog section lists
  `Catalog.productImages` with a non-zero count, and the run total includes it.
- Dry run, scope `4) platform`: `alpha-stores-…` **no longer appears** as a plain bucket.
- Real wipe, scope `2) catalog`: images removed, per-store verify line prints 0, and the platform's
  registry tables are untouched (so a re-seed needs no redeploy).
- Re-run the reset: reports 0 and exits via the "already reads empty" path.
- Collision path, exercised by unit test rather than on a live stack (a second plugin declaring
  `productImages` would have to be deployed to test it end-to-end, and the refusal is pure logic).

---

# Part 3 — Refuse colliding store prefixes at deploy

## What happens today

The collision is already fatal — just late, and by accident. Both serving arms build one CloudFront
cache behavior per served prefix ([`Plugin_Stack.res:243-247`](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L243-L247)),
and exactly one distribution fronts every store bucket. Two plugins declaring `productImages` produce
two behaviors with the same path pattern in **either** layout:

- `SharedBucket` — one `servedBucket` entry carrying `prefixes: ["productImages", "productImages"]`.
- `PerStore` — two `servedBucket` entries, each with `prefixes: ["productImages"]`, both on the one
  distribution.

CloudFront does not accept two cache behaviors with the same path pattern, so the deploy dies at
apply with an AWS-level error naming a path pattern rather than the two plugins that caused it.
(Read off the code path; not reproduced against a live distribution.)

**The prefix is a platform-global namespace, not a per-bucket one.** That is the finding, and it is
why no layout choice rescues the collision.

Before it fails, under `SharedBucket`, the two stores resolve to the same `(bucket, prefix)` and
three things silently go wrong:

- objects intermix with no way to attribute them — the wipe problem of Part 2;
- `Upload_Presign_S3` scopes its grants to `{bucket}/{prefix}/*`
  ([`Upload_Presign_S3.res:111`](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res#L111)),
  so a caller authorised for one plugin's store can address the other's objects — least privilege
  collapses without a symptom;
- the existing `coverageFor` gate passes cleanly, because `objectStores` holds two distinct keys and
  it has nothing to compare.

## Deliberate sharing is not a collision

[`Plugin_Structure.res:504-517`](../../reventless/core/src/plugin/component/Plugin_Structure.res#L504-L517)
resolves `@storageRef`'s optional plugin qualifier and only defaults to the declaring plugin when the
annotation left it off. So `@storageRef("Catalog.productImages")` from another plugin collapses to
**one** qualified key and is legitimate sharing. The error case is precisely *two unqualified
declarations of the same name in different plugins* — which means the message can offer both real
remedies: qualify the annotation if you meant to share, rename if you didn't.

`requiredStoreDeclaration` carries `component` and `field` as provenance, so the message can name
`Catalog.Product.imageUrl` and `Ordering.Shipment.imageUrl`, not just two store keys.

## Steps

1. **`Util_StoreLayout.collisionsFor`** — a pure predicate beside `layoutFor` / `coverageFor`, taking
   the declared stores as `{qualified, prefix, component, field}` and comparing on **`prefix`**, not
   on store name. Keying on the effective prefix is what makes Part 4 a no-op for this code: when
   prefixes become qualified, the same predicate keeps working and simply stops finding collisions
   that are no longer real.

   It must test **path containment, not string equality**: `a` collides with `a/b`, because a store
   rooted at `a` encloses one rooted at `a/b` for serving, IAM and wiping alike. Equality alone is
   sufficient only while every prefix is a single flat segment, which stops being true in Part 4 —
   and the one shape that then becomes reachable is a *legacy* store whose bare name equals a plugin
   name, e.g. legacy `Catalog` enclosing `Catalog/productImages`. Comparing on containment from the
   start means Part 4 introduces no new check.
2. **Call it at [`Platform.res:1526`](../../reventless/aws/src/Platform.res#L1526)**, where
   `declaredStores` already holds every plugin's pairs, and throw before a single resource is
   created. The message names every colliding qualified key with its declaration site, and states
   both remedies.
3. **Warn at plugin registration.** The platform holds every registered plugin's
   `pluginStructure.requiredStores`, so the same predicate runs there — and that path exists in
   `reventless-local`, so a developer sees it on `pnpm run start` before deploying anything. A
   **warning, not a rejection**: a hard failure in the registration path is how registrations have
   wedged before, and the deploy gate is the authoritative one. This mirrors the warn/throw polarity
   `coverageFor` already uses for `NotAdopted` vs `Missing`.
4. **Unit-test the predicate** in `reventless/aws/tests/Util_StoreLayoutTest.res`: no collision;
   two plugins colliding; deliberate qualified sharing *not* flagged; three-way collision reported
   once with all sites.

## Plugin-name uniqueness is not checked anywhere

Part 4's qualifier only qualifies if plugin names are unique within a platform. They are not
enforced to be, anywhere. The wider design question — whether to enforce, whether merging ever makes
sense, and how either survives installing a plugin whose name the installer did not choose — is
[plugin-name-identity-and-uniqueness.md](../analysis/plugin-name-identity-and-uniqueness.md); this
plan takes only the check that analysis calls step 1. What exists today and what it actually
guarantees:

- **The deploy manifest** lists plugins as a YAML mapping, so its *keys* are unique — but those keys
  are deployable names, not registered plugin names, and
  [`PlatformCodegen.res:76-82`](../../reventless/spec/src/generator/PlatformCodegen.res#L76-L82)
  states outright that "no rule relates the two" (`platform-inspector` against `PlatformInspector` is
  an ordinary pairing). It constrains nothing about plugin names.
- **The Plugin aggregate is keyed by plugin name** — [`PluginSpec.res:4-8`](../../reventless/core/src/plugin/lifecycle/PluginSpec.res#L4-L8):
  "One instance owns the whole lifecycle of every version of that name." So a second plugin
  registering an existing name is not rejected; it is read as a **new version of the first** and
  drives `VersionSuperseded`. The first plugin is superseded by an unrelated one, silently.
- **The capability union** merges on `{plugin}.{store}`
  ([`PlatformCodegen.res:40-61`](../../reventless/spec/src/generator/PlatformCodegen.res#L40-L61)),
  so two same-named plugins' stores collapse into one entry that is indistinguishable from
  deliberate cross-plugin sharing.
- **`GraphQL_Stitcher`** is the only place with any duplicate handling at all, and it *warns and
  skips* duplicate types and fields ([lines 209-267](../../reventless/core/src/components/Api/GraphQL_Stitcher.res#L209-L267)),
  so the loser's fields quietly vanish from the schema.

The store prefix is therefore the least of it: a same-named pair already corrupts the registry's
version lifecycle and the composed schema. Worth a check on its own merits, and cheap here because
the machinery is the same.

5. **Add plugin-name uniqueness to `collisionsFor`'s neighbourhood** — a sibling predicate over the
   registered names the platform composes, throwing at deploy with both deployable paths named.
6. **Warn at registration on a name whose incoming definition does not look like a new version of
   the existing one** — a heuristic, so a warning rather than a refusal, and explicitly *not* a
   change to supersession semantics. Legitimate redeploys must stay silent, so scope this narrowly
   or leave it to the deploy gate; decide when implementing, and say which was chosen.

## Why this is not a new restriction

Renaming a store is free before first deploy and **impossible after it**: minted refs are
`/{store}/…` in an append-only event log and can never be rewritten, so an old prefix would have to
be served forever. Every collision that Part 3 refuses is one that could not have deployed anyway.
The value is entirely in *when* and *how* it is reported — which is also why step 3's registration
warning matters: it fires while renaming is still free.

---

# Part 4 — Qualify store prefixes with the plugin

## Why

A flat, platform-global store namespace conflicts with plugin isolation. Plugins are independently
authored packages; extension points already use dotted names (`Catalog.Products`) to avoid exactly
this; and a platform assembling two plugins it does not own cannot rename either one's store —
it would have to fork one. Part 3 makes the collision survivable; Part 4 removes it.

## The rule

`Util_StoreLayout.keyPrefixFor` gains `~plugin` and returns `{plugin}/{store}` —
`Catalog/productImages`. The plugin segment is the name the plugin registers, verbatim, because
`{plugin}.{store}` identity already uses it verbatim and two spellings of one name is worse than an
unpretty one.

This satisfies the invariant `keyPrefixFor` is documented to protect: the prefix must not encode
**bucket layout**, because layout varies per stack and a production dump restored into a PR stack
must keep resolving. Plugin and store are stack-invariant, so a qualified prefix is as portable as a
bare one.

The accepted cost is that a plugin rename breaks existing refs. Plugin names are already load-bearing
elsewhere (they qualify store identity, and `meta.service` doubles as a projection dispatch key), so
this adds a case to an existing constraint rather than a new one.

The scheme rests on **plugin names being unique per platform**, and that is *assumed, never
enforced* — see Part 3, "Plugin-name uniqueness is not checked anywhere". Part 4 does not make that
worse (a same-named pair is already broken in ways that dwarf a shared store prefix), but it does add
the qualifier to the list of things silently wrong when it happens, which is why Part 3 gains a check
for it.

## A store gains a prefix *set*

Refs already written cannot be rewritten, so a store that has ever minted under a bare prefix must
keep **serving and deleting** under it. Every store therefore carries:

- one **mint prefix** — the qualified one, where new uploads go;
- zero or more **legacy prefixes** — served and releasable, never minted into.

The framework cannot tell from source whether a store has previously deployed, so the legacy set is
**declared, not inferred**: a one-time entry alongside the platform's existing hand-written
`~capabilities`, which shrinks to nothing for a new deployment. Inferring it from the stack's own
previous `objectStores` output was considered and rejected — it needs a self-referencing
StackReference, and its failure mode is silent ref breakage, which is the one failure this whole part
exists to prevent.

The legacy set is **collision-free by construction**: a bare-prefix collision could never have
deployed (CloudFront refuses it; after Part 3, the gate refuses it first), so anything eligible for
grandfathering is already unique *among bare prefixes*.

It is not automatically free of **nesting**, though, and this is the one genuinely new failure shape
Part 4 creates. A legacy store whose bare name happens to equal a plugin name — legacy `Catalog`,
rooted at `Catalog/…` — encloses that plugin's whole qualified space `Catalog/{store}/…`. Three
things then go wrong at once: CloudFront evaluates ordered behaviors in sequence, so `/Catalog/*`
can shadow `/Catalog/productImages/*`; the presign IAM `{bucket}/Catalog/*` grants across the
enclosed store's keys; and a prefix-scoped wipe of the legacy store deletes the qualified store's
objects. Part 3's containment test is what catches it, which is why that test is specified as
containment rather than equality.

## Steps

1. **`keyPrefixFor(~plugin, ~store)`** returns `{plugin}/{store}`; unit-test both the shape and its
   stack-invariance.
2. **Model the prefix set** — extend `ReventlessInfra.Platform.objectStore` (or the
   `declaredStoreServices` tuple at [`Platform.res:1600`](../../reventless/aws/src/Platform.res#L1600))
   with `mintPrefix` and `legacyPrefixes`, so every downstream consumer takes the set rather than
   re-deriving a single string.
3. **Declare the legacy set** on the platform's capability list, and thread it into
   [`Platform.res:1563-1601`](../../reventless/aws/src/Platform.res#L1563-L1601).
4. **Serving** — `declaredServedBuckets.prefixes` becomes the union of mint + legacy prefixes per
   bucket, so both old and new keys stay readable through the distribution. The bucket policy is
   bucket-wide (`{arn}/*`) and needs no change.
5. **Presign IAM** — [`Upload_Presign_S3.res:111`](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res#L111)
   emits one ARN per prefix per store, not one per store, or release stops being able to delete
   legacy objects.
6. **Release scope check** — [`Upload_Presign_S3_Ops.res:126-135`](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3_Ops.res#L126-L135)
   currently tests `key.startsWith("{servedPrefix}/")` against a single prefix, so a legacy-prefixed
   ref would be refused `not_in_store` the moment the store's prefix qualifies. It must accept **any**
   of the store's prefixes, while `{prefix}/{sub}/` identity scoping stays exactly as strict. This is
   the one step that silently breaks user-visible behaviour if missed.
7. **Minting** — [`Upload_Presign_S3_Ops.res:223`](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3_Ops.res#L223)
   keeps its `{prefix}/{sub}/{uuid}/{file}` shape and takes the **mint** prefix only.
8. **Stack output** — `objectStores` keeps `keyPrefix` as the mint prefix (existing consumers, incl.
   the seed's endpoint resolution, keep working unchanged) and gains an additive `legacyPrefixes`
   array.
9. **Reset (Part 2)** — count and empty across the store's **whole** prefix set, or a wipe leaves
   every pre-qualification image behind. Report them as one store with the combined count, since that
   is what an operator means by "the images".
10. **`reventless-local`** — [`LocalObjectStore`](../../reventless/local/src/adapter/LocalObjectStore.res#L25)
    serves one flat `uploads` prefix and has no per-store prefixes at all, so it neither breaks nor
    benefits. Leave it, and record the divergence here rather than in a code comment: local refs and
    deployed refs already differ in prefix, and Part 4 widens that gap.

## How this relaxes Part 3

Nothing in Part 3 changes. Its predicate keys on the effective prefix, so once prefixes qualify, two
plugins declaring `productImages` map to `Catalog/productImages` and `Ordering/productImages` — no
collision, no error. What the check still catches, correctly, is a collision **among legacy
prefixes**, which is the only place a bare prefix survives. The rule effectively narrows from
"unique per platform" to "unique per plugin" without a line of it being rewritten.

## Verification

- Unit tests for `keyPrefixFor`, the prefix set, the widened `scopeCheck`, and `collisionsFor` under
  qualified prefixes.
- On a stack with an existing store: deploy, then confirm an **old** ref still resolves through the
  distribution, an old ref can still be released, and a **new** upload mints under
  `{plugin}/{store}/…`.
- `seed:reset` reports one store whose count covers both prefixes, and reads 0 afterwards.
- A deliberately colliding pair of plugins deploys cleanly where it previously could not.

---

# Sequencing and risks

Parts 1 and 2 are independent of each other and of 3–4; either can land first. Part 1 requires a
deploy and carries the replace hazard, so if only one lands before the next seed cycle, **prefer
Part 2** — it is the one losing data correctness on every reset today.

Part 3 before Part 4. Part 3 is small, ships value on its own, and its predicate is the thing Part 4
reuses; doing 4 first would leave the interim state with no early diagnosis at all.

| risk | mitigation |
|---|---|
| Part 1 replace fails `BucketNotEmpty` on a protected stack | step 6 covers `pr-*`; step 7 is the manual drain for `alpha`/`dev`/production |
| Part 1 renames the side-effect Lambda too | expected and stated in step 4; no data at risk |
| Part 2 reads a stale `objectStores` output | the output is written by the same deploy that creates the bucket; a stale stack output means an undeployed stack, which `stackOutputs` already reports |
| Part 2 deletes under a prefix in a bucket it does not own | steps 8 and 9 — tag re-check plus wipeable on both stacks |
| Part 3 rejects a deployment that works today | impossible by construction — a colliding pair cannot have deployed; verified by the "deliberate sharing" test case |
| Part 4 breaks existing refs | the legacy prefix set, declared explicitly (steps 3–6); step 6 is the easiest one to miss and the one users would feel |
| Part 4 legacy declaration forgotten on an existing stack | old refs 404 and old releases refuse `not_in_store`. Consider a deploy-time warning when a stack provisions a store whose bucket already holds objects under the bare prefix and no legacy entry is declared |
| Part 4: a legacy bare store named like a plugin encloses that plugin's whole qualified space | Part 3's containment test, which is why it compares containment rather than equality |
| Two plugins registering one name — unchecked today, and it supersedes the first in the registry | Part 3 steps 5–6; note this is a pre-existing defect Part 4 depends on, not one Part 4 introduces |
| Plugin rename breaks refs | accepted; plugin names are already load-bearing for store identity |
