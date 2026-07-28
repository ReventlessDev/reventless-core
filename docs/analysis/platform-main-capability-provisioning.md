# Platform `Main.res` — Capability-Driven Resource Provisioning

**Status:** Analysis
**Date:** 2026-07-28
**Subject:** [examples/online-shop-hybrid/platform-aws/src/Main.res](examples/online-shop-hybrid/platform-aws/src/Main.res)
**Question:** Why does the platform composition root hand-write infrastructure (upload bucket, place index, served-bucket list) that exists only because *a plugin* needs it — and can that be recognised and provisioned automatically?

---

## 1. What the file actually contains

79 lines, of which **4 are the deploy program** and the rest is scaffolding. Accounting line by line:

| Lines | Content | Classification |
|---|---|---|
| 12 | `module Platform = ReventlessAws.Platform.Make()` | **Required.** The one real statement. |
| 18 | `let _cognitoUserPool = Platform_Stack.resolveCognitoUserPool()` | **Dead.** See §2.1. |
| 20–21 | `hostShellDist` = resolve `@reventlessdev/reventless-host-shell` + `/dist` | **Derivable.** Byte-identical in all three example platforms. |
| 27–36 | `PulumiAws.Location.PlaceIndex.make(...)` | **Plugin-induced.** Exists because `Customer.SetLocation` carries a `{lat, lng}` field. |
| 42–55 | `PulumiAws.S3.Bucket.make(... corsRules ...)` | **Plugin-induced.** Exists because `Product.imageUrl` is an uploaded storage ref. |
| 57–79 | `deployPlatform(~version, ~hostUiBundle={...})` | 2 of 6 fields carry information; 4 are derivation. |

Inside `hostUiBundle`:

- `assetsDir`, `bundleVersion` — constants, identical across every example.
- `geocoderPlaceIndex`, `enableUploads`, `uploadBucketName` — three ways of saying *"this app needs geocoding"* and *"this app needs an object store"*.
- `servedBuckets` — **pure derivation** from `uploadBucket` (§2.2).

So the genuinely app-specific information in this file is **two booleans**: *needs an object store*, *needs geocoding*. Everything else is a hand-written encoding of the framework's own contracts.

### 1.1 Why each resource exists — the plugin-side cause

**Upload bucket.** `catalog` declares [ChangeProductImage.res](examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/ChangeProductImage.res) with `imageUrl: string`, projected into [Products.res](examples/online-shop-hybrid/catalog/src/Product/StateViewSliceStream/Products.res) `state`. Auto UI's semantic layer (in `@reventlessdev/reventless-ui`) resolves a string field named `image`/`imageUrl`/`photo`/`avatar`/`thumbnail` to the **Image** semantic, and a field named `file`/`attachment`/`upload` or ending in `storageRef`/`fileRef`/`attachmentRef` to the **File** semantic, which is what mounts the upload input. The upload input needs `config.uploadEndpoint`, which needs the presign Lambda, which needs a bucket. **The chain starts at a field name in a plugin spec and ends at an S3 bucket in the platform stack** — with a hand-written hop in the middle.

**Place index.** `ordering` declares [Customer.res](examples/online-shop-hybrid/ordering/src/Customer/Aggregate/Customer.res) `type location = {lat: float, lng: float}` used by `SetLocation`. The same semantic layer resolves an object field with numeric `lat`/`lng` sub-properties to **GeoPoint**, which mounts the map input, which needs `config.geocoderEndpoint` → geocoder Lambda → place index. Identical chain, identical hand-written hop.

Both facts are already machine-readable **before deploy**: they live in the sury schemas that [Plugin_Structure.res](reventless/core/src/plugin/component/Plugin_Structure.res) walks, and (when the PPX sidecar is enabled) in the committed `*.model.json` files, which carry `{name, kind, annotations}` per field.

---

## 2. Three problems, not one

### 2.1 Authoring cost — the visible one

A developer adding a product image to a plugin must: know that an image field implies an upload input; know that the upload input needs a presign service; know that the presign service is provisioned by `deployPlatform` behind `enableUploads`; know that it needs a bucket the *app* must create; know the CORS rules that bucket needs; and know that the bucket must additionally be listed under `servedBuckets` with the right prefix. **Six framework internals leak into an app file to express one bit of information.**

