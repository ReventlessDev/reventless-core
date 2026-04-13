# Plan: AppSync Resolver via `@pulumi/aws-native`

## Summary

Replace `aws.appsync.Resolver` (Pulumi classic provider, Terraform-bridged)
with `aws-native.appsync.Resolver` (Pulumi native Cloud Control provider) only
for the AppSync resolver resources we create in `QueryDbResolvers_AppSync.res`.
Keep everything else on `@pulumi/aws`.

The hypothesis is that the AWS CloudFormation handler for
`AWS::AppSync::Resolver` (which Cloud Control wraps) internally handles the
schema → resolver propagation race that currently causes deploys to fail
with `NotFoundException: No field named X found on type Query`. If this
hypothesis holds, no custom retry logic is needed; AWS orchestrates the
wait server-side.

**Source analysis:** `private-consumer-repo/docs/analysis/appsync-resolver-creation-race.md`
(Option F).

**Alternative plan (Option C — custom dynamic resource with client-side
retry-on-404):** considered and discarded after Phase 1 passed empirically.
The standalone plan file was deleted; the design notes still live in the
analysis doc's "Option C" section if the fallback ever needs to be
revisited.

Phase 1 of this plan was a **smoke test** that decided between Option F and
Option C empirically. The smoke test passed (see Phase 1 status below), so
Option F was adopted.

---

## Prerequisites

- `@pulumi/aws-native` dependency added to `@reventlessdev/rescript-pulumi-aws`
  (or a sibling `rescript-pulumi-aws-native` package).
- Pulumi provider credentials configured for both `aws` and `aws-native`.

---

## Phase 1 — Smoke test ✅ PASSED (2026-04-13)

All 25 operations clean (5 up + 5 destroy per region × 2 regions). No
`NotFoundException: No field named` across `eu-west-1` or `us-east-1`.
Option F adopted. See the Option F risk-assessment section of
`private-consumer-repo/docs/analysis/appsync-resolver-creation-race.md` for
the empirical record. Proceeding to Phase 2.


### 1.1 Build a minimal test stack

**Location:** `reventless-aws/scratch/appsync-resolver-aws-native-smoke/`
*(new, not committed long-term)*

Pulumi program that:

1. Creates an AppSync GraphQL API (via `@pulumi/aws` — unchanged).
2. Pushes an initial SDL with 3 base query fields (via the existing
   `AppSync_Adapter.updateSchema` path, with the `waitForSchemaActive`
   post-`ACTIVE` sleep **set to 0**).
3. Immediately after schema `ACTIVE`, creates 5 resolvers via
   `aws-native.appsync.Resolver` for 5 **newly-added** fields in that SDL.

If steps 2–3 succeed without `NotFoundException`, Option F is viable.

### 1.2 Smoke-test criteria

Run 5× in each of two regions (`eu-west-1` and `us-east-1` — different
control-plane shards). Success: all 25 runs succeed with `sleep=0`.

- **All pass:** adopt Option F. Proceed to Phase 2.
- **Any fail in the same `NoFieldNamed` pattern we see today:** abandon
  Option F. Implement Option C instead. Delete the smoke-test directory.

### 1.3 Document findings

Write a one-paragraph summary of the smoke-test outcome into the analysis
doc (`appsync-resolver-creation-race.md`, Option F risk-assessment section).
Future readers will want empirical evidence for the decision.

---

## Phase 2 — ReScript bindings for `aws-native.appsync` ✅ DONE


### 2.1 Add binding package

Decision: add `@pulumi/aws-native` as a peer dependency of
`@reventlessdev/rescript-pulumi-aws` and colocate the new bindings in a
`src/AwsNative/` subdirectory, or create a new sibling package
`rescript-pulumi-aws-native`.

**Recommendation:** colocate inside `rescript-pulumi-aws`. Bindings are
small (1–2 resources), a sibling package adds versioning overhead out of
proportion to the scope. If future resources pile up we can extract later.

### 2.2 Binding module

**File:** `rescript-pulumi-aws/src/AwsNative/AppSync/AwsNative_AppSync_Resolver.res`
*(new)*

Minimal bindings for `aws-native.appsync.Resolver`:

