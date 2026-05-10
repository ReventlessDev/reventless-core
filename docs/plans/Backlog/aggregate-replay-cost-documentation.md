# Plan: Document Aggregate Replay Cost and Capacity Profile

**Analysis**: [aggregate-command-handling-review.md](../../analysis/aggregate-command-handling-review.md) — Performance §"Long-tail aggregates"

## Problem

The Aggregate command path replays the full event log on every command, with strongly-consistent reads. Cost scales linearly with event-log length:

- 100-event aggregate: ~100 RRU (strong-consistency reads ≈ 2× standard) per command.
- 10 000-event aggregate: ~10 000 RRU per command — and roughly proportional Lambda execution time.

This is a deliberate simplicity choice (no snapshotting, no caching), but it's not visible to users sizing their workloads. A team adopting Reventless for a "natural fit" use case (long-running workflow, persistent counter, account ledger) is likely to hit this wall in production without warning.

The framework documentation today covers components and patterns but does not give an operator a steady-state cost / throughput-ceiling profile to plan against.

## Goals

- Operators sizing an Aggregate-backed workload have a clear cost-per-command model and a throughput-per-aggregate ceiling.
- The trade-offs that motivate the no-snapshot design are spelled out so the decision feels intentional, not accidental.
- Users who hit the wall know what their options are (snapshotting; restructuring as DCB; rethinking aggregate boundaries) without having to reverse-engineer them from source.

## Non-goals

- Implementing snapshots. That's a separate plan ([aggregate-snapshotting.md](aggregate-snapshotting.md)).
- Re-architecting the replay path. The model is sound; it just needs documenting.
- Promising specific dollar figures. Pricing changes; surface the *shape* of the cost (linear in event count, 2× for strong consistency) and let operators plug in current rates.

## Approach

A new section in [`docs/reventless-components/aggregate.md`](../../reventless-components/aggregate.md): "Cost and capacity model". One page, no fluff. Cross-link from:

- [`docs/get-started.md`](../../get-started.md) — when introducing aggregates.
- [`docs/guides/aggregate-vs-dcb-decision-guide.md`](../../guides/aggregate-vs-dcb-decision-guide.md) — extend the decision matrix with a "long-lived aggregates" row that points at this section.
- [`docs/analysis/aggregate-command-handling-review.md`](../../analysis/aggregate-command-handling-review.md) — back-link.

### Suggested content outline

```markdown
## Cost and capacity model

Each command runs:
1. A strongly-consistent replay of the aggregate's full event log.
2. The behavior's `decide` (in-process, microsecond cost).
3. A conditional append (1× WCU per event for single-event commands; 2× WCU
   per event for multi-event TransactWriteItems).

### Per-command cost (DynamoDB)

| Aggregate length | Replay (strong-read) | Append (1 event) | Approx total |
|---|---|---|---|
| 10 events | 10 RRU | 1 WCU | $0.000002 |
| 100 events | 100 RRU | 1 WCU | $0.0000125 |
| 1 000 events | 1 000 RRU | 1 WCU | $0.00012 |
| 10 000 events | 10 000 RRU | 1 WCU | $0.0012 |

Strong-consistency reads cost 2× a regular read. The 100-event row dominates
the long tail in most applications.

### Throughput ceiling per aggregate

Per-aggregate FIFO ordering serializes all writers on one ID. Effective ceiling:

  throughput ≈ 1 / (replay_ms + decide_ms + append_ms)

For a 100-event aggregate on warm Lambda: ~30 commands/sec.
For a 10 000-event aggregate: ~1–3 commands/sec.

If a single aggregate routinely receives commands above this rate, consider:
- DCB instead — the consistency boundary scales with tags, not entity history.
- Splitting the entity (an "Order" → one Order plus per-line-item aggregates).
- Snapshotting (not yet built — see roadmap).

### Why no snapshots today

Snapshotting trades complexity for cost. The plan exists; it's gated on
production demand. Most early adopters work at scales where the linear
replay cost is invisible compared to Lambda baseline / SQS traffic.
```

The "approx total" column should call out current pricing as illustrative; operators verify against their region's pricing.

## Steps

### Step 1 — Draft the section

Write directly into [`docs/reventless-components/aggregate.md`](../../reventless-components/aggregate.md). Keep it under ~150 lines; this is reference doc, not a treatise.

### Step 2 — Verify numbers

The throughput estimates need a sanity check. Either:

- Run a small benchmark against an in-region DynamoDB table from a Lambda — record p50/p95 replay-and-append for 100/1000/10000-event aggregates.
- Or omit the throughput column and point at "measure your own workload" with the model formula.

Lean toward measurement: the analysis cited "10–30 commands/sec on a small aggregate" without a citation; this is the chance to nail it down.

### Step 3 — Cross-link

- Add a row in [`docs/guides/aggregate-vs-dcb-decision-guide.md`](../../guides/aggregate-vs-dcb-decision-guide.md): "Long event log per entity → DCB or restructure → see aggregate cost model."
- Add a one-liner in [`docs/get-started.md`](../../get-started.md) when first introducing aggregates: "See [Cost and capacity model](...) for sizing guidance."

### Step 4 — Mention the related backlog plans

In a "Roadmap" subsection or as inline notes, reference:

- [aggregate-snapshotting.md](aggregate-snapshotting.md) for the long-term remediation.
- [aggregate-multi-event-atomic-append.md](aggregate-multi-event-atomic-append.md) for the WCU implications of multi-event commands.

### Step 5 — Move to done

Plan to `done/` once the doc lands. Update analysis recommendation to mark documented.

## Open questions

- **Where to publish benchmark numbers?** They date quickly. Either commit them with a "measured 2026-MM-DD" stamp, or publish a benchmark script and let users re-run. Lean toward the script.
- **Should the doc warn about the visibility-timeout interaction?** (180s SQS visibility; if replay+decide+append > 180s the message is redelivered.) Probably yes — long aggregates that approach the limit are a real failure mode. Add a "Failure modes" subsection.

## Status

Not started.
