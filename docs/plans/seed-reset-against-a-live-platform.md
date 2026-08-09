# Plan: Make `seed:reset` survive a running platform

**Status.** Planned — 2026-08-09. Not started. Found when a reset reported every store truncated
and then failed its own verification, with one store back to its exact pre-wipe contents.

**Goal.** A reset of a deployed stack leaves the selected stores empty and stays that way, or says
precisely why it cannot — rather than reporting a successful truncate of a store that is refilled
before the run ends.

**Non-goal.** Changing what the reset selects, or its scope model. The discovery and the
confirmation prompt are right; only the emptiness guarantee is not.

---

## §1 — The defect: truncate succeeds, the store refills, verification fails

The reset truncates every selected table and then re-counts to verify. On a running platform the
verification can fail on a store the truncate genuinely emptied:

```
Emptying <scope> …
  truncated <AutomationSliceState>          ← the delete really happened
  …
Reset aborted — 12 item(s)/object(s) remain after the wipe — re-run to finish.
```

Re-running does not help, and the advice to re-run is therefore wrong: the same thing happens
every time.

**The truncate is not at fault.** `truncateTable` reads the key schema, scans projecting only the
key attributes, and batch-deletes with `sendBatch`, which resends `UnprocessedItems` and *throws*
after eight attempts rather than swallowing them. Deleting the surviving rows by hand takes the
table to zero, so nothing about the delete path is failing silently.

**The rows come back.** Measured on a quiet stack with no traffic: the table was empty on two
consecutive reads and back to twelve rows within forty seconds, with **byte-identical contents** —
the same ids and the same `createdAt` to the millisecond.

## §2 — What writes them

The owning runtime, on its next invocation:

```
service: AllAutomationSlices-<id>
comp:    QueryDbStorage_DynamoDb_Runtime
message: save: saved state to <AutomationSliceState>: id=…      ×12, within 34 ms
```

Twelve saves, one invocation, no event-processing line preceding them — the slice is **persisting
state it already holds**, not deriving new work from an event. That is why the restored rows are
identical rather than merely equivalent: nothing recomputed them.

Which is also why emptying the source first does not help. In the observed run the event log,
the read models and the aggregate stores had all been truncated moments earlier, and the state
still came back complete.

**Where the held state lives is the open question**, and it changes the fix:

1. **A warm runtime's in-process state.** A container that loaded the state before the wipe and
   writes it back on each later invocation. This fits the evidence best — it explains identical
   contents with every upstream store already empty — and it implies the data survives in memory
   until the container is recycled.
2. **A second durable copy the reset does not select** — a snapshot, a bucketed task store, or a
   sibling table outside the scope model.

These are distinguishable in one experiment (§5) and the plan should not choose a fix before
running it.

## §3 — Why this is the same shape as a race we have already lost

This is structurally the log-group problem in a different subsystem: **delete something a live
process owns, and it comes straight back**, with the retry advice making it look transient. The
lesson there transfers — a fix that races the platform is not a fix, and the durable answer is to
remove the contention rather than to be faster than it.

It also matters that the failure is *loud but misleading*. The reset does the right thing by
verifying and refusing, and the refusal correctly protects the seeder's one-shot precondition. The
wrong part is only the diagnosis it offers.

## §4 — Options, none chosen yet

- **Quiesce the runtimes for the duration.** Set reserved concurrency to zero on the affected
  runtimes, wipe, restore concurrency. Removes the contention outright and is the only option that
  works whichever answer §2 has. Costs the reset the right to reconfigure functions, and must
  restore concurrency even when the wipe fails.
- **Wipe last, in dependency order.** If the state is derived, emptying it after its sources are
  empty would leave nothing to rebuild from. Cheap and needs no new powers — but the evidence says
  the sources *were* already empty, so on its own this looks insufficient.
- **Verify-and-re-wipe with a bound.** Repeat until stable or a small limit is reached. Honest
  about the race without pretending to win it; degenerates into a loop against a warm container
  that re-saves on every invocation.
- **Report the writer instead of the count.** Whatever else changes, the failure should name what
  refilled the store. The current message says twelve items remain; it could say which store, and
  that a live runtime wrote them after the truncate. This is worth doing even alongside a real fix,
  because it converts a mystery into a diagnosis.

## §5 — The experiment that decides it

Empty the store, then force the owning runtime to cold-start (update its configuration to recycle
containers) **without** any upstream data present, and re-count.

- If the store stays empty → the state was held in a warm container (§2.1), and quiescing or
  forcing a recycle is the fix.
- If it refills → a durable copy exists outside the scope model (§2.2), and the fix is discovery,
  not timing.

## §6 — Acceptance

- A reset against a deployed, idle stack leaves the selected stores empty, verified after the
  runtimes have had an opportunity to run.
- The subsequent seed's one-shot precondition passes without manual intervention.
- If the reset cannot guarantee emptiness, it says which store refilled and what wrote to it —
  never "re-run to finish" for a condition that re-running cannot clear.
- Whatever powers the reset gains are released on the failure path as well as the success path.

---

## Appendix: anchors (2026-08-09)

| Fact | Anchor |
| --- | --- |
| Truncate: key schema → projected scan → batch delete | `reventless/seed-aws/src/ReventlessSeedAws_Reset.res` — `truncateTable` |
| Unprocessed items are retried, then raised | same file — `sendBatch`, capped at 8 attempts |
| Post-wipe verification and its message | same file — the `remaining` accumulator and the abort |
| The writer observed | automation-slice runtime, `QueryDbStorage_DynamoDb_Runtime` — `save: saved state to …` |