```rescript
// Wraps new aws_native.appsync.Resolver(name, args, opts)
type t

type resolverArgs = {
  ApiId: Pulumi.Input.t<string>,
  TypeName: Pulumi.Input.t<string>,
  FieldName: Pulumi.Input.t<string>,
  DataSourceName?: Pulumi.Input.t<string>,
  Kind?: Pulumi.Input.t<string>,  // "UNIT" | "PIPELINE"
  Code?: Pulumi.Input.t<string>,
  Runtime?: Pulumi.Input.t<runtimeConfig>,
  PipelineConfig?: Pulumi.Input.t<pipelineConfig>,
  // ... other fields as needed
}

@module("@pulumi/aws-native") @new @scope("appsync")
external make: (
  ~name: string,
  ~args: resolverArgs,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => t = "Resolver"
```

### 2.3 Adapter preserving current call shape

**File:** `reventless-aws/src/adapter/Api/AppSync_Resolver_Native.res`
*(new)*

Adapter exposing the same `makeUnitJsResolver` / `makePipelineJsResolver`
interface as the classic `PulumiAws.AppSync.Resolver` module, so
`QueryDbResolvers_AppSync.res` can switch imports without changing any
call sites.

Functions map camelCase ReScript labels → PascalCase Cloud Control fields:
- `~type_` → `TypeName`
- `~field` → `FieldName`
- `~dataSourceName` → `DataSourceName`
- `~code` → `Code` + `Runtime: { Name: "APPSYNC_JS", RuntimeVersion: "1.0.0" }`

### 2.4 Pipeline resolver support

Pipeline resolvers use `PipelineConfig: { Functions: [functionArns...] }`
instead of an inline `functions: [...]` array of `Function` resources.

Two options:
- **2.4a:** also migrate `AppSync.Function` to `aws-native.appsync.FunctionConfiguration`
  for symmetry.
- **2.4b:** keep `AppSync.Function` on classic `aws`, extract `.functionId`
  outputs, pass them into the native `PipelineConfig.Functions` array.

**Recommendation:** 2.4b. AppSync Functions don't reference schema field
names at create time, so they don't hit the race. Migrating them adds
surface area for no benefit. Mixing providers at the Function → Resolver
boundary is supported.

---

## Phase 3 — Wire into `QueryDbResolvers_AppSync` ✅ DONE

Section 3.3 (post-`ACTIVE` sleep) is a no-op — the current
`AppSync_Adapter.res` doesn't have an explicit sleep to remove.


### 3.1 Switch imports

**File:** `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`

Change:
```rescript
open PulumiAws.AppSync  // Resolver from classic provider
```
to:
```rescript
module Resolver = AppSync_Resolver_Native  // Resolver from aws-native
open PulumiAws.AppSync  // still used for Function, DataSource
```

All existing `Resolver.makeUnitJsResolver` / `Resolver.makePipelineJsResolver`
call sites continue to compile unchanged.

### 3.2 `opts` differences

`aws-native` does not support `deleteBeforeReplace: true` on Cloud Control
resources — the Cloud Control API decides ordering internally.

**Action:** audit `QueryDbResolvers_AppSync.res` and any caller for
`deleteBeforeReplace` on resolver resources. If present, remove when
migrating to native. Capture in the migration commit with a note in the
changeset explaining Cloud Control's own ordering semantics.

### 3.3 Remove the post-`ACTIVE` sleep (conditional)

**File:** `reventless-aws/src/components/Api/AppSync_Adapter.res`

If Phase 1 smoke test passed with `sleep = 0`, the sleep is no longer
needed. Either:

- **3.3a:** Remove the sleep entirely when the native resource ships.
- **3.3b:** Keep a shortened sleep (e.g. 5 s) for one release cycle as a
  safety net while we watch production deploys.

**Recommendation:** 3.3b. Low cost, catches edge cases where the CFN
handler's internal wait has a hole we didn't spot in the smoke test.
Remove in the next release.

---

## Phase 4 — State migration ✅ DECIDED — forced replace, no aliases

User opted for the forced-replace strategy (Section 4.3 fallback). No
alias wiring needed; first deploy after the migration will delete each
existing `aws:appsync/resolver:Resolver` and create a new
`aws-native:appsync:Resolver` in its place. Resolvers are stateless;
in-flight queries against affected fields fail for a few seconds during
the gap. No data loss.

