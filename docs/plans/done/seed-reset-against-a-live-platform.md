# Plan: Make `seed:reset` survive a running platform

**Status.** Done — 2026-08-09. §5 answered from the runtime source and confirmed against the live
`alpha` stack; the fix is in, and a full domain-scope reset of `alpha` left every store empty
through five subsequent runtime invocations, two of them scheduled sweeps (§7).

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

**Answered: §2.1, a warm runtime's in-process state.** The experiment in §5 was not needed to
decide it — the runtime source says so outright, and the live stack agrees on every detail:

- `AutomationSlice_Callback.Make` declares `let todoItems: Dict.t<todoRow> = Dict.make()` at
  **module level**, so the TODO list lives for the whole life of the execution environment.
- `AutomationSliceEntryPoint_Ops.makeSyncTodoItems` writes **every entry of that dict**, with
  `Overwrite`, at the end of every invocation. That call is the `save: saved state to …` line.
- `sweep` is `loadTodoItems() → phase2() → syncTodoItems()`, and the scheduled EventBridge rule
  fires it every **5 minutes** with `{reventlessSweep: true}` — a payload carrying no records,
  which is exactly why no event-processing line precedes the saves.
- `makeLoadTodoItems` is guarded by a `loaded` ref and runs **once per container**, so a warm
  container never re-reads the table and never learns it was emptied.
- `createdAt` is a field of the held row, not recomputed — hence byte-identical restores.

Confirmed live on `alpha` (2026-08-09): `AutoShipOrderTodo-61f39a2` held exactly the twelve rows
of the report, all `Failed`; one long-lived container logged twelve saves per invocation in ~100 ms
every five minutes; and three sequential manual invocations all landed in the **same** execution
environment with zero cold starts.

That the rows are `Failed` rather than `Completed` matters. `Failed` rows below `maxRetries` are
actionable, so `phase2` touches them on every sweep — which rules out the tempting runtime-side
fix of only writing back rows that changed. They change every time. The reset has to remove the
contention.

It also rules out §2.2: `makeLoadTodoItems` reads only `Pending`/`Failed` rows from the store the
reset empties, so a container starting after a successful wipe restores nothing.

## §3 — Why this is the same shape as a race we have already lost

This is structurally the log-group problem in a different subsystem: **delete something a live
process owns, and it comes straight back**, with the retry advice making it look transient. The
lesson there transfers — a fix that races the platform is not a fix, and the durable answer is to
remove the contention rather than to be faster than it.

It also matters that the failure is *loud but misleading*. The reset does the right thing by
verifying and refusing, and the refusal correctly protects the seeder's one-shot precondition. The
wrong part is only the diagnosis it offers.

## §4 — Options

- **Quiesce the runtimes for the duration.** *Chosen.* Removes the contention outright and is the
  only option that works whichever answer §2 has. Costs the reset the right to reconfigure
  functions, and must restore concurrency even when the wipe fails.
- **Wipe last, in dependency order.** Insufficient, as §2 predicted and the live evidence
  confirms: nothing upstream is read, so emptying the sources first changes nothing.
- **Verify-and-re-wipe with a bound.** Rejected. Against a warm container that re-saves on every
  sweep this is an unbounded loop dressed as a bounded one.
- **Report the writer instead of the count.** *Also done*, alongside the real fix — see §6.3.

## §5 — The experiment that decides it

Superseded. The runtime source answers it directly (§2), and the live confirmation there is
stronger than the proposed experiment: the container reuse, the five-minute sweep, the twelve
identical saves and the `Failed` statuses were all observed rather than inferred.

What *was* worth testing empirically is the question the plan did not ask — **which action
actually discards a warm container**. Reserving zero concurrency stops new invocations but is not
documented to terminate an existing execution environment, whereas a configuration change is.
Measured on `alpha`:

| step | invocations | execution environments | cold starts |
| --- | --- | --- | --- |
| baseline | 3 sequential | 1 (reused) | 0 |
| after `hold` → `recycle` → `release` | 2 sequential | 1 **new** | 1 |

So the recycle is a real requirement, not belt-and-braces, and the hold alone would not have been
enough.

## §6 — What was built

### 6.1 `AwsSdk.Lambda` (`rescript/aws-sdk/src/Lambda.res`)

Control-plane bindings only: `GetFunctionConfiguration`, `UpdateFunctionConfiguration`,
`GetFunctionConcurrency`, `PutFunctionConcurrency`, `DeleteFunctionConcurrency`. Explicit client
with a region, matching `ResourceGroupsTaggingApi` rather than the memoised clients.

### 6.2 `ReventlessSeedAws_Quiesce`

Three phases, in this order, around the wipe:

1. **`hold`** — reserve 0 concurrency on every function in scope, recording each function's prior
   reservation (`None` for "no reservation at all", which is a different state from 0) and its
   environment. Runs before the first delete, so a stack that cannot be held is one the reset can
   still decline to start on. It rolls back the reservations it already took before throwing —
   functions are held concurrently, and aborting while silently leaving half a stack switched off
   would be worse than the failure being reported.
2. **`recycle`** — add a `REVENTLESS_RESET_RECYCLE` marker variable, which discards the execution
   environments. Runs *while still held*, so the container that eventually replaces them starts
   from the emptied store.