The redundant line 18 is symptomatic. `Platform_Stack.resolveCognitoUserPool` is a process-cached singleton ([Platform_Stack.res:152](reventless/aws/src/Platform_Stack.res#L152)) and is already called inside the functor body at [Platform.res:254](reventless/aws/src/Platform.res#L254) (Events API auth) and again at [Platform.res:1512](reventless/aws/src/Platform.res#L1512) (config.json). The call in `Main.res` provisions nothing that would not otherwise exist. It survives because nobody can tell, from the app side, which of these lines are load-bearing.

### 2.2 `servedBuckets` is not a decision — it is a restatement

[Platform.res:1539–1546](reventless/aws/src/Platform.res#L1539-L1546) provisions the presign service as `Upload_Presign_S3.make(~bucketName)` — with no `~servedPrefix`, so it takes the default `"uploads"` from [Upload_Presign_S3.res:34](reventless/aws/src/adapter/Upload/Upload_Presign_S3.res#L34). The presign handler therefore returns refs of the form `/uploads/<uuid>`. For those refs to resolve, the host-shell distribution must carry an `uploads/*` ordered cache behavior pointing at that bucket — which is exactly what `servedBuckets: [{prefix: "uploads", bucketId, bucketArn, bucketRegionalDomainName}]` establishes.

Every field of that record is already reachable from `uploadBucket`, and `prefix` must equal a default the app author cannot see. **Nothing validates the match.** Writing `prefix: "media"` compiles, deploys green, and yields 404s on every uploaded image at runtime — the presign service mints `/uploads/…` refs and CloudFront has no behavior for that path. This is a latent bug class created purely by asking the app to restate a framework constant.

### 2.3 Hand-written infra silently drops framework invariants — with evidence

Framework-created buckets go through helpers that apply a house standard. Hand-written ones do not, and the drift is real in this file today:

- **No attribution tags.** Every framework resource carries `AWS.Tags.make(~name, ~kind, ~role, ~scope, …)` — see [TaskBucket_S3.res:146](reventless/aws/src/adapter/Task/TaskBucket_S3.res#L146) and [Plugin_Stack.res:162](reventless/aws/src/plugin/stack/Plugin_Stack.res#L162). The `online-shop-uploads` bucket has none, and `platform-aws/Pulumi.yaml` sets no `aws:defaultTags`. The guarded store-wipe tool discovers targets **only** through `reventless:platform` + `reventless:environment` tag filters against the Resource Groups Tagging API ([ReventlessSeedAws_Reset.res:176–220](reventless/seed-aws/src/ReventlessSeedAws_Reset.res#L176-L220)). **`pnpm run seed:reset` therefore never empties the uploads bucket.** A "wipe the alpha store" leaves every uploaded product image behind while the events referencing them are gone.
- **No `BucketPublicAccessBlock`.** [Plugin_Stack.res:434](reventless/aws/src/plugin/stack/Plugin_Stack.res#L434) documents the framework's assumption explicitly — *"the served bucket keeps its own all-true BucketPublicAccessBlock (app-owned)"*. The app never created one. The bundle bucket the framework owns gets one at [Plugin_Stack.res:172](reventless/aws/src/plugin/stack/Plugin_Stack.res#L172). Account-level S3 defaults currently cover this, so it is a latent gap rather than a live exposure — but it is a framework invariant that the app was quietly made responsible for and did not honour.
- No encryption, versioning, or lifecycle policy — decisions the framework makes consistently for its own buckets and that were never made here.

**This is the strongest argument for automation.** The cost of hand-written platform infra is not the twelve lines; it is that those twelve lines are outside every convention the framework enforces on itself, and the divergence is invisible until an operational tool quietly does nothing.

### 2.4 The hard constraint: split-stack deploy ordering

The reason this was not automated already is structural, and any concept must address it head-on.

[deploy-manifest.yaml](examples/online-shop-hybrid/deploy-manifest.yaml) deploys `platform-aws` **first**; plugin stacks follow and consume platform outputs via `StackReference`. Correspondingly, [platform-aws/package.json](examples/online-shop-hybrid/platform-aws/package.json) has **no dependency** on `catalog`/`ordering` — deliberately, so plugins deploy and retire independently.

So at the moment `deployPlatform` runs, the platform stack has **no access to any plugin's schemas**. It cannot introspect what it has never imported. Worse, the resources in question are not independently attachable: a CloudFront distribution's origins and ordered cache behaviors are a single monolithic resource owned by one stack, so a plugin stack **cannot** add an `uploads/*` read path to a distribution the platform owns. (Contrast the merged-API path at [Platform.res](reventless/aws/src/Platform.res), where a plugin stack *can* associate its own source API against the platform's exported merged-API ARN — association is a separate resource, cache behaviors are not.)

Any "automatic recognition" therefore has to answer: **where does the platform learn the requirement, and when?**

---

## 3. Precedent — the framework already does this everywhere else

This is not a new pattern; it is an unfinished one.

| Declared in a plugin | Auto-provisioned | Where |
|---|---|---|
| `Task.buckets: [{bucketName: "product-imports", …}]` | S3 bucket + CORS + IAM + notification wiring | [TaskBucket_S3.res:125](reventless/aws/src/adapter/Task/TaskBucket_S3.res#L125) |
| Aggregate / DCB slice | EventLog tables, command topics (FIFO SQS), Lambdas, IAM | `reventless-aws` adapters |
| ReadModel / StateViewSlice | QueryDb tables + GSIs from `@index`/`@id`, resolvers | ditto |
| `@@reventless.async` | A whole extra FIFO-backed command Lambda | plugin generator |
| Any component | GraphQL SDL, subscriptions, authorization directives | `Plugin_Builder` |
| Any plugin | Its entire AWS deploy program (`Main.res`) | [Codegen.res:534](reventless/spec/src/generator/Codegen.res#L534) |

[ImportProducts.res](examples/online-shop-hybrid/catalog/src/Task/ImportProducts.res) is the model to copy: the plugin says `bucketName: "product-imports"` and a bucket appears with tags, CORS, and least-privilege IAM. Nobody writes Pulumi. The upload bucket is the *same kind of statement* — it just happens to be induced by a field name rather than a literal, and to land in the platform stack rather than the plugin stack.

Two more relevant seams already exist:

- **[DeployBootstrap.res](reventless/infra/src/components/DeployBootstrap.res)** — a `PreDeploy`/`PostDeploy` registry designed precisely so "deploy-time extension becomes *registration*, not *file editing*". Currently no-op.
- **[Util_LocalConfig.res](reventless/aws/src/util/Util_LocalConfig.res)** — `hostUiBaseDomain`/`hostUiHostedZoneId` demonstrate opt-in via Pulumi config with a safe default, no code ([Platform.res:1464–1484](reventless/aws/src/Platform.res#L1464-L1484)).

And the in-memory platform already proves zero-config is achievable: [platform-local/src/Main.res](examples/online-shop-hybrid/platform-local/src/Main.res) is 10 lines with no bucket, no index, no served list — the local server mounts `/__inmemory/upload` and the served-object routes unconditionally ([DomainGraphQL_Server.res:138](reventless/local/src/adapter/DomainGraphQL_Server.res#L138)). **Same app, same plugins, same capability — one platform requires twelve lines of Pulumi and the other requires nothing.** That asymmetry is the defect.

---

## 4. The concept: capabilities

A **capability** is a named, provider-agnostic infrastructure service that a component's *functionality* requires, distinct from the storage/messaging substrate every component gets by default. `ObjectStore`, `Geocoding`, `EmailDelivery`, `SecretStore`, `FullTextSearch`, `Vpc`.

Four stages, each with an existing home in the codebase.

### 4.1 Declare — a capability requirement originates at a component

Two sources, in priority order:

1. **Inferred** from the component's schemas. The inference rules already exist and are already the thing that decides the UI needs an upload widget — they simply run client-side today. Lift them into a pure core module, `Capability_Inference`, over the same schema data `Plugin_Structure` already walks:

   | Rule | Capability |
   |---|---|
   | string field named `image`/`imageUrl`/`photo`/`avatar`/`thumbnail`, or `@semantic("image")` | `ObjectStore` |
   | string field named `file`/`attachment`/`upload`, or ending `storageRef`/`fileRef`/`attachmentRef`, or `@semantic("file")` | `ObjectStore` |
   | object field with numeric `lat`/`lng`, or `@semantic("geo-point")`; numeric `lat`+`lng` pair | `Geocoding` |
   | `Task.buckets` entry | `ObjectStore` *(plugin-scoped — already handled)* |

   This is the identical move the framework already makes elsewhere: `DcbScopeInference` derives read scope from the slice graph; `Plugin_Structure` derives `labelField`/`statusField` from field names and annotations. Deriving *infrastructure* from the same data is the same idea one layer down.

2. **Explicit**, for what inference cannot see — a file-level `@@reventless.requires(ObjectStore, EmailDelivery)`, matching the existing `@@reventless.async` / `@@reventless.systemCallable` opt-in vocabulary. This is also the escape hatch when inference is *wrong*: `@@reventless.requires.not(ObjectStore)` on a spec whose `avatarUrl` is genuinely an external URL.

   `SendOrderConfirmation` already declares `externalSystem = Some("EmailService")` with no infra binding — the natural first explicit-declaration client when an SES capability lands.

**Inference must be advisory-with-override, never silent-only.** A field rename must not silently delete a bucket. See §7.

### 4.2 Collect — union per plugin

`Plugin_Structure.make` gains a `capabilities: array<capability>` field: the deduplicated union over every component, each entry carrying its provenance (`Inferred(component, field)` or `Declared(component)`) so the deploy log and any error message can name *why*. This makes the requirement set a first-class part of the plugin's structural description, alongside `queryableDef` and the component graph — and it becomes visible in the same places (deploy logs, MCP tooling, the event graph).

### 4.3 Provision — capability providers, following the adapter pattern

Per provider (`reventless-aws`, `reventless-local`, future `reventless-postgres`), a `Capability_<Name>_<Impl>` module implementing a common interface, mirroring the existing deploy-time/runtime split:

```rescript
module type CapabilityProvider = {
  let capability: Reventless.Capability.t
  // Deploy-time: create the resource(s), return the endpoints/config the shell
  // and the runtime need.
  let provision: (~config: Reventless.Capability.config) => outputs
}
```

- `Capability_ObjectStore_S3` → bucket (**with the framework's own tags, PAB, CORS, lifecycle**) + presign Lambda Function URL + the CloudFront served path, and it owns the prefix contract on both sides — so the §2.2 mismatch becomes unrepresentable.
- `Capability_Geocoding_AwsLocation` → place index + geocoder Lambda Function URL.
- `Capability_ObjectStore_InMemory` → the routes `DomainGraphQL_Server` already mounts, now mounted *because a capability was resolved* rather than unconditionally.

**Placement rule** — where a capability's resources live:

| Scope | Rule | Examples |
|---|---|---|
| **Platform** | shared, referenced by the host shell, or attached to a platform-owned monolithic resource (the CloudFront distribution) | `ObjectStore`, `Geocoding` |
| **Plugin** | isolated per plugin, no platform resource to attach to | Task buckets (today), a plugin-private queue |

Platform-scoped object storage means **one** bucket with per-plugin key prefixes (`uploads/<plugin>/…`) and prefix-scoped IAM, not a bucket per plugin. That is what makes the CloudFront constraint tractable: one origin, one behavior, N plugins.

### 4.4 Wire — resolved endpoints flow outward automatically

`deployPlatform` already assembles `config.json` from resolved outputs ([Platform.res:1548–1596](reventless/aws/src/Platform.res#L1548-L1596)). With providers, the `switch` chains (`withEvents` → `withGeocoder` → `withUpload`) collapse into a fold over resolved capability outputs, and `servedBuckets` disappears from the public API entirely — the `ObjectStore` provider hands its served path to the distribution builder directly, with the prefix it also gave the presign service.

---

## 5. Where does the platform learn the requirement set?

The open question from §2.4. Four candidates.

### Option A — platform stack imports the plugin packages

Add `catalog`/`ordering` to `platform-aws` deps and call `Capability_Inference.scan([module(Catalog), module(Ordering)])` without deploying them.

*Pro:* type-safe, single source of truth, no new artifact.
*Con:* **reintroduces the coupling the split deploy exists to remove.** The platform would rebuild and redeploy on every plugin change. Rejected.

### Option B — build-time capability manifest + generated platform root ✅ recommended

1. Each plugin's build emits `capabilities.json` (name, provenance) next to `Plugin.res`, from the same PPX/spec scan that already produces `*.model.json` sidecars.
2. A new `generate-platform` CLI — sibling to the existing `generate-plugin` — reads [deploy-manifest.yaml](examples/online-shop-hybrid/deploy-manifest.yaml) (which already lists every plugin path), unions their manifests, and emits `platform-aws/src/Main.res`.
3. The emitted root is committed, exactly as plugin `Main.res` files are today ([Codegen.res:534](reventless/spec/src/generator/Codegen.res#L534)).

*Pro:* zero runtime coupling; deterministic; the requirement change shows up as a **reviewable diff in a committed file** — which is what makes §7's "silent deprovisioning" risk manageable; matches a convention the repo has already accepted for the harder case (whole plugin composition roots).
*Con:* new generator; needs plugin sources co-located at platform build time — which `deploy-manifest.yaml` already assumes.

*Caveat found while checking:* the `*.model.json` sidecars are gated on `REVENTLESS_EMIT_SIDECAR=1` and are already stale — 27 `@@reventless.spec` files in `online-shop-hybrid`, 26 sidecars (`ChangeProductImage.model.json`, the most recently added slice, is missing). Sidecars in their current form are a reverse-codegen artifact, not a build invariant. `capabilities.json` must be emitted by an **ungated** step of the normal plugin build, or the scan must read `.res` sources directly.

### Option C — two-pass via stack outputs

Plugin stacks export `requiredCapabilities`; the platform `StackReference`s each plugin optionally (`getOutput` → `option`).

*Pro:* no build-time coupling at all; self-healing.
*Con:* **converges one deploy late.** First introduction of a capability needs plugin deploy → platform redeploy → plugin redeploy. Unacceptable as the primary path.

### Option D — runtime discovery

Serve `config.json` from a resolver instead of a static object, reading capability registrations from the platform's own read models (plugins already register themselves and their UI fragments through the Plugin aggregate / `Platform_UIFragments`).

*Pro:* genuinely dynamic; a plugin deployed at 3pm is usable at 3:01pm.
*Con:* **solves wiring, not provisioning.** No amount of runtime registration creates an S3 bucket. Complementary, not a substitute.

### Recommendation

**B as the mechanism, C as the safety net.** Generate the platform root from the build-time union; additionally have `deployPlugin` fail fast when the platform stack's exported capability set does not cover what the plugin requires:

```
Catalog requires capability `ObjectStore` (inferred: Products.state.imageUrl → image semantic)
but platform stack `online-shop-hybrid-platform-aws/alpha` does not provide it.
Run `pnpm run generate` in platform-aws and redeploy the platform stack first.
```

That converts §2.4's ordering hazard from a silent 404 at runtime into a named, actionable deploy-time failure. D remains worth doing later for the wiring half.

---

## 6. Answering the three questions directly

**"The upload bucket — is that really necessary in `Main.res`?"**
No. It encodes one bit (*this app stores files*) in twelve lines, and in doing so it drops the framework's tagging and public-access invariants — which already costs the project a working `seed:reset` for uploaded objects (§2.3). It should be a platform-owned capability resource with per-plugin key prefixes.

**"Same for the place index?"**
Same chain, same conclusion — with one real caveat. Unlike the bucket, a place index carries genuine configuration: `dataSource` (Esri vs HERE vs Grab) and `intendedUse` (`SingleUse` vs `Storage`) are licensing and cost decisions, and `Storage` has different data-retention terms. So `Geocoding` should be provisioned automatically with the current defaults (`Esri`/`SingleUse`) and **tunable via Pulumi config**, following the `hostUiBaseDomain` precedent — config, not code. Note also that a place index has no standing charge, only per-request billing, so provisioning it on inference is cheap even if the map input is never opened.

**"Why do I write down what buckets are served?"**
You should not — it is a restatement of a framework constant (`servedPrefix = "uploads"`) that the app cannot see and nothing validates, and getting it wrong deploys green and 404s at runtime (§2.2). `servedBuckets` should leave the public API; the `ObjectStore` provider owns both ends of the prefix contract.

**"What else?"**
Today: nothing else in `Main.res` is plugin-induced — but `hostShellDist`, `assetsDir`, `bundleVersion`, and line 18 are all constants or dead code (§1), so the same cleanup removes them. Looking forward, the capability catalogue naturally grows to: `EmailDelivery` (SES identity + IAM — `SendOrderConfirmation` already declares `externalSystem = Some("EmailService")`), `SecretStore` (outbound slices calling authenticated third parties), `Vpc` (Postgres-backed query storage), `FullTextSearch`, `MediaProcessing` (thumbnailing behind the Image semantic), `WebhookIngress` (inbound translation slices). Every one of these has the same shape: **a plugin-level statement of intent whose infrastructure consequence currently has to be hand-carried into a platform file.**

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| **Silent deprovisioning.** A field rename drops the last `ObjectStore` requirement → Pulumi deletes a bucket with live objects. | Capability removal is a **generated-file diff** under Option B, so it lands in review. Additionally: provisioned capabilities carry `protect: true` / `retainOnDelete` by default, with removal requiring an explicit config opt-out — consistent with `docs/analysis/protecting-prod-infrastructure-resources.md`. |
| **Inference false positives.** `externalImageUrl: string` on a spec that never uploads → an unused bucket. | Cheap failure mode (empty bucket, unused Lambda). `@@reventless.requires.not(...)` for the explicit denial. Log every inferred capability with its provenance at deploy time. |
| **Inference false negatives.** A field named `banner` holding a storage ref. | Explicit `@@reventless.requires(ObjectStore)`. `deployPlugin`'s assertion (§5) turns the failure into a clear message rather than a runtime 404. |
| **Rules diverging from Auto UI.** The UI decides the widget; the platform decides the infra. If they drift, a widget appears with no endpoint. | Single source: core owns the semantic rules; the UI consumes them. This is the right direction of dependency anyway — the UI's inference table is currently the de-facto spec for behaviour the backend must match. |
| **Cross-plugin prefix collisions in one bucket.** | Prefix is `uploads/<plugin>/…`, assigned by the provider, with prefix-scoped IAM per plugin. |
| **Generator complexity.** `generate-platform` is new surface. | Scope it to exactly what `generate-plugin` does — read a manifest, emit a committed root. No new concepts, one new file kind. |

---

## 8. Staged adoption

Each stage stands alone and is independently shippable.

**Stage 0 — derivation only, no new concepts.** Inside `deployPlatform`: derive `servedBuckets` from the upload bucket + the presign service's own `servedPrefix`; default `assetsDir` to the resolved `@reventlessdev/reventless-host-shell` dist; default `bundleVersion` to `~version`; drop the dead Cognito line from all three example roots. `hostUiBundleConfig` keeps `enableUploads` + `uploadBucketName` but loses `servedBuckets` and the two constants.

```rescript
module Platform = ReventlessAws.Platform.Make()

let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.makeBucket(~name="online-shop-uploads")
let placeIndex = ReventlessAws.Capability_Geocoding_AwsLocation.makeIndex(~name="online-shop-geocoder")

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={geocoderPlaceIndex: placeIndex, uploadBucketName: uploadBucket},
)
```

*Fixes §2.2 and §2.3 immediately* — the helpers apply the framework's tags and PAB, which is what restores `seed:reset` coverage. Roughly 79 → 12 lines with no inference machinery at all.

**Stage 1 — capabilities as a declared list.** `deployPlatform` provisions from a named set; no Pulumi in the app.

```rescript
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~capabilities=[ObjectStore, Geocoding],
  ~hostUi=Default,
)
```

**Stage 2 — inference.** `Capability_Inference` + `capabilities.json` + `generate-platform` + the `deployPlugin` assertion. The `~capabilities` argument becomes generated, and `Main.res` joins the plugin roots as `// AUTO-GENERATED`:

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
ReventlessInfra.DeployBootstrap.run(PreDeploy)
module Platform = ReventlessAws.Platform.Make()
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~capabilities=[ObjectStore, Geocoding],  // catalog: Products.imageUrl; ordering: Customer.location
  ~hostUi=Default,
)
ReventlessInfra.DeployBootstrap.run(PostDeploy)
```

The generated comment carrying provenance is deliberate: it is what makes the diff readable when a capability appears or disappears.

**Stage 3 — catalogue growth.** `EmailDelivery`, `SecretStore`, `Vpc`, … registered through [DeployBootstrap](reventless/infra/src/components/DeployBootstrap.res) so a capability provider can ship in a satellite package without touching `reventless-aws`.

Stage 0 is worth doing regardless of whether Stages 1–3 are ever taken: it is pure derivation, it closes a live operational defect, and it removes the file's only correctness trap.

---

## 9. Related

- [docs/analysis/zero-touch-plugin-assembly.md](docs/analysis/zero-touch-plugin-assembly.md) — the same argument one level down (plugin composition root); the generator it proposes is the model Option B copies.
- [docs/analysis/protecting-prod-infrastructure-resources.md](docs/analysis/protecting-prod-infrastructure-resources.md) — the deprovisioning-risk mitigation in §7.
- [docs/guides/platform-and-plugin-guide.md](docs/guides/platform-and-plugin-guide.md) — needs a "capabilities" section once Stage 1 lands.