Sections 4.2 (alias adoption) and 4.4 (cautious one-stack-at-a-time
rollout to validate aliases) are therefore skipped — but operators may
still prefer to roll one stack first to validate the replace cycle in
practice.


### 4.1 Resource-type change

Switching `aws:appsync/resolver:Resolver` → `aws-native:appsync:Resolver`
changes the Pulumi resource type. Pulumi will want to delete each
existing resolver and recreate it as the new type. Between delete and
recreate, the field has no resolver and queries against it fail.

### 4.2 Use aliases to adopt existing resources

Add `aliases` to the new native resource so Pulumi re-adopts the
existing state entry:

```rescript
~opts={
  ...baseOpts,
  aliases: [
    Pulumi.Alias.make(
      ~type_="aws:appsync/resolver:Resolver",
      ~name=resolverName,
      (),
    ),
  ],
}
```

Verify via `pulumi preview` that the resources show as unchanged (or at
worst, `update` with no-op diff) rather than `replace`. If `preview`
still says `replace`, investigate the property shape mismatch between
classic and native — often a casing or enum-default difference.

### 4.3 Stateful-resource risk: none

Resolvers are stateless configuration. A recreate causes brief query
failures but no data loss. The alias path avoids even that risk, but
even the fallback (no alias, forced recreate) is tolerable for
resolvers.

### 4.4 Rollout order

Deploy one plugin stack at a time. Watch the first one end-to-end. If
aliases work, the remaining stacks are trivial.

---

## Phase 5 — Documentation ✅ DONE

- Architecture + runbook (merged): [`docs/guides/dual-aws-provider.md`](../guides/dual-aws-provider.md)
- Release notes: this monorepo uses semantic-release / conventional commits
  (no `.changeset/`) — the `feat(api):` commit message that lands these
  changes carries the changelog entry. Suggested subject:
  *`feat(api): use aws-native AppSync Resolver to fix schema propagation race`*
  Body should mention: forced-replace cycle on first deploy; resolver
  outage of a few seconds per field; runbook link.


### 5.1 Runbook

**File:** merged into [`docs/guides/dual-aws-provider.md`](../guides/dual-aws-provider.md) — see "What to do if the race resurfaces" section.

Short entry describing:

- The schema → resolver propagation race (one paragraph, link to analysis).
- How we solve it by using `aws-native.appsync.Resolver` whose CFN
  handler internally waits for resolver-creatability.
- What to do if it does fail (escalation: file an issue, temporarily
  reinstate the post-`ACTIVE` sleep in `AppSync_Adapter.res`).

### 5.2 Release notes

Changeset entry:
- Calls out that resolvers now use `@pulumi/aws-native`.
- Notes the alias migration is automatic — no user action on first deploy.
- Lists any `deleteBeforeReplace` semantics removed (Section 3.2).

### 5.3 Architecture note

Record the dual-provider pattern somewhere discoverable (e.g. a short
section in `docs/` explaining when we use `aws-native` vs `aws`). Matches
Pulumi's official "aws as backbone, aws-native as needed" guidance —
readers should understand we are following the recommended pattern, not
accidentally mixing providers.

---

## Phase 6 — Rollout and monitoring

### 6.1 Ship behind existing sleep safety net

Ship Phases 1–5 in one release. Keep the shortened post-`ACTIVE` sleep
(3.3b) for the first release cycle.

### 6.2 Monitor

Watch CI and manual deploys for one release cycle. Success criteria:

- Zero `NotFoundException: No field named` failures across all stacks.
- Resolver create latency is acceptable (expect Cloud Control ops to be
  5–15 s slower per resolver; cumulative impact over 12–20 resolvers
  per stack is 1–3 min of extra deploy time).

### 6.3 Remove the sleep

After one release cycle of clean deploys, remove the sleep entirely
(3.3a).

### 6.4 Capture aws-native provider version

Pin `@pulumi/aws-native` version in the `rescript-pulumi-aws` package.json.
A silent major-version update on our side would be risky.

---

## Out of scope

