# Plan: AppSync Schema-Push Deduplication

## Summary

`preResolversSchemaHook` in `reventless-aws/src/Platform.res` calls
`StartSchemaCreationCommand` on every `pulumi up`, unconditionally.
Even when the resulting SDL is byte-identical to the currently-live
schema, AWS accepts the push and re-runs the internal propagation
between its schema document store and its resolver control-plane
store. For ~30 seconds to several minutes after each push,
`CreateResolver` 404s on every field that was part of the schema
delta — which, on a no-op push, is *none* of the fields, yet
`CreateResolver` still fails because it sees the whole schema as "in
flight".

Skipping `StartSchemaCreation` when the SDL has not changed
eliminates the race entirely for no-op deploys and most
incremental-change deploys where no schema field is actually added.
Combined with the retry wrapper
(`docs/plans/done/appsync-resolver-aws-native-retry.md`), this
completes the fix.

**Source analysis:** `private-consumer-repo/docs/analysis/appsync-resolver-creation-race.md`
— see the "Out of scope" note at the end of the Option C section
mentioning schema-push deduplication as a complementary optimisation.

**Companion plan:** `docs/plans/done/appsync-resolver-aws-native-retry.md`
— the retry wrapper. Both are needed; either alone is insufficient.

---

## Motivation

### What each `pulumi up` currently does

`preResolversSchemaHook` runs during every plugin-stack deploy and:

1. Writes the current plugin's fragment to a `deploy-schema:<name>` DynamoDB
   entry in the `Plugin-*` registry table.
2. Scans the table for all `deploy-schema:*` entries → builds the stitched SDL.
3. Calls `StartSchemaCreationCommand` with the full stitched SDL.
4. Polls `GetSchemaCreationStatus` until `ACTIVE`.
5. (Currently) sleeps to let propagation complete.

Steps 3–5 fire even when the SDL is byte-identical to what AWS already
has. Every `pulumi up` — including pure no-op runs — therefore pays
the propagation-race tax.

### Observed impact

On the `platform-inspector-aws` stack, re-running `pulumi up` after a
successful deploy takes ~30 seconds just for the unnecessary schema
push + post-ACTIVE sleep + retry propagation waits. With 5 plugin
stacks this adds ~2.5 minutes of wasted time per clean-state
deploy cycle.

More importantly, the unnecessary push **restarts the resolver
propagation clock**, so any resolver create that happens afterward
(e.g. adding a new plugin in the same `pulumi up` wave) hits the
retry path. Avoiding the push avoids the race entirely.

---

## Design

### Hash the stitched SDL, store it alongside the fragments

The `Plugin-*` DynamoDB table already stores per-plugin schema
fragments under `deploy-schema:<pluginName>`. Add one more entry:
`deploy-schema-hash:<apiId>` whose value is the SHA-256 hex digest of
the stitched SDL that was last successfully pushed to that AppSync
API.

Keyed per `apiId` (not globally) so:
- Platform API and Domain API have independent hashes (dual-API split).
- A new AppSync API — e.g. a fresh stack bring-up — has no stored hash
  and thus always pushes on first deploy.
- If the AppSync API is destroyed and recreated, the new `apiId`
  doesn't pick up a stale hash.

### Push skip condition

```
storedHash = read DynamoDB item "deploy-schema-hash:<apiId>"
currentHash = sha256(stitchedSdl)

if storedHash == Some(currentHash) then
  log "[preResolversSchemaHook] SDL unchanged (hash match), skipping push"
  return  // no StartSchemaCreation call, no waitForSchemaActive
else
  log "[preResolversSchemaHook] SDL changed, pushing schema (old hash: X, new hash: Y)"
  call StartSchemaCreationCommand
  wait for ACTIVE
  write DynamoDB item "deploy-schema-hash:<apiId>" = currentHash
```

### Hash-write happens after successful push

If the push fails, the old hash stays in DynamoDB. Next deploy will
retry the push. This keeps the hash in sync with what AWS actually
has; a successful push is the event that advances the hash.

### First deploy of a stack

No hash exists in DynamoDB for a brand-new `apiId`. Push happens
normally. After it succeeds, hash is written.

### AWS drift detection

If someone pushes a schema to AppSync out-of-band (via `aws appsync
start-schema-creation` from the CLI), the DynamoDB hash will match the
last Pulumi-pushed SDL but will not match the AWS SDL. Next `pulumi up`
will skip the push even though AWS and our idea of "what's deployed"
have diverged.

**Mitigation:** document it; provide a force-push escape hatch (see
Phase 3.3 below). Drift is rare in practice because manual schema
pushes against a Pulumi-managed API are unusual, but we should
acknowledge it rather than silently diverge.

---

