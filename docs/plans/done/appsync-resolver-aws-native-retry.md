# Plan: Retry-on-404 Wrapper Around `aws-native.appsync.Resolver`

## Summary

`aws-native.appsync.Resolver` is already wired into `QueryDbResolvers_AppSync.res`
via `AppSync_Resolver_Native.res` (Option F is implemented). However, the
production `platform-inspector-aws` deploy revealed that the CFN handler
behind `aws-native` does **not** internally wait for AppSync's resolver
control plane to catch up after a schema push — `CreateResolver` returns
`NotFoundException: No field named X found on type Query` with `SDK Attempt
Count: 1` on every fail, and the stack only converges after multiple
sequential `pulumi up` invocations.

This plan adds a **retry-on-404 wrapper** around the existing
`aws-native.appsync.Resolver` call site, so create/update operations that
hit the propagation race are transparently retried with exponential
backoff. This is Option C from
a downstream consumer analysis (`analysis/appsync-resolver-creation-race.md`),
specialised for the case where we already have the native resource in
place — we wrap the resource construction in a Pulumi `ComponentResource`
that handles retry, instead of writing a full custom dynamic provider.

**Source analysis:** a downstream consumer analysis (`analysis/appsync-resolver-creation-race.md`)
(Option C, narrowed by Option F's failure record).

**Alternative plan:** `docs/plans/appsync-resolver-retry-dynamic.md`
(full custom dynamic provider — more code, more control, but unnecessary
now that we already own the `AppSync_Resolver_Native` adapter).

**Companion plan:** `docs/plans/appsync-schema-push-dedup.md` —
content-hash-based skip of `StartSchemaCreation` when the SDL is
unchanged. The retry wrapper handles the race when a real schema delta
triggers it; dedup ensures no-op deploys don't trigger the race at all.
Both are needed for the full fix; either alone is insufficient.

---

## Approach

There are two viable retry shapes given that the native resource already
exists:

### Approach A — Pre-flight introspection check before constructing the resource

Before calling `new aws_native.appsync.Resolver(...)`, issue a GraphQL
introspection query against the API endpoint (IAM-signed, same as
`Util_AppSync_Caller.sendMutation`) checking that the target field exists
on the target type. Retry the introspection with backoff until the field
is visible, then construct the Pulumi resource.

**Pros:** Pulumi resource itself is unchanged — we just delay its
construction until the schema is genuinely queryable. Failure modes stay
inside our control.

**Cons:** Introspection reads from the schema document store, which (per
the analysis) **lags less** than `CreateResolver` validation but still
not perfectly aligned with it. Empirically we need to verify the gap is
small or zero. If introspection is also stale relative to
`CreateResolver`, this approach fails the same way.

### Approach B — Custom dynamic provider wrapping the SDK call

Skip `aws-native.appsync.Resolver` entirely; bring back the
custom-dynamic-provider design from
`docs/plans/appsync-resolver-retry-dynamic.md`. We own all
create/update/delete/diff/read paths and wrap `CreateResolver` /
`UpdateResolver` in a retry loop that catches `NotFoundException: No
field named …` directly.

**Pros:** Solves the race definitively. Same call we want to retry is
the call we directly wrap. No extra moving parts (no introspection
side-channel).

**Cons:** Larger surface area than Approach A. Also: makes
`AppSync_Resolver_Native` redundant unless we want both as fallbacks.

### Decision: Approach B

The introspection approach (A) trades one race for another and we have
no production signal that it actually closes the window.
[Approach B] is the path the original retry plan
(`docs/plans/appsync-resolver-retry-dynamic.md`) describes in full —
this plan focuses on the **adjustments** needed because the
`@pulumi/aws-native` work has already landed.

---

## What changes vs the original retry plan

The original retry plan
(`docs/plans/appsync-resolver-retry-dynamic.md`) assumed we would
replace `aws.appsync.Resolver` (classic) with a custom dynamic resource.
With Option F now in production, we instead replace
`aws-native.appsync.Resolver` with the custom dynamic resource:

1. **Same dynamic provider implementation** as the original plan
   (`AppSync_Resolver_Retrying.res` with create/update/delete/diff/read).
2. **Migration path is different.** Resources are currently in state as
   `aws-native:appsync/resolver:Resolver`, not
   `aws:appsync/resolver:Resolver`. The Pulumi `aliases` field must
   reference the **native** type:
   ```rescript
   aliases: [
     Pulumi.Alias.make(~type_="aws-native:appsync/resolver:Resolver", ~name=resolverName, ()),
   ],
   ```
3. **Cleanup:** once the dynamic resource is shipping cleanly, we can
   either keep `AppSync_Resolver_Native.res` as dead code (cheap, may be
   useful for non-`Resolver` Cloud Control resources later) or delete
   it. Recommend keeping the bindings file but removing it from the
   import path of `QueryDbResolvers_AppSync.res`.
4. **Keep `@pulumi/aws-native` dependency.** Even after the dynamic
   resource lands, the Cloud Control provider may be the right tool for
   future resources. Pulumi's official guidance is to use both
   providers; we follow it.

---

## Phase 1 — Implement the dynamic resource

Identical to Phases 1–2 of `docs/plans/appsync-resolver-retry-dynamic.md`.
Summary:

- New file `reventless-aws/src/adapter/Api/AppSync_Resolver_Retrying.res`
  with a Pulumi dynamic provider implementing create/update/delete/diff/read.
- Error classifier helper `isFieldNotFoundError` (returns `true` only
  for `NotFoundException` with message containing `No field named` —
  must NOT match the delete-path "No resolver found" 404).
- Retry loop hand-rolled in ReScript (see "Serialisation constraints"
  below for why `rescript-effect` cannot be used). Exponential backoff
  starting at 2 s, doubling each attempt, capped at **30 s per delay**.
  Up to **6 attempts**, total budget ~2 min.

  The retry is a **backstop**, not the primary fix. The primary fix is
  schema-push deduplication (see `docs/plans/appsync-schema-push-dedup.md`):
  skipping `StartSchemaCreation` when the SDL is unchanged avoids
  restarting the propagation clock on no-op deploys, which is what
  turns the race from invisible into visible. With dedup in place, the
  retry rarely fires; 2 min covers the genuine-delta case where a new
  field or plugin is added. Widening the cap is a tuning decision if
  we ever see larger single-deploy deltas than 2 min of propagation.

  **Do not rely on the retry budget as the mechanism that makes
  deploys pass.** The retry absorbs small propagation lag; dedup
  prevents the lag from happening in the first place for most
  deploys.
- Pulumi dynamic-provider scaffolding: minimal bindings in
  `rescript-pulumi-aws/src/Pulumi_Dynamic.res` (or inline).
- Provider object must be **pure** — no closures over Pulumi `Output`
  values. All state flows through `inputs` / `olds` / `news`.

### 1.1 Serialisation constraints (learned during implementation)

Pulumi serialises the dynamic provider object — and its **entire closure
of captured references** — into stack state. Any module the provider
transitively imports is walked by the serialiser. Two concrete rules
followed from this:

1. **No `rescript-effect` / `Effect` / `Schedule` inside the provider
   closure.** Effect's runtime state (fibers, schedulers, internal
   refs) fails `serializeFunction` with
   `Error serializing '() => provider'`. The retry loop must be
   hand-rolled plain ReScript using `setTimeout` + recursion.

