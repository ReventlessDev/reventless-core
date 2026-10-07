# Plan: the DCB consistency follow-ups wait for a workload that needs them

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/dcb-consistency-hardening.md](../done/dcb-consistency-hardening.md) when it closed. Every item here is evidence-gated: nothing in the repo or on the deployed stacks triggers it today, and building any of them ahead of that evidence is churn on the hottest path of the DCB write.<br/>
**Relates to:** [../../analysis/dcb-consistency-check-issues.md](../../analysis/dcb-consistency-check-issues.md) (Issues 6 and 9), [../../analysis/dcb-high-contention-handling.md](../../analysis/dcb-high-contention-handling.md) (the runtime control surface)

---

## In plain words

A DCB slice decides by reading the events it cares about, then appends only if nobody changed those
events in the meantime. The "nobody changed them" check is a **fence**: a small DynamoDB row per tag
whose last position must not have moved past what the read saw. The hardening roadmap fixed every
fence defect that a real slice hit. Four smaller items were left because no slice hits them yet.

## What is left

| Item | What it is | Pull it when |
|---|---|---|
| **Per-tag `after`** (analysis Issue 6) | A multi-clause read (`[{tags:A}, {tags:B}]`) computes one global head position and checks every partition tag's fence against it. When the clauses sit at very different positions, a partition tag can false-conflict. Read-only (secondary) tags are already immune — they use a check-don't-bump `ConditionCheck`. The fix is to check each fence against the head observed for *its own* clause. | A real multi-clause slice shows false `ConditionalCheckFailed` conflicts in the `Reventless/DCB` `AppendConflict` metric. |
| **`appendUnconditional` bumps every tag** (analysis Issue 9) | The seed/replay path in `DcbEventLogStorage_DynamoDb_Runtime.res` still bumps the fence of every tag an event carries, while the runtime path (`appendConditional`) bumps only partition tags. Seeding-only, so not a live bug. | A composite-fence design is ever adopted, or a seed run is shown to wedge a slice. |
| **Per-slice decision-cache capacity** | `StateChangeSlice_Callback.res` hardcodes `let projectionCacheCapacity = 100` (and `Aggregate_Callback.res` the same for `replayCacheCapacity`). A knob means a `projectionCacheCapacity` field on `StateChangeSlice.Spec` plus PPX injection of the default, like `readConsistency`. | The `DcbDecisionModelCacheHit`/`Miss` metrics show a slice whose working set exceeds 100 entities per warm Lambda. |
| **Runtime strong-read override** | `readConsistency` (`EscalateOnRetry` / `AlwaysStrong` / `AlwaysEventual`) is build-time only. A runtime override (SSM parameter or env var, no redeploy) is option S3 in the contention analysis. | Metrics show a recurring hot slice where flipping consistency without a redeploy would have mattered — and only with conflict *classification* (replica lag vs. genuine concurrent writers), never an automatic flip on raw conflict rate. |

## What done looks like

Each row is independent. For any one: a failing case reproduced first (the DynamoDB Local
integration suite, `reventless/aws/tests/integration/DcbEventLogStorage_DynamoDb_IntegrationTest.res`,
is the harness for the first two), then the fix, with the suite still green and the analysis issue
marked resolved.
