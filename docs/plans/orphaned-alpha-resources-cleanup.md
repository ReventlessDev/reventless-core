# Plan: Orphaned alpha resource cleanup (functions, APIs, log groups)

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

## Remaining — 4 orphan source APIs blocked by a Merged-API association ⬜

`5ad57tvvn5cnzhivq5mr452emm`, `eumxoutq7rgzhiun47urgwqqj4`,
`hqkjvmytqvgqtljpmojhmlibf4`, `i6sr3p5mgvez7p36vh5ojx64y4`.

`delete-graphql-api` fails: *"API can not be deleted as it is associated to a
Merged API."* But neither **live** merged API lists them as a source:

- `DomainMergedApi` (25nde…) sources: su7vlak…, 2tm3n4f…, zwnmyix…
- `PlatformMergedApi` (klgg3…) source: cmnpz6n…

So these are **dangling/stale associations** — to a merged API that is gone, or an
association stuck in a failed state. Not to be force-untangled against the live
merged APIs casually (removing a source re-triggers a merge on the running API —
the delicate merged-API composition path, cf. MERGE_FAILED / assoc-create 409s).

They carry **no log group and no idle cost**, so they are parked. To clear later,
carefully: find the owning association from the source side
(`get-source-api-association` / the association id), confirm it is not a live
merge input, `delete-source-api-association`, then `delete-graphql-api`.

## Root cause — worth confirming so this is not a treadmill ⬜

>50% orphan rate means redeploys leave the old resource behind on replace. Likely
the big merged-API / `node()`-drop cutovers, or destroy/recreate history, or
logical-name changes across framework versions. Until understood, orphans will
re-accumulate and this cleanup repeats. Investigate: do current alpha redeploys
still strand a superseded function/API per replaced component, or was this a
one-time backlog from historical cutovers?

## Scripts

Written to the session scratchpad (ephemeral — the method above is the durable
record): `find-alpha-orphans.sh` (read-only state diff),
`delete-alpha-orphans.sh` (dry-run-first delete), `migrate-alpha-log-groups.sh`
(the earlier log-group delete for the Step 8 cutover).