2. **No static `@module("@aws-sdk/client-appsync") @new` bindings.**
   The SDK's CJS/ESM dual exports trip Pulumi's path resolution and
   produce runtime errors like
   `Cannot find module '@aws-sdk/client-appsync/node_modules/@aws-sdk/region-config-resolver/dist-cjs/index.js'`.
   Import the SDK **lazily** via `@val external dynImport: string => promise<'a> = "import"`
   and cache the resolved module in a module-level ref on first use.
   The provider methods then read the cached SDK inside their `async`
   body — the static module reference is never captured in the
   closure.

3. **No `@module("@pulumi/pulumi/dynamic") @new external`.** The bare
   directory import is not ESM-resolvable. Use the explicit
   `@module("@pulumi/pulumi/dynamic/index.js") @new` form instead.

4. **Keep helpful logging in the retry loop.** The
   `[AppSync_Resolver_Retrying] retry N/M after Xms: ...` and
   `giving up after N attempts: ...` log lines are the only way to
   diagnose propagation behaviour in the wild. Do not remove them
   after launch.

---

## Phase 2 — Wire into `QueryDbResolvers_AppSync`

### 2.1 Switch imports

**File:** `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`

Currently:
```rescript
module Resolver = AppSync_Resolver_Native
```

Change to:
```rescript
module Resolver = AppSync_Resolver_Retrying
```

The `AppSync_Resolver_Retrying` module exposes the same
`makeUnitJsResolver` and `makePipelineJsResolver` signatures as
`AppSync_Resolver_Native` so call sites are unchanged.

### 2.2 Other resolver creation sites

`QueryDbResolvers_AppSync` is **not** the only place resolvers are
created. Other sites hit the same race and must be migrated in the
same pass:

- `reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res`
  (aggregate mutations + DCB StateChangeSlice mutations)
- `reventless-aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res`
  (inbound translation mutations)
