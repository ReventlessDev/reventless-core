# Platform `Main.res` — Capability-Driven Resource Provisioning

**Status:** Analysis
**Date:** 2026-07-28 (revised same day — §5.5/§5.6/§7: semantic-type foundation moved ahead of Stage 1)
**Plans:** [platform-capability-provisioning-stage-0.md](../plans/platform-capability-provisioning-stage-0.md), [semantic-type-marker-and-storage-ref.md](../plans/semantic-type-marker-and-storage-ref.md)
**Subject:** [examples/online-shop-hybrid/platform-aws/src/Main.res](../../examples/online-shop-hybrid/platform-aws/src/Main.res)
**Question:** Why does the platform composition root hand-write infrastructure (upload bucket, place index, served-bucket list) that exists only because *a plugin* needs it — and can that be recognised and provisioned automatically?

---

## Summary

- **The upload bucket does not belong in `Main.res`** — but it cannot simply be deleted, because it is currently the *only* place in the codebase where "this app stores files" is written down (§2). It should become a **plugin-owned** bucket, one per declared store, provisioned from the plugin's own declaration (§5.3).
- **The place index is the same chain**, with one difference: it backs a stateless lookup service with no per-plugin data, so it stays **platform-scoped and shared** — one geocoding service for every plugin that needs it. Its `dataSource`/`intendedUse` are real licensing decisions, so they belong in Pulumi config, not code (§5.3).
- **`servedBuckets` should not exist in the public API.** It restates a framework constant (`servedPrefix = "uploads"`) that the app author cannot see, and nothing validates the match — writing `prefix: "media"` deploys green and 404s every image at runtime (§3.2).
- **Two live defects** fall out of the hand-written infra: `seed:reset` never empties the uploads bucket (no attribution tags), and nothing validates what lands in the event log — a client can put any URL in `imageUrl` and it is appended permanently (§3.3, §3.4).
- **The mechanism** is a capability model: the plugin declares, the framework provisions. The missing primitive is a *declared storage reference* — `@storageRef("productImages")` today, `productImage: UploadableFile.t` once semantic types land (§5).
- **The constraint to design around** is split-stack deploy ordering: the platform deploys first and has no access to plugin schemas. A build-time capability manifest feeding a generated platform root resolves it (§6).

---

## 1. What `Main.res` contains today

79 lines, of which **4 are the deploy program** and the rest is scaffolding:

| Lines | Content | Classification |
|---|---|---|
| 12 | `module Platform = ReventlessAws.Platform.Make()` | **Required.** The one real statement. |
| 18 | `let _cognitoUserPool = Platform_Stack.resolveCognitoUserPool()` | **Dead.** See §3.1. |
| 20–21 | `hostShellDist` = resolve `@reventlessdev/reventless-host-shell` + `/dist` | **Derivable.** Byte-identical in all three example platforms. |
| 27–36 | `PulumiAws.Location.PlaceIndex.make(...)` | **Plugin-induced.** Exists because `Customer.SetLocation` carries a `{lat, lng}` field. |
| 42–55 | `PulumiAws.S3.Bucket.make(... corsRules ...)` | **Plugin-induced.** Exists because `Product.imageUrl` holds an uploaded object — by convention only (§2). |
| 57–79 | `deployPlatform(~version, ~hostUiBundle={...})` | 2 of 6 fields carry information; 4 are derivation. |

Inside `hostUiBundle`: `assetsDir` and `bundleVersion` are constants identical across every example; `geocoderPlaceIndex`, `enableUploads` and `uploadBucketName` are three ways of saying *"this app needs geocoding"* and *"this app needs an object store"*; `servedBuckets` is pure derivation from `uploadBucket` (§3.2).

**The genuinely app-specific information in this file is two capability requirements.** Everything else is a hand-written encoding of the framework's own contracts.

---

## 2. How the requirement is expressed today — it isn't

**There is no storage-reference type, no annotation, and no declaration anywhere in a plugin that says "this field holds an uploaded object."** Tracing the upload chain end to end, because the gap is the whole point:

1. [ChangeProductImage.res](../../examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/ChangeProductImage.res) declares `imageUrl: string` — a plain string, type-identical to `name: string` and to a field holding an external `https://…` URL. Same in the [Products.res](../../examples/online-shop-hybrid/catalog/src/Product/StateViewSliceStream/Products.res) `state` it projects into.
2. The command's JSON Schema reaches the browser through the plugin structure. Auto UI's semantic layer (`@reventlessdev/reventless-ui`) applies a **field-name heuristic**: a string named `image`/`imageUrl`/`photo`/`photoUrl`/`avatar`/`avatarUrl`/`thumbnail` → **Image** semantic; a string named `file`/`attachment`/`upload` or ending in `storageRef`/`fileRef`/`attachmentRef` → **File** semantic. `imageUrl` matches the first.
3. The dropzone input is registered under **both** semantics — but only by an explicit `FileDropzoneInput.init(~adapter=…)` call.
4. That `init` runs **only if `config.uploadEndpoint` is present**. The shell's own comment at the call site: *"Absent endpoint ⇒ a `file` field stays a plain text box."*
5. `config.uploadEndpoint` exists only if `deployPlatform` provisioned the presign service — i.e. only because someone wrote `enableUploads: true` and a bucket in `Main.res`.