- AppSync `Function` resources (Phase 2.4). They don't hit the race.
- Non-AppSync resources. Stay on `@pulumi/aws`.
- Wholesale migration to `aws-native`. Explicitly not recommended by
  Pulumi; see the "Wider context" section in the analysis doc.
- Retry-on-404 custom logic. If this plan succeeds, custom retry is
  unnecessary. If it fails, fall back to plan C.

---

## Risks

### Smoke test fails

The whole premise of Option F is that the CFN handler for
`AWS::AppSync::Resolver` internally handles the propagation race. That
is inferred from CloudFormation's track record and the absence of open
issues, not from an explicit AWS statement.

Mitigation: Phase 1 is explicitly the test gate. Abandoning Option F
after a failed smoke test costs one day of binding work that isn't
reusable. Accept that cost; it's cheaper than committing to Option F
and debugging production deploys later.

### Slower deploys

Cloud Control resources are noticeably slower than direct SDK calls.
Typical overhead per resource is 5–15 s. Across 12–20 resolvers per
plugin stack this is 1–3 min of additional deploy time.

Mitigation: accept the tradeoff. Deploy reliability beats deploy speed.
If latency becomes painful we can parallelise resolver creation more
aggressively (Cloud Control supports concurrent requests).

### Dual-provider complexity

Two AWS providers in one program is supported but uncommon. New
contributors must understand which provider is used for what and why.

Mitigation: documented in Phase 5.3 and in the runbook. The scope
(`appsync.Resolver` only) is narrow enough to memorise.

### Pulumi `aws-native` versioning instability

As a newer provider, `aws-native` has had more breaking changes in its
schema than classic `aws`. A minor-version bump could change the
`resolverArgs` shape.

Mitigation: pin the version (Phase 6.4). Upgrade deliberately, with
`pulumi preview` verification before committing the bump.

### Alias path breaks

If `preview` still says `replace` after adding the alias, we either
accept brief resolver downtime on first deploy, or block the rollout
and investigate.

Mitigation: first rollout is a single plugin stack (Phase 4.4) so we
catch this before propagating.

---

## Decision criteria — when to pick this plan vs the retry plan

| Signal | Pick this plan (Option F) | Pick the retry plan (Option C) |
|---|---|---|
| Phase 1 smoke test passes | ✓ | — |
| Phase 1 smoke test fails | — | ✓ |
| Team prefers leaning on AWS-managed infrastructure | ✓ | — |
| Team prefers owning the solution in code | — | ✓ |
| Deploy latency is already a pain point | — | ✓ |
| Concerned about dual-provider complexity | — | ✓ |

The plans are mutually exclusive. Do not implement both.

---

## File Changes Summary

| File | Action |
|------|--------|
| `reventless-aws/scratch/appsync-resolver-aws-native-smoke/` | ~~New (Phase 1, disposable)~~ — deleted after Phase 1 passed |
| `rescript-pulumi-aws/src/AwsNative/AppSync/AwsNative_AppSync_Resolver.res` | New |
| `rescript-pulumi-aws/package.json` | Add `@pulumi/aws-native` peer dep |
| `reventless-aws/src/adapter/Api/AppSync_Resolver_Native.res` | New |
| `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | Updated — swap Resolver module, add aliases |
| `reventless-aws/src/components/Api/AppSync_Adapter.res` | Updated — shorten then remove sleep |
| `docs/guides/dual-aws-provider.md` | New — merged architecture note + runbook |
| `.changeset/` | New — release note |

---

## References

- Business-repo analysis (Option F): `private-consumer-repo/docs/analysis/appsync-resolver-creation-race.md`
- Alternative (Option C): see "Option C" section in the analysis doc
  above. Standalone plan file removed after Option F was adopted.
- [`pulumi-aws-native` README — "aws as primary, aws-native as needed"](https://github.com/pulumi/pulumi-aws-native)
- [AWS Cloud Control Provider GA announcement (Pulumi)](https://www.pulumi.com/blog/pulumi-aws-cloudcontrol-provider/)
- [`AWS::AppSync::Resolver` CloudFormation handler](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-appsync-resolver.html)
- [`aws-native.appsync.Resolver` — Pulumi Registry](https://www.pulumi.com/registry/packages/aws-native/api-docs/appsync/resolver/)