## Phase 1 — Hash computation helper

### 1.1 SHA-256 of the stitched SDL

**File:** `reventless-aws/src/components/Api/AppSync_Adapter.res`

Add a helper:

```rescript
@module("node:crypto") external createHash: string => hashObject = "createHash"
@send external update: (hashObject, string) => hashObject = "update"
@send external digest: (hashObject, string) => string = "digest"

let sha256Hex = (input: string): string =>
  createHash("sha256")->update(input)->digest("hex")
```

Node's `crypto` is already in the Lambda runtime and in Pulumi-host
Node, no new dependency.

---

## Phase 2 — DynamoDB helpers for the hash entry

### 2.1 Read and write helpers

**File:** `reventless-aws/src/Platform.res` (near the existing
`deploy-schema:` read/write code)

```rescript
let deploySchemaHashPrefix = "deploy-schema-hash:"

let readSchemaHash = async (~tableName: string, ~apiId: string): option<string> => {
  // GetItem where pk = deploySchemaHashPrefix ++ apiId
  // Returns Some(hash) or None
}

let writeSchemaHash = async (~tableName: string, ~apiId: string, ~hash: string): unit => {
  // PutItem with pk = deploySchemaHashPrefix ++ apiId, value = hash
}
```

Use the same DynamoDB client + encoding patterns as the existing
`writeAndScanFragments` flow (JSON-encoded attribute values).

### 2.2 Key scoping

Use one key per AppSync API ID, not per plugin. The hash represents
the **stitched** SDL that was pushed to the API, which is shared
across plugins. Plugins come and go; the hash tracks the API's
schema state.

---

## Phase 3 — Wire skip into `preResolversSchemaHook`

### 3.1 Modify the existing hook

**File:** `reventless-aws/src/Platform.res`

After computing `sdl` and before calling `startSchemaCreation`:

```rescript
let currentHash = AppSync_Adapter.sha256Hex(sdl)
let storedHash = await readSchemaHash(~tableName, ~apiId)

switch storedHash {
| Some(prev) when prev == currentHash =>
  Console.log(
    `[preResolversSchemaHook] SDL unchanged (hash ${currentHash->String.slice(~start=0, ~end=12)}…), skipping push`
  )
// no push, no wait, no hash update
| _ =>
  Console.log(
    `[preResolversSchemaHook] SDL changed, pushing schema (new hash: ${currentHash->String.slice(~start=0, ~end=12)}…)`
  )
  let _ = await client->AppSync_Adapter.startSchemaCreation({apiId, definition: sdl})
  Console.log("[preResolversSchemaHook] startSchemaCreation called, waiting for ACTIVE")
  await AppSync_Adapter.waitForSchemaActive(client, apiId)
  Console.log("[preResolversSchemaHook] Schema is ACTIVE")
  await writeSchemaHash(~tableName, ~apiId, ~hash=currentHash)
}
```

### 3.2 Logging

Log both the old and new hash prefixes on change to make it easy to
correlate deploys in CI logs with schema-delta events.

### 3.3 Force-push escape hatch

For cases where the DynamoDB hash and AWS reality have drifted (manual
intervention, disaster recovery):

- Pulumi config flag: `appsync:forceSchemaPush=true` — when set, skip
  the hash check and always push. Clear after a successful deploy.
- Alternative: a small CLI `reventless-aws schema force-push --api
  <id>` that deletes the hash entry from DynamoDB. Next deploy will
  re-push.

Pick one; the config flag is simpler.

### 3.4 DynamoDB failure fallback

If the read or write fails (permissions, table gone, transient DB
error), fall back to the current behaviour: always push. This
preserves correctness at the cost of the optimisation. Log a warning
so operators notice.

---

## Phase 4 — Cross-stack interaction

### 4.1 Plugin stack adds a new fragment

1. Plugin stack writes `deploy-schema:<pluginName>` entry.
2. Scans all fragments → stitched SDL includes the new plugin's fields.
3. Hash changes → push fires.
4. Post-ACTIVE, hash is written.
5. Other plugin stacks deploying afterward see the new hash. If their
   fragment has not changed, their stitched SDL (which scans all
   fragments) equals the just-pushed one → hash match → skip.

This is the happy path: **only the plugin whose fragment actually
changed triggers a push**.

### 4.2 Simultaneous deploys

Two plugin stacks deploying at the same time race on the
DynamoDB fragment table. The current implementation does not lock
this. With dedup added, the race becomes:

- Stack A writes fragment F_A → scans (sees F_A, F_B_old, F_C) → hashes → pushes → writes hash H1.
- Stack B writes fragment F_B → scans (sees F_A, F_B, F_C) → hashes → **gets H2 ≠ H1** → pushes → writes hash H2.