**Step 5 is the answer, and it is circular.** The field does not demand a bucket; the bucket's existence is what upgrades the field's widget. `imageUrl` degrades silently to a text input when the platform lacks the capability — nothing errors, nothing warns. The requirement's single written form in the entire codebase is `enableUploads: true`, in a platform file the plugin author never opens.

The two places a declaration would live both fall short:

- **Type level:** nothing. There is no `Reventless.StorageRef.t`, and no `@schema` type carrying "this is an object-store key".
- **Annotation level:** `@semantic("file")` *does* exist in the PPX — but [StateAnnotations.ml](../../packages/reventless-ppx/src/ppx/StateAnnotations.ml) gates every injection site on `ptype_name.txt = "state"`, and emits it as `x-reventless-semantic` on read-model schemas. **It cannot be written on a command field.** The very form that performs the upload is heuristic-only by construction.
- The `*storageRef`/`*fileRef`/`*attachmentRef` convention is the closest thing to a definition, and it is a lowercase string comparison in UI code, not a framework concept. The example plugin does not use it — `imageUrl` reaches the dropzone through the *display*-oriented Image semantic instead.

The seed's product images do travel a real upload → S3 → CloudFront loop. They do so because a human connected the two ends by hand.

**The place index is the same shape, one rung shorter.** [Customer.res](../../examples/online-shop-hybrid/ordering/src/Customer/Aggregate/Customer.res) declares `type location = {lat: float, lng: float}` for `SetLocation`; the heuristic resolves an object field with numeric `lat`/`lng` sub-properties to **GeoPoint**, which mounts the map input, which reads `config.geocoderEndpoint` → geocoder Lambda → place index. `{lat, lng}` is a structural coincidence the UI pattern-matches, not a declared type.

**Consequence for the design.** Field *names* are machine-readable before deploy — they sit in the sury schemas [Plugin_Structure.res](../../reventless/core/src/plugin/component/Plugin_Structure.res) already walks. The *intent* is not. So "lift the UI's inference rules into core" is not sufficient on its own: those rules are display heuristics that **guess**, and guessing is a poor basis for creating and destroying infrastructure. §5.1 therefore puts declaration first and heuristics second.

---

## 3. What that costs

### 3.1 Authoring cost

A developer adding a product image must know: that an image field implies an upload input; that the input needs a presign service; that the service is provisioned by `deployPlatform` behind `enableUploads`; that it needs a bucket the *app* must create; the CORS rules that bucket needs; and that the bucket must additionally be listed under `servedBuckets` with the right prefix. **Six framework internals leak into an app file to express one bit of information.**