3. **`release`** — put the original environment back (dropping the marker, and recycling a second
   time harmlessly), then the original reservation. Because the marker round-trips, the function
   ends byte-identical to how it started and `pulumi preview` reports no drift.

`recycle` and `release` never throw: they run on the abort path too, where an exception would bury
the reason the reset failed. They return warnings for the caller to print instead — a function left
reserved at 0 is a stack left switched off, and that has to be said out loud.

Control-plane calls fan out six at a time; Lambda's control plane is rate-limited well below the
data plane and a reset touches every function in a project at once.

### 6.3 Reset changes (`ReventlessSeedAws_Reset`)

- `discover` now also returns the project's **Lambda functions**, under the same
  `reventless:platform` + `reventless:environment` tag scope and the same per-resource re-check as
  the stores. The tag scope that decides what may be emptied is exactly the scope that decides what
  may be held. `classify` gained a `Function` arm that tolerates a version/alias qualifier.
- The wipe and its verification run between `hold` and `recycle`/`release`. ReScript has no
  `finally`, so the outcome is captured as a value and re-raised after the stack has been handed
  back — every exit path releases.
- The verification now records **which** store is non-empty, not just a total.
- `refillMessage` replaces `"…remain after the wipe — re-run to finish."` It names every store that
  came back with its count, and distinguishes the two genuinely different situations: under a hold
  the only possible writer is an invocation already in flight, which a re-run does clear; without
  one, re-running is the wrong advice and the message says so.
- `SEED_RESET_NO_QUIESCE=1` opts out for credentials lacking the Lambda permissions, with the loss
  of guarantee stated in the run output rather than buried.

### 6.4 Tests and docs

`reventless/seed-aws/tests/QuiesceResetTest.res` pins the pure half: ARN classification (including
the qualifier case), `mapBounded` order-preservation and its concurrency ceiling, both arms of
`refillMessage`, and the fail-closed `noQuiesce` parsing. The hybrid example's README documents the
hold, the five IAM actions it needs, and the opt-out.

## §7 — Acceptance

- [x] **A reset against a deployed, idle stack leaves the selected stores empty, verified after the
      runtimes have had an opportunity to run.** Full domain-scope reset of `alpha`, 2026-08-09.
      18 runtimes held; 13 tables, 1 bucket and 1 object store emptied and verified. The runtimes
      then had every opportunity to undo it and did not:

      | time (UTC) | what ran | saves to `AutoShipOrderTodo` |
      | --- | --- | --- |
      | 02:21:31 | last pre-wipe scheduled sweep | **12** — the defect |
      | ~02:24 | hold → wipe → recycle → release | — |
      | 02:24:32 / :38 / :43 | three forced sweeps | 0 |
      | 02:26:31, 02:31:31 | two scheduled sweeps | 0 |

      Every `save: saved state to …` line in the window predates the wipe. Re-running the reset
      afterwards reports "Nothing to reset — the selected scope already reads empty".
- [x] **Whatever powers the reset gains are released on the failure path as well as the success
      path.** After the run, all 18 functions read no reservation and no `REVENTLESS_RESET_RECYCLE`.
      Verified in isolation too: `hold` → `recycle` → `release` on one function left its environment
      byte-identical and its reservation back to none. The wipe's outcome is captured as a value
      precisely so the abort path releases too, and `hold` rolls back its own partial work.
- [x] **If the reset cannot guarantee emptiness, it says which store refilled and what wrote to
      it — never "re-run to finish" for a condition that re-running cannot clear.** `refillMessage`,
      pinned by tests on both arms.
- [x] **The recycle actually drops the held state.** Measured — see the table in §5.
- [~] **The subsequent seed's one-shot precondition passes without manual intervention.** The
      precondition is `Seed.Runner.assertStoreEmpty`, and every store in scope reads empty — shown
      by the reset's own re-run above. The seed itself was not run: it authenticates to Cognito and
      the operator's credentials were not available to this session.

---

## Appendix: anchors (2026-08-09)

| Fact | Anchor |
| --- | --- |
| Truncate: key schema → projected scan → batch delete | `reventless/seed-aws/src/ReventlessSeedAws_Reset.res` — `truncateTable` |
| Unprocessed items are retried, then raised | same file — `sendBatch`, capped at 8 attempts |
| Post-wipe verification and its message | same file — the `refilled` accumulator and `refillMessage` |
| The hold / recycle / release cycle | `reventless/seed-aws/src/ReventlessSeedAws_Quiesce.res` |
| Container-lifetime TODO list | `reventless/core/src/components/AutomationSlice/AutomationSlice_Callback.res` — `let todoItems = Dict.make()` at module level |
| Whole-dict write-back on every invocation | `reventless/aws/src/adapter/Runtime/AutomationSliceEntryPoint_Ops.res` — `makeSyncTodoItems` |
| Once-per-container reload | same file — `makeLoadTodoItems`, guarded by `loaded` |
| The eventless sweep that triggers it | `AutomationSliceEntryPoint.mjs` — `event?.reventlessSweep`; EventBridge `rate(5 minutes)` |
| The writer observed | automation-slice runtime, `QueryDbStorage_DynamoDb_Runtime` — `save: saved state to …` |