Both pushes happen, both produce consistent end state. No worse than
today. The optimisation degrades to current behaviour under
concurrent deploys, which is acceptable.

### 4.3 Platform deploy (base fragment change)

Base fragment changes in `Platform.res` (e.g. adding a new admin
mutation) change the stitched SDL even if no plugin fragment
changed. Hash will diff → push fires. Correct.

---

## Phase 5 — Tests

### 5.1 Unit test for `sha256Hex`

**File:** `reventless-aws/tests/AppSync_AdapterTest.res`

- Stable digest for identical input across runs.
- Different digest for two SDLs differing by one character.

### 5.2 Integration test — skip on no-op deploy

Manual for now: deploy any plugin stack, watch the log for
`Pushing schema to API`. Run `pulumi up --yes` again, confirm the
log line for the second run says `SDL unchanged ... skipping push`
and the deploy is noticeably faster (~15s vs ~45s).

Formal integration test is worthwhile once we have a stack-level
test harness. Defer.

---

## Phase 6 — Documentation

### 6.1 Update the dual-provider guide

**File:** `reventless-aws/docs/guides/dual-aws-provider.md`

Add a "Schema push optimisation" section:

- Describes the hash-based dedup.
- Notes the `Plugin-*` table now stores `deploy-schema-hash:<apiId>`.
- Documents the force-push escape hatch.

### 6.2 Release notes

Conventional commit subject:

```
perf(aws): skip AppSync schema push when SDL is unchanged
```

Body mentions:
- No behaviour change for deploys that genuinely change the schema.
- Significantly faster no-op deploys (~30 s saved per plugin stack).
- Indirectly reduces propagation-race frequency by not resetting the
  propagation clock on no-op pushes.

---

## Phase 7 — Rollout

### 7.1 Ship Phases 1–6 in one release

### 7.2 Monitor

Watch for:

- `SDL unchanged (hash …), skipping push` log appearing on repeat
  deploys — confirms the optimisation fires.
- Force-push escape hatch documented but not needed in normal
  operations.
- No unexpected `CreateResolver` 404s from stacks that legitimately
  didn't change their schema.

### 7.3 Metric to track (optional)

Count the ratio of schema-push skips vs pushes across all deploys
in a given week. Steady state should be >50% skips (most deploys
don't change SDL).

---

## Out of scope

- Pre-push AWS-side drift detection. Reading the current live SDL
  from AppSync to compare against what we intend to push would give
  us truly authoritative drift detection, but costs an extra round
  trip and complicates the hook. Not worth it for rare drift cases.
- Cross-region schema-hash replication. If a stack is ever deployed
  across regions, each `apiId` (which is region-scoped) naturally
  has its own hash. No extra work needed.
- Hash versioning. If we ever change the SDL stitching or auth
  injection algorithm, the new stitched SDL will naturally produce
  a different hash and force a push. No explicit versioning needed.

---

## Risks

### DynamoDB hash and AWS reality drift silently

If someone pushes a schema manually while Pulumi isn't running,
the stored hash remains at the last Pulumi-pushed value. Next
`pulumi up` will skip the push even though AWS has something
different.

**Mitigation:** Phase 3.3 force-push flag. Document it in the
runbook. Drift is rare in practice and operators can always force
a push.

### Hash collision

Theoretical with SHA-256 but astronomically unlikely; not a concern.

### DynamoDB read latency on every deploy

The dedup check adds one GetItem call per plugin stack deploy.
Sub-10ms typically. Acceptable compared to the 30 s saved per
no-op deploy.

### Increased `Plugin-*` table footprint

One extra entry per AppSync API (two, in dual-API setups). Trivial.

---

## File Changes Summary

| File | Action |
|------|--------|
| `reventless-aws/src/components/Api/AppSync_Adapter.res` | Updated — add `sha256Hex` helper |
| `reventless-aws/src/Platform.res` | Updated — add `readSchemaHash` / `writeSchemaHash`, wire hash check into `preResolversSchemaHook` |
| `reventless-aws/tests/AppSync_AdapterTest.res` | Updated — unit test for `sha256Hex` |
| `reventless-aws/docs/guides/dual-aws-provider.md` | Updated — schema-push optimisation section |

---

## References

- Source analysis: `private-consumer-repo/docs/analysis/appsync-resolver-creation-race.md`
- Companion plan (retry): `docs/plans/done/appsync-resolver-aws-native-retry.md`
- [`StartSchemaCreation` API](https://docs.aws.amazon.com/appsync/latest/APIReference/API_StartSchemaCreation.html)
- [Node.js `crypto.createHash`](https://nodejs.org/api/crypto.html#cryptocreatehashalgorithm-options)