The redundant line 18 is symptomatic. `Platform_Stack.resolveCognitoUserPool` is a process-cached singleton ([Platform_Stack.res:152](../../reventless/aws/src/Platform_Stack.res#L152)), already called inside the functor body at [Platform.res:254](../../reventless/aws/src/Platform.res#L254) (Events API auth) and again at [Platform.res:1512](../../reventless/aws/src/Platform.res#L1512) (config.json). The call in `Main.res` provisions nothing that would not otherwise exist. It survives because nobody can tell, from the app side, which of these lines are load-bearing.

### 3.2 `servedBuckets` is not a decision — it is a restatement

[Platform.res:1539–1546](../../reventless/aws/src/Platform.res#L1539-L1546) provisions the presign service as `Upload_Presign_S3.make(~bucketName)` — with no `~servedPrefix`, so it takes the default `"uploads"` from [Upload_Presign_S3.res:34](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res#L34), and the handler returns refs of the form `/uploads/<uuid>`. For those to resolve, the host-shell distribution must carry an `uploads/*` cache behavior pointing at that bucket — which is exactly what `servedBuckets: [{prefix: "uploads", …}]` establishes.

Every field of that record is reachable from `uploadBucket`, and `prefix` must equal a default the app author cannot see. **Nothing validates the match.** Writing `prefix: "media"` compiles, deploys green, and yields 404s on every uploaded image — the presign service mints `/uploads/…` refs and CloudFront has no behavior for that path. A latent bug class created purely by asking the app to restate a framework constant.

### 3.3 Hand-written infra silently drops framework invariants

Framework-created buckets go through helpers that apply a house standard. Hand-written ones do not, and the drift is real in this file today:

- **No attribution tags.** Every framework resource carries `AWS.Tags.make(~name, ~kind, ~role, ~scope, …)` — see [TaskBucket_S3.res:146](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L146) and [Plugin_Stack.res:162](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L162). The `online-shop-uploads` bucket has none, and `platform-aws/Pulumi.yaml` sets no `aws:defaultTags`. The guarded store-wipe tool discovers targets **only** through `reventless:platform` + `reventless:environment` tag filters against the Resource Groups Tagging API ([ReventlessSeedAws_Reset.res:176–220](../../reventless/seed-aws/src/ReventlessSeedAws_Reset.res#L176-L220)). **`pnpm run seed:reset` therefore never empties the uploads bucket** — a "wipe the alpha store" leaves every uploaded product image behind while the events referencing them are gone.
- **No `BucketPublicAccessBlock`.** [Plugin_Stack.res:434](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L434) documents the framework's assumption explicitly — *"the served bucket keeps its own all-true BucketPublicAccessBlock (app-owned)"*. The app never created one; the framework's own bundle bucket gets one at [Plugin_Stack.res:172](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L172). Account-level S3 defaults currently cover this, so it is a latent gap rather than a live exposure — but it is an invariant the app was quietly made responsible for and did not honour.
- No encryption, versioning, or lifecycle policy — decisions the framework makes consistently for its own buckets and that were never made here.

**This is the strongest argument for automation.** The cost is not the twelve lines; it is that those twelve lines sit outside every convention the framework enforces on itself, and the divergence is invisible until an operational tool quietly does nothing.

### 3.4 Nothing validates what lands in the event log

The same missing declaration leaves a second hole, on the plugin side. [ChangeProductImage_Behavior.res](../../examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/ChangeProductImage_Behavior.res) passes the string straight through:

```rescript
| ChangeProductImage({productId, imageUrl}) =>
  if !state.exists { Error(ProductNotFound) }
  else if imageUrl == state.currentImageUrl { Ok([]) }
  else { Ok([ProductImageChanged({productId, imageUrl})]) }
```

`imageUrl` is never checked against anything. A client can submit an external `https://…` URL, a `data:` URI, or a path into another plugin's stored objects, and it is appended to the event log **permanently** — event-sourced data being precisely the worst place to discover you accepted junk. The presign service mints well-formed refs; nothing requires the command to carry one.

This is not an argument for hand-written validation in every behavior. It is the second reason the reference should be *declared*: a declared ref is format-checked by the schema before `decide` runs, and the declaration that closes this hole is the same one that provisions the bucket.

---

## 4. Precedent — the framework already does this everywhere else

This is not a new pattern; it is an unfinished one.

| Declared in a plugin | Auto-provisioned | Where |
|---|---|---|
| `Task.buckets: [{bucketName: "product-imports", …}]` | S3 bucket + CORS + IAM + notification wiring | [TaskBucket_S3.res:125](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L125) |
| Aggregate / DCB slice | EventLog tables, command topics (FIFO SQS), Lambdas, IAM | `reventless-aws` adapters |
| ReadModel / StateViewSlice | QueryDb tables + GSIs from `@index`/`@id`, resolvers | ditto |
| `@@reventless.async` | A whole extra FIFO-backed command Lambda | plugin generator |
| Any component | GraphQL SDL, subscriptions, authorization directives | `Plugin_Builder` |
| Any plugin | Its entire AWS deploy program (`Main.res`) | [Codegen.res:534](../../reventless/spec/src/generator/Codegen.res#L534) |

[ImportProducts.res](../../examples/online-shop-hybrid/catalog/src/Task/ImportProducts.res) is the model to copy: the plugin says `bucketName: "product-imports"` and a bucket appears in **the plugin's own stack** with tags, CORS, and least-privilege IAM. Nobody writes Pulumi. An upload store is the same kind of statement — it just happens to be induced by a field rather than a literal.

Two more seams already exist:

- **[DeployBootstrap.res](../../reventless/infra/src/components/DeployBootstrap.res)** — a `PreDeploy`/`PostDeploy` registry built so "deploy-time extension becomes *registration*, not *file editing*". Currently no-op.
- **[Util_LocalConfig.res](../../reventless/aws/src/util/Util_LocalConfig.res)** — `hostUiBaseDomain`/`hostUiHostedZoneId` demonstrate opt-in via Pulumi config with a safe default, no code ([Platform.res:1464–1484](../../reventless/aws/src/Platform.res#L1464-L1484)).

And the in-memory platform already proves zero-config is achievable: [platform-local/src/Main.res](../../examples/online-shop-hybrid/platform-local/src/Main.res) is 10 lines with no bucket, no index, no served list — the local server mounts `/__inmemory/upload` and the served-object routes unconditionally ([DomainGraphQL_Server.res:138](../../reventless/local/src/adapter/DomainGraphQL_Server.res#L138)). **Same app, same plugins, same capability — one platform requires twelve lines of Pulumi and the other requires nothing.** That asymmetry is the defect.

---

## 5. The concept: capabilities

A **capability** is a named, provider-agnostic infrastructure service that a component's *functionality* requires, distinct from the storage/messaging substrate every component gets by default: `ObjectStore`, `Geocoding`, `EmailDelivery`, `SecretStore`, `FullTextSearch`, `Vpc`.

### 5.1 Declare

Three sources, in priority order.

**1. A declared storage reference — the missing primitive.** The declaration must name **which store**, not merely "this is a file", because the store is what gets provisioned:

```rescript
@schema
type command =
  ChangeProductImage({productId: string, @storageRef("productImages") imageUrl: string})
```

The mechanism already exists in the PPX: `@partitionTag` injects `@s.matches(Reventless.DcbTag.string)` onto the field's type, and `@storageRef("productImages")` would inject `@s.matches(Reventless.StorageRef.forStore(~plugin="Catalog", ~store="productImages"))`. One annotation then drives three things:

1. **Provisioning** — `Catalog` needs an object store named `productImages` (§5.3).
2. **UI** — the field mounts an upload input bound to *that store's* presign endpoint, instead of guessing from the name and hoping an endpoint exists. The §2 circularity disappears: a declared ref on a platform without the capability is a deploy-time error, not a silent text box.
3. **Validation** — a malformed or foreign ref is rejected **by the schema, before `decide` runs**. No I/O, behaviors stay pure, identical on local and AWS. This closes §3.4.

Lifting `@semantic` off its `type state` gate is worth doing alongside so it works on `command` and `event` records too — but `@semantic` carries a *display* hint and `@storageRef` a *store identity*; they are not one annotation wearing two hats.

**2. Inferred from field names** — a migration aid and a lint, not the mechanism. The UI's heuristics become a pure core module, `Capability_Inference`, over the schema data `Plugin_Structure` already walks:

| Rule | Requirement |
|---|---|
| field typed `UploadableFile.t`, or annotated `@storageRef("<store>")` | `ObjectStore("<store>")` — **declared, authoritative** |
| `Task.buckets` entry | `ObjectStore("<bucketName>")` — declared (already provisioned today) |
| string named `file`/`attachment`/`upload`, or ending `storageRef`/`fileRef`/`attachmentRef` | `ObjectStore` — inferred |
| string named `image`/`imageUrl`/`photo`/`avatar`/`thumbnail` | `ObjectStore` — inferred, **weak** |
| field typed `GeocodedAddress.t`, annotated `@semantic("geo-point")`, or an object with numeric `lat`/`lng` | `Geocoding` |

The `image`-name rule is deliberately weak: `imageUrl` is genuinely ambiguous between an uploaded object and an external URL, and today's UI resolves that ambiguity by asking whether an endpoint happens to exist — which a capability scan cannot do, since it is the thing deciding that. An inferred-only `ObjectStore` should therefore **warn and provision**, naming the field and pointing at `@storageRef`.

Precedent for derivation is solid — `DcbScopeInference` derives read scope from the slice graph, `Plugin_Structure` derives `labelField`/`statusField` from names and annotations. The difference is only that a wrong guess here costs infrastructure rather than a label, which is why declaration outranks it. **Inference must be advisory-with-override, never silent-only** (§8).

**3. Explicit capability declaration**, for what neither type nor field can express: a file-level `@@reventless.requires(ObjectStore, EmailDelivery)`, matching the existing `@@reventless.async` / `@@reventless.systemCallable` vocabulary — with `@@reventless.requires.not(ObjectStore)` as the denial for a spec whose `avatarUrl` really is an external URL. `SendOrderConfirmation` already declares `externalSystem = Some("EmailService")` with no infra binding: the natural first client when an SES capability lands.

### 5.2 Collect

`Plugin_Structure.make` gains a `capabilities: array<capabilityRequirement>` field — the deduplicated union over every component. A requirement is a capability **plus its instance key where it has one**: `ObjectStore("productImages")` is distinct from `ObjectStore("productImports")` and provisions a different bucket, whereas `Geocoding` is instance-free. Each entry carries provenance (`Declared(component, field)` / `Inferred(component, field)`) so deploy logs and error messages can name *why*. The requirement set becomes part of the plugin's structural description alongside `queryableDef` and the component graph.

### 5.3 Provision

Per provider (`reventless-aws`, `reventless-local`, future `reventless-postgres`), a `Capability_<Name>_<Impl>` module mirroring the existing deploy-time/runtime split:

```rescript
module type CapabilityProvider = {
  let capability: Reventless.Capability.t
  // Deploy-time: create the resource(s), return the endpoints/config the shell
  // and the runtime need.
  let provision: (~config: Reventless.Capability.config) => outputs
}
```

- `Capability_ObjectStore_S3` → **one instance per declared store**: bucket (framework tags, PAB, CORS, lifecycle) + a presign Lambda whose `s3:PutObject` is scoped to exactly that bucket + the CloudFront served path. It owns the prefix contract on both sides, making §3.2's mismatch unrepresentable. Per-store presign Lambdas are also the least-privilege story — today's single service holds write access to everything.
- `Capability_Geocoding_AwsLocation` → place index + geocoder Lambda Function URL. `dataSource` (Esri / HERE / Grab) and `intendedUse` (`SingleUse` / `Storage`) are licensing, cost and data-retention decisions, so they belong in Pulumi config with today's defaults, following the `hostUiBaseDomain` precedent. A place index has no standing charge — only per-request billing — so provisioning it on a declaration is cheap even if the map input is never opened.
- `Capability_ObjectStore_InMemory` → the routes `DomainGraphQL_Server` already mounts, now mounted *because a capability was resolved* rather than unconditionally.

**Placement rule** — where a capability's resources live:

| Scope | Rule | Examples |
|---|---|---|
| **Plugin** | the resource holds the plugin's *data*, so it should live and die with the plugin | Object stores (one per declared store), Task buckets (today), a plugin-private queue |
| **Platform** | a shared, stateless *service* every plugin calls, or something attached to a platform-owned monolithic resource | `Geocoding`, the serve wiring on the CloudFront distribution |

So: **one bucket per declared store, owned by the plugin — not one bucket per platform.** The CloudFront distribution *is* monolithic and platform-owned, so a plugin stack cannot add an origin to it — but that is an **ordering** constraint ("the platform must know the list at deploy time"), which the capability manifest supplies (§6). It is easy to mistake it for a constraint on how many buckets may be served, and it is not:

- **The machinery already handles N.** [Plugin_Stack.res:145](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L145) takes `~servedBuckets: array<servedBucket>`, and every consumer is per-entry — one origin per bucket, one ordered cache behavior per prefix, one `BucketPolicy` per bucket scoped to this distribution. N served buckets requires **no new CloudFront code**.
- **Consistency.** `Task.buckets` already provisions a per-plugin bucket in the plugin's own stack. A platform-owned upload bucket would give the framework two ownership models for one resource type.
- **Bucket-level settings prefixes cannot express:** versioning, Object Lock, a per-plugin KMS key, replication — plus clean `pulumi destroy` semantics when a plugin retires. (Lifecycle rules *are* prefix-scopeable, so that is not an argument either way.)

What per-store buckets do **not** buy is read isolation: a served object is fetchable by anyone who knows its path regardless of which bucket backs it. Splitting buckets makes ownership and policy explicit; making objects private is a separate decision (signed URLs or cookies).

The real cost is bucket count — names are globally unique and buckets are account-limited, and `plugins × stores × stacks` multiplies quickly once alpha/beta/main and personal stacks are counted. **Check the account's current limit before committing**; it is the one input that could justify falling back to prefixes.

### 5.4 Wire

`deployPlatform` already assembles `config.json` from resolved outputs ([Platform.res:1548–1596](../../reventless/aws/src/Platform.res#L1548-L1596)). With providers, the `switch` chains (`withEvents` → `withGeocoder` → `withUpload`) collapse into a fold over resolved capability outputs, and `servedBuckets` leaves the public API entirely — the `ObjectStore` provider hands its served path to the distribution builder directly, with the prefix it also gave the presign service.

**Provisioning a store and serving it are two decisions, and only one of them used to be unconditional.** A store's bucket is created with an all-true public-access block and takes its read grant solely from a distribution's `BucketPolicy`, so a provisioned store is not a readable one. Until this was fixed, every consumer of the provisioned stores — the `uploadEndpoints` map and `~servedBuckets` on the distribution — sat inside `deployPlatform`'s `switch hostUiBundle`. A platform that deploys no shell, because its UI ships from its own stack, therefore provisioned stores that nothing could name and nothing could read: presign services existed, the buckets existed, and no URL for either was published anywhere.

Two things follow, and the second is the constraint that shapes the answer:

- **The store topology is exported unconditionally** — `uploadEndpoints` (qualified `{plugin}.{store}` → presign URL) and `objectStores` (→ `{bucketName, keyPrefix, baseUrl?}`) are stack outputs whenever anything is declared, with `getObjectStoreEndpoints()` as the in-process accessor alongside `getSplitApiOutputs()`. Both are omitted entirely when nothing is declared, so a deployment that declares no store keeps a byte-identical output set.
- **Serving is owned by the stack that owns the bucket, and is never split.** **S3 permits exactly one bucket policy per bucket.** If the read grant were written by whichever stack happened to build a distribution, two distributions fronting one store would each write that single policy and silently unpick the other's grant — a green deploy that 404s afterwards. That rules out the otherwise-attractive "export the bucket descriptors and let each consumer wire its own origin", and is why a separately-deployed UI receives a **`baseUrl`** rather than a bucket identity: a URL is both a smaller contract and one that cannot collide.

So the topology is a three-way choice, decided in one place ([`Util_StoreLayout.servingFor`](../../reventless/aws/src/util/Util_StoreLayout.res)) precisely so that "both" is not expressible:

| Deployment | Serves the stores | What a consumer gets |
|---|---|---|
| No store declared | nothing | neither output is exported |
| Platform deploys the host shell | the shell's distribution, same-origin | a relative `/{prefix}/…` resolves; no `baseUrl` |
| UI ships from its own stack | a platform-owned distribution over the store buckets | `baseUrl` + `keyPrefix` per store |

The `servedBucket` type already made the *within-one-distribution* case unrepresentable by grouping prefixes per bucket rather than per prefix. This is the same reasoning one level up: across distributions.

### 5.5 Semantic types — not a future stage, a prerequisite

**Revised 2026-07-28.** This section originally read "semantic types will land in the framework in the future", and §7 staged them last. Tracing the actual schema-emission paths (§5.6) inverts that: the *foundation* of the semantic-type work — one generic marker read during the schema walk — is what makes §5.1's declaration reach the UI at all. It is a **prerequisite of Stage 1**, not a successor to it. The examples below still describe the end state; what changed is that the first rung of that ladder is now on Stage 1's critical path.

When the types land, §5.1's annotations collapse into the field's type and everything else falls out of it. Both examples are worth writing down now, so the annotation design is a waypoint on that road rather than a detour.

#### Product image

```rescript
// now — annotation
ChangeProductImage({productId: string, @storageRef("productImages") imageUrl: string})

// future — semantic type
ChangeProductImage({productId: string, productImage: UploadableFile.t})
```

From `productImage: UploadableFile.t` alone the framework derives:

| Derived | Value |
|---|---|
| Store name | `productImages` — the field stem, pluralised |
| Bucket | `<platform>-<stack>-catalog-product-images`, plugin-owned, framework tags + PAB + CORS |
| Served path | `/uploads/catalog/product-images/*` on the host-shell distribution |
| Presign service | one, `s3:PutObject` scoped to that bucket only |
| Capability requirement | `ObjectStore("productImages")` in the plugin manifest |
| UI | upload input bound to that store — no name heuristic, no endpoint gating |
| Validation | schema-level: the value must be a ref into *this* store |

Pluralisation is consistent with conventions the repo already has — aggregates singular, read models plural, and the PPX already strips a trailing `s` when deriving plural DCB tag keys, so `productImage → productImages` is the inverse of a transform that already ships. It should stay overridable (`@storageRef("productImagery")`) where naive pluralisation is wrong: derivation is a default, not a law.

The field also gets its proper name back. `imageUrl` was only ever called "URL" because a string was the only thing available; `productImage: UploadableFile.t` says what it is.

#### Geocoded address

More interesting, because a resolved address is not a reference to something the framework stores — it is a value that had to be *computed* by an external service.

```rescript
// now — annotation
type command = | Register({email: string, address: string})
type event   = | Registered({email: string, @geocoded address: string, lat: float, lng: float})

// future — semantic type
type command = | Register({email: string, address: PostalAddress.t})      // untrusted input
type event   = | Registered({email: string, address: GeocodedAddress.t})  // resolved: formatted + lat/lng
```

`GeocodedAddress.t` in an event declares `Geocoding` exactly as `UploadableFile.t` declares `ObjectStore`: the manifest carries the requirement, the platform provisions one shared service, and `Main.res` needs nothing.

**Where the resolution runs matters.** Calling the geocoder inside `decide` would break the framework's central guarantee — `decide` must be pure and deterministic because it is re-run on every replay, and geocoding the same address next year can return a different point as the provider's data changes. A replayed event log would stop reproducing itself. The lookup cannot live there.

The type is the fix, and it is the same move as the storage ref: **resolution happens at the boundary, and the type is the evidence that it happened.**

- `GeocodedAddress.t` is abstract and constructible only by the geocoding capability. Holding one is proof a real lookup succeeded — the same shape as `ReventlessSpec.Id.String.t`, which cannot be conjured from a bare string.
- The impure step runs *before* the decision, at the trust boundary. The framework already has the component for server-side resolution: an **InboundTranslationSlice**, whose stated job is turning external input into commands. It resolves `PostalAddress.t` → `GeocodedAddress.t`, or rejects. (Today the browser's map input does this instead, which is why it is a UX affordance and not a guarantee — a client can post any lat/lng it likes, exactly as it can post any `imageUrl`.)
- `decide` then receives an already-resolved value and stays pure. **Resolution at the boundary, policy in `decide`**: "is this a real address" belongs at the boundary; "we do not ship outside the EU" belongs in `decide`, operating on the resolved coordinates.

Which is the unifying idea behind both examples: **a semantic type is capability-bearing evidence.** Holding one asserts that the capability exists, that the boundary work was done, and that the value is well-formed — and because the framework can see the type in the schema, it also knows what to provision. Provisioning, validation and purity turn out to be the same problem, and one declaration answers all three.

### 5.6 The emission path — why the `type state` gate is not on the critical path

§5.1 proposes `@storageRef("<store>")` and, alongside it, ungating `@semantic` from `type state` so annotations work on `command` and `event` records too. The gate is real — **11 sites** test `ptype_name.txt = "state"` in [StateAnnotations.ml](../../packages/reventless-ppx/src/ppx/StateAnnotations.ml) — but tracing what actually emits `x-reventless-semantic` shows the ungating is **not required** to get a declaration onto a command field. [SuryToJsonSchema.res](../../reventless/core/src/components/Api/SuryToJsonSchema.res) has two independent paths:

| Path | Lines | Driven by | Reaches |
|---|---|---|---|
| `mergeAnnotations` | `:14-90` | the PPX-collected `spec.semantic: array<(string, string)>` on `StateAnnotations` | read-model `state` records **only** |
| `toJsonSchema` → `deriveObjectSchema` → `fromSchemaType` | `:91-162` | the sury schema's own shape | **any** schema — command, event, state |

`x-reventless-semantic` is emitted only by the first, at `:71-73`. The second never consults `spec` at all — it walks the schema. So a marker carried in **sury metadata on the field's type** is emitted for commands and events without touching the PPX gate.

That matters because §5.1's own mechanism is already a type refinement: `@storageRef("productImages")` injects `@s.matches(Reventless.StorageRef.forStore(…))`. The store identity therefore rides on the field's *type*, and the only thing missing is a generic reader for that marker in the schema walk. Today there is none — `SchemaType.fromSury` detects the two existing typed markers by hardcoded special case ([SchemaType.res:15](../../reventless/core/src/components/Api/SchemaType.res#L15) for `DateTime`, `:30` for `Reference`), each with its own bespoke metadata id, so every new typed marker is currently bespoke work.

Two consequences for the plan:

1. **One generic marker (`Semantic.mark`) plus one read in the generic walk is the enabler for Stage 1** — cheaper than the 11-site PPX ungating, and it is work Stage 5 needs regardless. Re-expressing `DateTime` and `Reference` on it proves the machinery against two known-good cases with no behavior change.
2. **Ungating `@semantic` becomes optional and can be deferred.** It buys the *string* annotation on commands; the type path already covers the declared case, which is the one §5.1 wants authoritative. Keep it as a separate, lower-priority item rather than a Stage 1 dependency.

`StorageRef` is also the right first semantic type to ship, ahead of the richer value types (`Money`, `GeoPoint`): it has a waiting consumer in Stage 2, it closes §3.4's validation hole, it breaks §2's circularity, and it is a *branded scalar* — the `Id.T` shape ([Id.res](../../reventless/spec/src/types/Id.res): abstract `t`, `make` / `makeFromString` / `toString`, sealed so values cannot be mixed) that this package already ships and that new semantic types should follow rather than reinvent. Composite types raise open shape questions; a branded ref raises none.

---

## 6. The ordering constraint, and where the requirement set comes from

[deploy-manifest.yaml](../../examples/online-shop-hybrid/deploy-manifest.yaml) deploys `platform-aws` **first**; plugin stacks follow and consume platform outputs via `StackReference`. Correspondingly, [platform-aws/package.json](../../examples/online-shop-hybrid/platform-aws/package.json) has **no dependency** on `catalog`/`ordering` — deliberately, so plugins deploy and retire independently.

So when `deployPlatform` runs, the platform stack has **no access to any plugin's schemas**; it cannot introspect what it never imported. And the served paths are not independently attachable — a CloudFront distribution's origins and cache behaviors are one monolithic resource owned by one stack. (Contrast the merged-API path, where a plugin stack *can* associate its own source API against the platform's exported merged-API ARN: association is a separate resource, cache behaviors are not.)

Four candidates.

### Option A — platform stack imports the plugin packages

Add `catalog`/`ordering` to `platform-aws` deps and scan them without deploying.

*Pro:* type-safe, single source of truth, no new artifact.
*Con:* **reintroduces the coupling the split deploy exists to remove** — the platform would rebuild and redeploy on every plugin change. Rejected.

### Option B — build-time capability manifest + generated platform root ✅ recommended

1. Each plugin's build emits `capabilities.json` (requirement, instance key, provenance) next to `Plugin.res`.
2. A new `generate-platform` CLI — sibling to the existing `generate-plugin` — reads `deploy-manifest.yaml` (which already lists every plugin path), unions the manifests, and emits `platform-aws/src/Main.res`.
3. The emitted root is committed, exactly as plugin `Main.res` files are today ([Codegen.res:534](../../reventless/spec/src/generator/Codegen.res#L534)).

*Pro:* zero runtime coupling; deterministic; a requirement change shows up as a **reviewable diff in a committed file**, which is what makes §8's silent-deprovisioning risk manageable; matches a convention the repo already accepted for the harder case.
*Con:* new generator; needs plugin sources co-located at platform build time — which `deploy-manifest.yaml` already assumes.

*Caveat found while checking:* the `*.model.json` PPX sidecars would be the obvious input, but they are gated on `REVENTLESS_EMIT_SIDECAR=1` and are already stale — 27 `@@reventless.spec` files in `online-shop-hybrid`, 26 sidecars (`ChangeProductImage.model.json`, the most recently added slice, is missing). They are a reverse-codegen artifact, not a build invariant. `capabilities.json` must come from an **ungated** step of the normal plugin build, or the scan must read `.res` sources directly.

### Option C — two-pass via stack outputs

Plugin stacks export `requiredCapabilities`; the platform `StackReference`s each plugin optionally.

*Pro:* no build-time coupling; self-healing.
*Con:* **converges one deploy late** — first introduction of a capability needs plugin deploy → platform redeploy → plugin redeploy. Unacceptable as the primary path.

### Option D — runtime discovery

Serve `config.json` from a resolver instead of a static object, reading capability registrations from the platform's own read models (plugins already register themselves and their UI fragments through the Plugin aggregate / `Platform_UIFragments`).

*Pro:* genuinely dynamic — a plugin deployed at 3pm is usable at 3:01pm.
*Con:* **solves wiring, not provisioning.** No amount of runtime registration creates an S3 bucket. Complementary, not a substitute.

### Recommendation

**B as the mechanism, C as the safety net.** Generate the platform root from the build-time union, and have `deployPlugin` fail fast when the platform's exported capability set does not cover what the plugin requires:

```
Catalog requires capability `ObjectStore("productImages")`
  (declared: ChangeProductImage.imageUrl @storageRef("productImages"))
but platform stack `online-shop-hybrid-platform-aws/alpha` does not serve it.
Run `pnpm run generate` in platform-aws and redeploy the platform stack first.
```

That converts the ordering hazard from a silent 404 at runtime into a named, actionable deploy-time failure. D remains worth doing later for the wiring half.

---

## 7. Staged adoption

Each stage stands alone and is independently shippable.

**Stage 0 — derivation only, no new concepts.** Inside `deployPlatform`: derive `servedBuckets` from the upload bucket + the presign service's own `servedPrefix`; default `assetsDir` to the resolved host-shell dist; default `bundleVersion` to `~version`; drop the dead Cognito line from all three example roots. The bucket and index are still created in `Main.res`, but through framework helpers that apply tags and PAB:

```rescript
module Platform = ReventlessAws.Platform.Make()

let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.makeBucket(~name="online-shop-uploads")
let placeIndex = ReventlessAws.Capability_Geocoding_AwsLocation.makeIndex(~name="online-shop-geocoder")

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={geocoderPlaceIndex: placeIndex, uploadBucketName: uploadBucket},
)
```

Roughly 79 → 12 lines, and it fixes §3.2 and §3.3 immediately — restoring `seed:reset` coverage and removing the prefix trap — with no inference machinery at all.

**Stage 0.5 — the generic semantic marker (new, 2026-07-28).** One `Semantic.mark(id)` metadata id in `reventless/spec`, read generically in `SchemaType.fromSury` / `SuryToJsonSchema`'s schema walk and emitted as `x-reventless-semantic`; `DateTime` and `Reference` re-expressed on it, replacing their bespoke ids. No behavior change — the two known-good cases are the proof. This is what lets Stage 1's declaration reach a *command* field (§5.6), and it is groundwork Stage 5 needs anyway.

**Stage 1 — the declaration primitive.** `@storageRef("<store>")` on command/event/state fields, injecting the `@s.matches(StorageRef.forStore(…))` refinement, which surfaces the store on the JSON Schema through Stage 0.5's generic path so the UI reads a declared field instead of guessing. `StorageRef` follows the `Id.T` shape (§5.6). Annotate `ChangeProductImage.imageUrl`, `AddProduct.imageUrl`, `Products.state.imageUrl`. No infrastructure change and no event-schema change — but the requirement is now *stated* (which Stage 3 reads) and §3.4's validation hole is closed.

Ungating `@semantic` from `type state` is **no longer part of this stage** (§5.6): it buys the string annotation on commands, which the type path already covers for the declared case. Track it separately.

**Stage 2 — capability providers.** `deployPlatform` provisions from a named set; object stores move to the plugin stacks that own them (§5.3). No Pulumi in the app:

```rescript
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~capabilities=[ObjectStore("catalog", "productImages"), Geocoding],
  ~hostUi=Default,
)
```

**Stage 3 — inference and generation.** `Capability_Inference` (declaration-first, heuristics as a warning fallback) + `capabilities.json` + `generate-platform` + the `deployPlugin` assertion. `Main.res` joins the plugin roots as `// AUTO-GENERATED`, with the `~capabilities` list and a provenance comment emitted from the manifest:

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
ReventlessInfra.DeployBootstrap.run(PreDeploy)
module Platform = ReventlessAws.Platform.Make()
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  // catalog: ChangeProductImage.imageUrl @storageRef("productImages")
  // ordering: Customer.location {lat,lng}
  ~capabilities=[ObjectStore("catalog", "productImages"), Geocoding],
  ~hostUi=Default,
)
ReventlessInfra.DeployBootstrap.run(PostDeploy)
```

The platform learns only *which stores to serve* — the buckets are created by the plugin stacks that own them. The provenance comment is deliberate: it makes the diff readable when a capability appears or disappears.

**Stage 4 — catalogue growth.** `EmailDelivery` (SES identity + IAM), `SecretStore`, `Vpc` (Postgres-backed query storage), `FullTextSearch`, `MediaProcessing`, `WebhookIngress` — registered through [DeployBootstrap](../../reventless/infra/src/components/DeployBootstrap.res) so a provider can ship in a satellite package without touching `reventless-aws`.

**Stage 5 — the rest of the semantic-type library (§5.5).** With the marker and `StorageRef` already shipped in Stages 0.5–1, what remains here is breadth: `UploadableFile.t` and `GeocodedAddress.t` subsuming the annotations entirely (store name, bucket, served path, UI input, schema refinement and capability requirement all derived from the field's type), plus the richer value types whose shape questions are still open. Stage 1's annotations remain valid as the explicit-override form.

Stage 0 is worth doing regardless of whether the later stages are taken: it is pure derivation, it closes a live operational defect, and it removes the file's only correctness trap. Stages 0 and 0.5 are independent of each other and can proceed in either order or in parallel.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| **Silent deprovisioning.** A field rename drops the last `ObjectStore("productImages")` requirement → Pulumi deletes a bucket with live objects. | Capability removal is a **generated-file diff** under Option B, so it lands in review. Provisioned stores also carry `protect: true` / `retainOnDelete` by default, removable only via explicit config opt-out — consistent with [protecting-prod-infrastructure-resources.md](protecting-prod-infrastructure-resources.md). |
| **Inference false positives.** `externalImageUrl: string` on a spec that never uploads → an unused bucket. | Cheap failure mode (empty bucket, unused Lambda). `@@reventless.requires.not(...)` for explicit denial. Every inferred capability logged with provenance at deploy time. |
| **Inference false negatives.** A field named `banner` holding a storage ref. | Explicit `@storageRef` / `@@reventless.requires`. `deployPlugin`'s assertion (§6) turns the failure into a clear message rather than a runtime 404. |
| **Rules diverging from Auto UI.** The UI decides the widget; the platform decides the infra. If they drift, a widget appears with no endpoint. | Single source: core owns the declaration and the fallback heuristics; the UI consumes them. This also removes §2's circularity — the UI stops gating on "does an endpoint happen to exist". Right direction of dependency: the UI's inference table is currently the de-facto spec the backend must match. |
| **Retrofitting the declaration.** `UploadableFile.t` on an existing `imageUrl` changes an event schema; `@storageRef` does not. | Adopt the annotation first (no event-schema change, no replay concern); treat the semantic type as a later, opt-in migration. The scan accepts both. |
| **Bucket count.** `plugins × stores × stacks` against a globally-unique namespace and an account limit. | Verify the account limit before Stage 2 (§5.3). Prefix-within-one-bucket remains the fallback if the ceiling is real. |
| **Generator complexity.** `generate-platform` is new surface. | Scope it to exactly what `generate-plugin` does — read a manifest, emit a committed root. One new file kind, no new concepts. |

---

## 9. Related

- [zero-touch-plugin-assembly.md](zero-touch-plugin-assembly.md) — the same argument one level down (plugin composition root); the generator it proposes is the model Option B copies.
- [protecting-prod-infrastructure-resources.md](protecting-prod-infrastructure-resources.md) — the deprovisioning mitigation in §8.
- [platform-and-plugin-guide.md](../guides/platform-and-plugin-guide.md) — needs a "capabilities" section once Stage 2 lands.