- `reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res`
  (admin Clone mutation)

All four files currently call `PulumiAws.AppSync.Resolver.makeUnitJsResolver`
(or the classic `AppSync.Resolver.*`). Replace every such call with
`AppSync_Resolver_Retrying.makeUnitJsResolver`.

Downstream code calls `Util_AppSync.toResource` to convert the
classic-resource result into `ReventlessInfra.Adapter.resource`.
`AppSync_Resolver_Retrying`'s output type is
`PulumiAws.AwsNative.AppSync.Resolver.t` (aliased), so the downstream
call must change to `Util_AppSync.toResourceNative`.

### 2.3 Pipeline resolver Functions

`AppSync.Function` resources are currently still created via the classic
`@pulumi/aws` provider (Option F kept them there because they don't
reference field names at create time). Decision for this plan: keep
that arrangement. The retry logic is only needed for `Resolver`.

If we ever see `Function` resources fail with the same race, extend
`AppSync_Resolver_Retrying` to cover them — for now they are out of
scope.

---

## Phase 3 — State migration

### 3.1 Resource-type change

Switching `aws-native:appsync/resolver:Resolver` →
`pulumi-nodejs:dynamic:Resource` (the type Pulumi uses for dynamic
resources) changes the resource type in state. Same situation as Option F's
classic → native migration.

### 3.2 Aliases against the native type

Add `aliases` to the new dynamic resource pointing at the **native**
type:

```rescript
~opts={
  ...baseOpts,
  aliases: [
    Pulumi.Alias.make(
      ~type_="aws-native:appsync/resolver:Resolver",
      ~name=resolverName,
      (),
    ),
  ],
}
```

Verify via `pulumi preview` that resources show as `update` (no-op) or
unchanged rather than `replace + create`. If `replace`, investigate
input-shape mismatch: the dynamic resource's input record must accept
the same property names the native resource accepted.

### 3.3 Stateful-resource risk: none

Same as the previous migration — resolvers are stateless config; a
recreate causes brief query failures (a few seconds) but no data loss.
Aliases avoid even that brief failure window.

### 3.4 Rollout order

