# Plan: a baked component manifest for a shell deployed from its own stack

**Date:** 2026-08-19
**Status:** PROPOSED — nothing implemented.
**Repos:** `reventless-core` only.
**Builds on:** [ui-manifest-baked-emission.md](./done/ui-manifest-baked-emission.md) (the bake itself,
landed) and [done/curated-manifest-per-journey.md](./done/curated-manifest-per-journey.md)
(per-audience files).
**Same shape as:** [declared-object-stores-without-host-ui-bundle.md](./declared-object-stores-without-host-ui-bundle.md)
— a capability whose provisioning is unconditional and whose *consumers* all sit inside
`switch hostUiBundle`. That plan settled the principle this one reuses, and the one place it
does not apply is called out in [The decision](#the-decision-this-plan-turns-on).

## The gap

A platform that does not host the shell cannot bake a manifest at all, so every non-`Admin`
caller of a separately-deployed shell fails discovery.

The failure is not a refusal from the bake — it is that no bake was ever declared, no file was
ever written, and `config.json` carries no `manifestUrl`. The shell then picks the admin path
before issuing a request (by design: `RegisterFragments.staticDiscovery` chooses from the token,
so an unreachable manifest still fails loudly rather than degrading into an authorization error
at a distance), and a caller acting as a non-elevated role is told there are no surfaces
configured for their role. Which is exactly true, and exactly the state the bake exists to end.

**Where the binding is.** Four things, all deploy-side:

| Bound to `hostUiBundle` | Where |
|---|---|
| the *declaration* — `bakedManifest` is a field of `hostUiBundleConfig`, so there is no way to pass one without a bundle | [Platform.res:1471](../../reventless/aws/src/Platform.res#L1471), [types/Platform.res:420](../../reventless/infra/src/types/Platform.res#L420) |
| `manifestUrl` / `journeyManifestUrls` in `config.json` | [Platform.res:2171](../../reventless/aws/src/Platform.res#L2171) → `Util_ShellConfig.fields` |
| the bake's `s3:PutObject` grant, scoped to the resolved keys | [Platform.res:2219-2265](../../reventless/aws/src/Platform.res#L2219) |
| the `bakedManifestFunction` / `Bucket` / `Key` exports the post-deploy step reads | [Platform.res:2266-2268](../../reventless/aws/src/Platform.res#L2266) |

**What already works and needs nothing.** The handler is bucket-agnostic *by construction*: the
target travels in the invocation payload (`bakeTargetOf` reads `{bake, bucket, key}`), and the
comment at [Platform_ComponentDefinitions_Lambda_Ops.res:349](../../reventless/aws/src/adapter/Api/Platform_ComponentDefinitions_Lambda_Ops.res#L349)
says why — "the bucket only exists inside the host-UI [branch]". So the runtime half of this
plan is already built and shipped; the missing half is entirely the deploy program's, and this
plan writes no handler code.

That is worth stating plainly because it sets the size: three of the four rows above are
`Pulumi.export` and IAM, and the fourth is moving a record field.

## The decision this plan turns on

The stores plan turned on **S3 allowing exactly one bucket policy per bucket**, which is what
ruled out "export the descriptors and let each consumer wire its own grant". That constraint
does *not* bind a manifest object — one writer (the bake function), any number of readers, no
resource policy required. But it comes straight back the moment the grant is written on the
bucket's side, because [`makeUiBundleDistribution`](../../reventless/aws/src/Plugin_Stack.res)
already writes that bucket's one policy for OAC read. A second stack adding a `PutObject`
statement would silently replace the read grant, and the symptom is a shell that 404s its own
assets.

So the grant goes on the **identity** side — the platform attaches `s3:PutObject` to its own
bake role, scoped to `arn:aws:s3:::{bucket}/{key}` for each resolved key. An IAM resource ARN is
a string and need not resolve at policy-write time, so the platform may grant into a bucket a
later stack creates, and the first-deploy ordering problem does not arise.

Three options for *how the platform learns the bucket*:

1. **A stack config key** (`platform:shellBucket`). Cheapest, and invisible in the deploy
   program — a deployment that renames its shell bucket gets a bake writing where nothing
   fetches, with nothing in the diff to say so.
2. **A field on the bake declaration** (`bakedManifest.bucket`). The declaration already says
   *what* to bake and under which keys; saying where is the same sentence, it is reviewable in
   the diff, and it is absent-is-inert like every other field on that record.
3. **Export the bake role ARN and let the shell stack grant it.** Correct in principle
   (the bucket's stack owns the bucket's policy) and wrong in practice for the collision above,
   unless `makeUiBundleDistribution` grows a way to merge extra statements into the one policy
   it writes.

**Recommendation: option 2.** Option 3 is the precedent-following answer and would be right if
the grant needed a resource policy; it does not, and buying a merge parameter on
`makeUiBundleDistribution` to reach it is a larger change with a silent-failure mode at the end
of it. Option 1 is the same information with no review gate.

## Steps

### 1. Move the declaration off `hostUiBundleConfig`

`bakedManifest` becomes a parameter of `deployPlatform` / `makePlatform` in its own right, and
gains an optional `bucket`:

```rescript
~bakedManifest: bakedManifest=?   // { components, key?, journeys?, bucket? }
```

It describes *this deployment's audience*, which is a fact about the platform and not about who
serves its HTML — the same argument that moved the active-role write door out of the switch
([Platform.res:2285](../../reventless/aws/src/Platform.res#L2285)) and the object stores before
it. `bucket` unset ⇒ the host-UI bucket, exactly as today. Set ⇒ that bucket, and the platform
hosts no shell for it.

One caller to update — the hybrid example's AWS and in-memory roots — plus the field's removal
from `hostUiBundleConfig`. Nothing accepts both spellings: two ways to declare one bake is the
collision `Util_ShellConfig.fields` already fails deploys over.

**Where the name comes from, in the topology this is for.** A shell that ships from its own
stack is deployed *after* the platform and owns its bucket, so the platform cannot reference it
without a cycle — and a distribution built without `~stableName` has a generated suffix, so the
name is not derivable either. In practice the field is therefore fed from stack config, read
once out of the shell stack's own output. That is option 1's mechanism arriving through option
2's door, and it is still the better of the two: the config key is *named in the deploy program*,
where a reviewer sees which declaration consumes it, rather than being a key the program reads
and nothing mentions. Worth saying in step 4's docs, because "set this before the first
platform deploy" is otherwise learned by getting an empty menu.

### 2. Lift the grant and the exports out of the switch

Resolve the target through a pure function beside `Util_StoreLayout.servingFor`, for the reason
that one exists — so the choice is testable rather than a condition buried in `deployPlatform`,
and so "both" is not expressible:

```rescript
Util_ShellConfig.bakeTargetFor(~hasHostUiBundle, ~declaredBucket)
  : NoBake | HostShell(bucketOutput) | External(bucketName)
```

Then, outside `switch hostUiBundle`: attach the `PutObject` policy to the ComponentDefinitions
role for every key `Platform_BakedManifest.files` resolves, and export
`bakedManifestFunction` / `bakedManifestBucket` / `bakedManifestKey` from all three arms rather
than one. `NoBake` exports nothing, as today.

Add `bakedManifestKeys` (every file, default first) beside the singular `Key`. The invocation
already writes every journey from one call and reports them in its response, so this is for the
post-deploy step to *verify* against rather than to iterate — a journey silently absent from the
bake is a role with an empty menu and no error anywhere.

### 3. Export the URLs, do not make a second stack derive them

A shell deployed from its own stack still has to write `manifestUrl` and `journeyManifestUrls`
into its own `config.json`. Export them, computed by the same `Platform_BakedManifest.urlForKey`
/ `journeyUrls` the grant and the bake use:

```
bakedManifestUrls : { manifestUrl: "/component-manifest.json",
                      journeyManifestUrls: { "Fulfilment": "/component-manifest-fulfilment.json" } }
```

so a consumer merges the object verbatim. This is the stores plan's lesson restated: *a key
derived twice is a shop whose file is written where nothing fetches it, and the symptom is an
empty menu rather than a missing file.* The URLs stay root-relative, which is what makes the
external-bucket topology work without CORS at all — the shell fetches its manifest from its own
origin, because that origin is where the bake wrote it.

Under `HostShell` the export is redundant with `config.json` and written anyway: one shape for a
consumer to read rather than two.

### 4. Document the topology

The choice between "platform hosts the shell" and "shell ships from its own stack" now has a
consequence for discovery, next to the one it already has for stores. Record in
[host-ui-shell-config-choices.md](./host-ui-shell-config-choices.md) which side writes which key
in each case, and that a shell stack must not derive manifest URLs itself.

## Verification

- A platform declaring no bake exports nothing new and previews byte-identical.
- A platform with `~hostUiBundle` and a bake previews byte-identical to before this plan —
  the path that works today must not move.
- A platform with a bake and `bucket` set, and no bundle: `pulumi up` creates the role policy
  and the three (now four) exports; invoking the function with the exported bucket/key writes
  every file `bakedManifestKeys` names; a `GET` of each URL from the shell's origin returns the
  curated JSON; a caller acting as a declared journey's group gets that journey's menu, and one
  acting as an undeclared role gets the default.
- Core's unit tests do not run in the default suite — judge this with
  `jest --selectProjects reventless-aws` and `--selectProjects reventless-core`.

## What this deliberately does not do

- **No live manifest query for non-admin callers.** Same non-goal as the plan that landed the
  bake; nothing here reopens it.
- **No change to the handler.** The payload contract already carries the target.
- **No second distribution.** Unlike stores, a manifest has no serving problem to solve: it is
  fetched from the shell's own origin by the shell that was pointed at it.
- **No config.json assembly for external stacks.** Writing the endpoint/auth keys from another
  stack's outputs is a separate and larger seam; this plan exports two keys, not a file.

## Risks

| Risk | Mitigation |
|---|---|
| A declared `bucket` that names nothing (typo, renamed bucket) produces a grant into a void and a bake that fails at invocation — the platform deploy stays green. | The bake job fails loudly on `FunctionError`, which is where the wrong name surfaces. Nothing at deploy time can check a bucket in another stack, and inventing a lookup would couple the platform to a stack it must not need. |
| Moving `bakedManifest` off `hostUiBundleConfig` is a breaking signature change. | One caller in this repo; the field is alpha and the compiler finds every use. |
| A grant is written for keys the bake does not produce (or the reverse) if the key set is resolved twice. | Both sides already read `Platform_BakedManifest.files`; step 3 puts the URLs on the same footing. |
| An external shell writes `manifestUrl` but its bucket is never baked into (bake job absent from that deployment's CI), leaving a set `manifestUrl` that 404s. | Deliberately fails loudly rather than falling back — the contract `done/ui-manifest-baked-emission.md` §4 chose. Call it out in step 4's docs: pointing a shell at a manifest and never baking it is a worse state than not pointing it. |
