# Plan: Orphaned alpha resource cleanup (functions, APIs, log groups)

**Status: complete (2026-08-02).** All actionable work done — 34 orphan functions
+ 6 orphan APIs deleted, root cause resolved (historical backlog, not an ongoing
leak). The 4 stuck source APIs are a conscious "leave them" (no cost/logs/drift);
reopen this plan only if AWS surfaces a force-detach for their dangling merged-API
association.

Follow-up to
[env-tiered-log-retention-and-levels.md](./env-tiered-log-retention-and-levels.md).
That change makes Lambda/AppSync log groups Pulumi-managed, which stops *future*
orphan **log groups** on the live stack. This note covers the *existing* orphaned
**functions and AppSync APIs** whose auto-created groups were the visible symptom.

## Problem

On the shared `eu-west-1` account, resources tagged `reventless:environment=alpha`
far outnumber what the live stacks manage — past redeploys replaced resources
(new `-<suffix>`) without tearing down the old ones. Measured 2026-08-02:

| | Live (in Pulumi state) | Tagged `alpha` | Orphans |
|---|---|---|---|
| Lambda functions | 30 | 64 | **34** |
| AppSync APIs | 6 | 16 | **10** |

`online-shop-hybrid`'s alpha deploy is **three** Pulumi stacks
(`online-shop-hybrid-{platform,catalog,ordering}-aws`), so the live set is the
union of all three. The tag alone cannot tell a live resource from an orphan —
**Pulumi state is the only safe oracle**.

## Method (safe, reproducible)

Orphans = resources tagged alpha that are in **no** alpha stack's state:

```bash
REGION=eu-west-1
# LIVE set — union of the three stacks' exported state
for p in platform-aws catalog-aws ordering-aws; do
  ( cd examples/online-shop-hybrid/$p && pulumi stack export -s alpha ) \
    | jq -r '.deployment.resources[]
             | select(.type=="aws:lambda/function:Function") | .outputs.name'
done | sort -u > /tmp/live-fns.txt          # …and aws:appsync/graphQLApi:GraphQLApi → .outputs.id

# TAGGED set
aws resourcegroupstaggingapi get-resources --region $REGION \
  --resource-type-filters lambda:function \
  --tag-filters Key=reventless:environment,Values=alpha \
  --query 'ResourceTagMappingList[].ResourceARN' --output text \
  | tr '\t' '\n' | awk -F: 'NF{print $NF}' | sort -u > /tmp/tag-fns.txt

comm -23 /tmp/tag-fns.txt /tmp/live-fns.txt   # ORPHANS (delete these + their /aws/lambda/<fn> group)
```

Deleting a function also drops its (stale) event-source mappings; the live
consumers are the in-state functions and are untouched. `comm -23` guarantees no
live resource can appear in the delete list.

## Done — 2026-08-02

- **34 orphan Lambda functions deleted** (+ their log groups). Re-derived diff
  afterwards: **0 orphan functions remain** (30 tagged = 30 live).
- **6 of 10 orphan AppSync APIs deleted** (+ their log groups).
- All orphan **log groups are gone** — including the 4 APIs still pending below
  (their groups were already absent). The recurring auto-created groups that
  remain belong only to the 30 *live* functions (heartbeats), addressed by the
  managed-group cutover in the parent plan's Step 8.

## Remaining — 4 orphan source APIs stuck on a dangling merged-API association ⬜ (parked)

`5ad57…` (PluginSourceApi-35cd3a3), `eumxo…` (DomainApi-6969f63),
`hqkjv…` (ConsoleSourceApi-aaf9a1a), `i6sr3…` (PlatformObservabilitySourceApi-4910084).

`delete-graphql-api` fails: *"API can not be deleted as it is associated to a
Merged API."* Diagnosed 2026-08-02:

- The account holds exactly **two** merged APIs, both **live** (`DomainMergedApi`
  25nde…, `PlatformMergedApi` klgg3…). Their source lists are su7vlak…/2tm3n4f…/zwnmyix…
  and cmnpz6n… respectively — **none of the 4**.
- Each of the 4, queried from the source side, reports **empty** associations.

So the merged API they were associated to **no longer exists** — a **dangling
association** AppSync won't let go of, with no association record left to
`delete-source-api-association`. Two of the four (`ConsoleSourceApi`,
`PlatformObservabilitySourceApi`) are *removed* components; the other two are
superseded duplicates from the merged-API topology change.

**Decision: leave them.** No log group (already deleted), no idle cost (AppSync
GRAPHQL APIs bill per request), not in any Pulumi stack (no drift). Clearing a
dangling association to a deleted merged API is an AWS-support-adjacent task with
no material payoff. Revisit only if AWS surfaces a way to force-detach, or if they
start costing something.

## Root cause — resolved: historical backlog, not an ongoing leak ✅

Answered by re-measuring after the cleanup: across the **two subsequent deploys**
(host-shell bump + others), the orphan **function** count stayed at **0** (30
tagged = 30 live). Current deploys clean up after themselves — replace/destroy is
tearing down the old resource. The accumulation was a **one-time historical
backlog**, not a per-deploy treadmill.

The evidence points at the big topology cutovers as the source: the orphan set
was dominated by duplicate `AllReadModels`/`AllStateViewSlices`/`DeadLetterQueue`
suffixes (replace-without-delete during framework-version changes) plus whole
removed components (`ConsoleSourceApi`, `PlatformObservabilitySourceApi` — the
retired inspector/observability surfaces, cf. the merged-API composition and
`node()`-drop migrations). No further code action needed; the periodic
`find-alpha-orphans.sh` state-diff is enough to catch any future regression.

## Scripts

Written to the session scratchpad (ephemeral — the method above is the durable
record): `find-alpha-orphans.sh` (read-only state diff),
`delete-alpha-orphans.sh` (dry-run-first delete), `migrate-alpha-log-groups.sh`
(the earlier log-group delete for the Step 8 cutover).