Deploy one plugin stack first (recommend `platform-inspector-aws`
since that's where the race was reproducible). Watch end-to-end. If
aliases work, the remaining stacks are trivial.

---

## Phase 4 — Tests

Same as Phase 3 of the original retry plan:

### 4.1 Unit test for `isFieldNotFoundError`

**File:** `reventless-aws/tests/AppSync_Resolver_RetryingTest.res` *(new)*

Cover the classifier:
- `true` for `{ name: "NotFoundException", message: "No field named Foo found on type Query" }`.
- `false` for `{ name: "NotFoundException", message: "No resolver found" }` (delete-path; must not retry on that one).
- `false` for `{ name: "ThrottlingException", message: ... }`.
- `false` for non-exception values.

### 4.2 Integration test

Defer. Manual validation against `platform-inspector-aws` is sufficient
because that stack reproduces the race reliably.

---

## Phase 5 — Documentation

### 5.1 Update the dual-provider guide

**File:** `reventless-aws/docs/guides/dual-aws-provider.md` (created in
Option F, Phase 5).

Add a section explaining the relationship between
`AppSync_Resolver_Native` and `AppSync_Resolver_Retrying`:

- `AppSync_Resolver_Native` is the thin wrapper around
  `aws-native.appsync.Resolver`. Kept as bindings even though
  `QueryDbResolvers_AppSync` no longer uses it.
- `AppSync_Resolver_Retrying` is what `QueryDbResolvers_AppSync` uses
  in production — a custom dynamic provider that calls
  `@aws-sdk/client-appsync` directly and retries on the AppSync
  schema-propagation race.
- Use `Native` only if you need a Cloud Control-managed resource for
  some future reason (e.g. CFN-style ordering); use `Retrying` for
  every resolver derived from a recently-pushed schema field.

### 5.2 Runbook update

In the same guide, update the "What to do if the race resurfaces"
section: previously the recommendation was "try a manual
`pulumi up` retry"; now the dynamic resource handles retries
internally. The runbook entry shrinks to "investigate logs in the
`AppSync_Resolver_Retrying` provider — the retry envelope logs each
attempt".

### 5.3 Update the analysis doc

**File (business repo):** `docs/analysis/appsync-resolver-creation-race.md`

Add a closing entry to the Option C section noting that it was
implemented after Option F's production failure, with a link to this
plan and a date.

### 5.4 Release notes

Conventional commit subject for the landing commit:

```
fix(aws): retry AppSync CreateResolver on schema-propagation 404s
```

Body should mention:
- Replaces `aws-native.appsync.Resolver` with a custom dynamic
  resource that retries `NotFoundException: No field named` with
  exponential backoff (capped at 3 min).
- Aliased migration — no recreate on first deploy.
- `aws-native` remains a peer dep; the bindings (`AppSync_Resolver_Native`)
  are kept for future use but no longer in the resolver creation path.

---

## Phase 6 — Rollout and monitoring

### 6.1 Ship Phases 1–5 in one release

### 6.2 Monitor

Watch CI and manual deploys for one release cycle. Success criteria:

- Zero `NotFoundException: No field named` failures escaping the retry
  envelope (i.e. failing after the 3-min cap).
- Per-resolver retry counts visible in logs — typical run should show
  zero retries on a stable schema, 1–4 retries on a fresh schema push.
- Deploy time is comparable to (or faster than) Option F: with retries
  absorbed, no manual `pulumi up` re-runs needed.

### 6.3 Acceptance: zero manual retries

The success bar is one clean `pulumi up` for any deploy that previously
required 6 sequential runs to converge. If we hit that bar across two
weeks of normal deploys, the race is closed.

---

## Out of scope

- AppSync `Function` resources. Still on classic `@pulumi/aws`. Extend
  the retry wrapper if they ever start failing.
- Removing `@pulumi/aws-native`. We keep it as a peer dep for future
  Cloud Control needs.
- Schema-push deduplication. The current schema push fires unconditionally
  on every `pulumi up`, which restarts the propagation clock. Adding a
  content-hash check to skip no-op pushes is a separate optimisation,
  beneficial alongside this plan but not blocked by it.

---

## Risks

### Dynamic provider serialisation pitfalls

Pulumi serialises the provider object into stack state. Closures over
non-serialisable values (Pulumi `Output`, class instances, etc.)
silently break. Mitigation: keep the provider pure — all state through
`inputs`/`olds`/`news`.

### Aliases path doesn't cleanly migrate from native

The native → dynamic migration is less common than classic → dynamic.
If `pulumi preview` after applying aliases still shows `replace`
instead of `update`, we may need to inspect the actual property shape
generated by the native provider vs what our dynamic provider stores.

Mitigation: Phase 3.4 rolls out one stack first to catch this.

### Retry doesn't fire at all (closure / serialisation bug)

If the retry loop is somehow eliminated (e.g. provider serialisation
strips the `Effect` chain), failures will look identical to today's.

Mitigation: the unit test covers the classifier directly, but does
**not** cover the retry loop's actual execution. Mitigate via a manual
deploy of `platform-inspector-aws` (which reproduces the race) before
declaring the rollout successful.

### CFN handler / Cloud Control quirks resurface elsewhere

The `aws-native` resource is being removed from the resolver path, but
is still in our dependency surface (kept for future use). If we
introduce other `aws-native` resources later, they may exhibit similar
issues that this plan does not address.

Mitigation: documented in the dual-provider guide so future authors
know to evaluate retry needs per-resource.

---

## File Changes Summary

| File | Action |
|------|--------|
| `reventless-aws/src/adapter/Api/AppSync_Resolver_Retrying.res` | New |
| `rescript-pulumi-aws/src/Pulumi_Dynamic.res` (or inline) | New — minimal bindings for `pulumi.dynamic` |
| `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | Updated — swap `Resolver` module from `Native` to `Retrying`, add aliases |
| `reventless-aws/src/adapter/Api/AppSync_Resolver_Native.res` | Untouched — kept as bindings |
| `reventless-aws/tests/AppSync_Resolver_RetryingTest.res` | New — unit tests for error classifier |
| `reventless-aws/docs/guides/dual-aws-provider.md` | Updated — Native vs Retrying, runbook |
| a downstream consumer analysis (`analysis/appsync-resolver-creation-race.md`) | Updated — Option C closing entry |

---

## References

- Source analysis (Option C, narrowed by Option F's failure):
  a downstream consumer analysis (`analysis/appsync-resolver-creation-race.md`)
- Original full retry plan: `docs/plans/appsync-resolver-retry-dynamic.md`
  (use as the implementation template for `AppSync_Resolver_Retrying`)
- Option F plan & implementation: `docs/plans/appsync-resolver-aws-native.md`
- terraform-provider-aws [`retryResolverOp`](https://github.com/hashicorp/terraform-provider-aws/blob/main/internal/service/appsync/resolver.go)
- [Pulumi Dynamic Providers docs](https://www.pulumi.com/docs/concepts/resources/dynamic-providers/)
- [AWS SDK `@aws-sdk/client-appsync`](https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/appsync/)
- Related upstream issues: tf-aws #25178, cfn-roadmap #932, aws-cdk #13269
