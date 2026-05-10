# Plan: Propagate Aggregate `decide` Errors as `Rejected`

**Analysis**: [aggregate-command-handling-review.md](../../analysis/aggregate-command-handling-review.md) — Correctness §"Decide errors silently log and continue"
**Sibling**: closed gap on the DCB path in commit `c0942696b`.

## Problem

In [`Aggregate_Callback.processCommand`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L57-L73), a domain rejection from `Behavior.decide` is logged and the accumulator is returned **unchanged**:

```rescript
| Error(error) =>
  let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
  let id = command'.id->Spec.Id.toString
  EffectLogger.logError(~comp, `decide error: ${errorJson} id=${id}`)->Effect.runSync
  Ok((state, events))
```

Net effect: a domain rejection (e.g. `OrderAlreadyShipped`, `ProductNotFound`) ends up indistinguishable from a successful no-op command. The producer's path:

- **Async (SQS FIFO)**: handler returns `Ok(reference)` for the rejected command → message deleted → producer never learns.
- **Sync (`runInlineAndCollect`)**: `acceptedResultChannel` is keyed only on `entityId/eventCount`, no error code; sync producers see `Accepted({eventCount: 0})`. Indistinguishable from an idempotent re-submit.

The DCB path closed the equivalent gap by routing decide errors into a `Rejected` outcome carrying the encoded error JSON. The Aggregate path needs the same shape.

## Goals

- A producer that submits an Aggregate command receives `Rejected({msgId, errorCode, errorDetail})` whenever `Behavior.decide` returns `Error`.
- Async (SQS) producers see the message removed from the queue **after** a `Rejected` is reported (don't retry domain rejections — they're not transient).
- Within a batch of N commands for the same aggregate, a single rejected command does not cancel the surviving commands; they still produce events and report `Accepted`.
- Error JSON shape matches the DCB conventions so downstream UI / logging is unified.

## Non-goals

- Distinguishing "no events produced because invariant satisfied" (a happy idempotent no-op) from a `decide` returning `Ok([])`. Those genuinely look the same to the producer; that's by design.
- Re-classifying decide errors as `Conflict` and retrying. Domain errors are deterministic; retry never helps.
- Routing rejected commands to a DLQ. Producer-side handling is enough; DLQ adds operational surface without value here.

## Approach

Three changes, layered:

### 1. Carry rejection info through the accumulator

Replace the simple `(state, events)` accumulator with a richer one that records per-command outcomes:

```rescript
type cmdOutcome =
  | CmdOk(array<event>)
  | CmdRejected({errorCode: string, errorDetail: string})

// accumulator: (state, array<(reference, cmdOutcome, meta)>)
```

`processCommand` produces a `CmdRejected` rather than swallowing the error. The reduce stays in `Effect.succeed(Ok(...))` shape — no rejection short-circuits subsequent commands.

### 2. Add a `rejectedResultChannel` side-channel

Mirror [`acceptedResultChannel`](../../reventless/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res#L17) with a sibling `rejectedResultChannel`:

```rescript
let rejectedResultChannel:
  ref<option<(string, {errorCode: string, errorDetail: string}) => unit>> = ref(None)

let reportRejected = (reference, info) =>
  rejectedResultChannel.contents->Option.forEach(cb => cb(reference, info))
```

`runInlineAndCollect` ([CommandTopic_Helpers.res:44-72](../../reventless/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res#L44-L72)) sets both channels, and synthesises the final `commandOutcome` per `msgId`: rejected entries take precedence, then accepted entries, fallback Pending.

### 3. Route per-reference outcomes from `replayProcessAppend`

After the append completes, walk the accumulator:

- For `CmdOk(events)` references: `reportAccepted` (existing path).
- For `CmdRejected({errorCode, errorDetail})` references: `reportRejected`, and **return `Ok(reference)`** in the per-command result array (so SQS deletes the message — domain rejections don't redeliver).

Async (SQS) consumers still see the message removed; producers awaiting `runInlineAndCollect` get `Rejected({msgId, errorCode, errorDetail})`.

## Steps

### Step 1 — Refactor accumulator shape

In [`Aggregate_Callback.res`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res):

- Define `type cmdOutcome` (above).
- Update `processCommand` to return `CmdOk(events)` or `CmdRejected({errorCode, errorDetail})`. Encode the error to JSON once; extract `errorCode` from the variant tag (re-use `Message.variantNameOfJson` on the encoded error JSON), `errorDetail` from the rest of the encoded payload.
- Update the reduce to push `(reference, cmdOutcome, meta)` per command.

### Step 2 — Add `rejectedResultChannel` and `reportRejected`

In [`CommandTopic_Helpers.res`](../../reventless/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res):

- Define `rejectedResultChannel` and `reportRejected`.
- Update `runInlineAndCollect` to set both channels and compose the final `commandOutcome` per reference. Rejected wins over Accepted (a reject is always more informative than an accept of zero events).

### Step 3 — Wire into `replayProcessAppend`

After the append succeeds:

- For each `(reference, CmdOk(events), _)`: existing `reportAccepted` flow.
- For each `(reference, CmdRejected({errorCode, errorDetail}), _)`: `reportRejected(reference, ...)`. Result entry is `Ok(reference)` so SQS deletes the message.

### Step 4 — Tests

`reventless/reventless-core/tests/components/Aggregate/Aggregate_CallbackTest.res` (or a fresh `Aggregate_RejectionTest.res`):

- Single-command batch where `decide` returns `Error` → handler returns `Ok(reference)` and `acceptedResultChannel`/`rejectedResultChannel` shows the `Rejected` shape.
- Mixed batch: 3 commands, command 2 rejects → commands 1 and 3 produce events and append, command 2 reports `Rejected`. Surviving events appended in one batch.
- All-reject batch (3 rejects, no events) → no append call, all three reported as `Rejected`.
- Round-trip via `runInlineAndCollect` from `CommandTopic_HelpersTest.res` — confirm `commandOutcome` shape.

Update existing slice / aggregate GWT tests as needed.

### Step 5 — Examples and docs

- Update example aggregates' GWT tests in `examples/online-shop-aggregates/*` if any rely on the silent-swallow behaviour (none expected — those tests usually assert on events, not on `Rejected`).
- Document the rejection contract in [`docs/reventless-components/aggregate.md`](../../reventless-components/aggregate.md): "If `decide` returns `Error`, the producer receives `Rejected({errorCode, errorDetail})`. SQS messages corresponding to rejected commands are removed from the queue (no redelivery)."
- Move this plan to `done/` and update the analysis to mark resolved.

## Open questions

- **`errorCode` extraction.** Today `Spec.errorSchema` defines a variant. The encoded JSON's first key is the variant tag. Use `Message.variantNameOfJson` for that, mirroring how `eventDetail` extracts event names. If a spec uses `unit` errors (no payload), `errorDetail` is empty string — fine.
- **What about non-Aggregate command paths?** StateChangeSlice already does this (the model for this fix). Other paths that call `processCommand`-shaped logic are inheriting from these two; double-check `AutomationSlice` doesn't have its own copy.

## Status

Done. Implemented in this PR:

- `CommandTopic_Helpers.res` — added `type rejectedResult`, `rejectedResultChannel`, `reportRejected`. `runInlineAndCollect` now sets both channels and gives `rejectedResultChannel` precedence over both `Accepted` and the synthesized `"Conflict"` Rejected.
- `Aggregate_Callback.res` — replaced the `result<(state, events), error>` accumulator with a `(state, array<(reference, cmdOutcome, meta)>)` shape. `processCommand` now records `CmdOk(events)` / `CmdRejected({errorCode, errorDetail})` and never short-circuits. New `reportFinalOutcomes` walks the outcomes after append, calling `reportAccepted` for `CmdOk` and `reportRejected` for `CmdRejected`. Rejected refs always return `Ok(reference)` (SQS deletes — domain rejections aren't transient). The dead `Error(error) => JsError.throwWithMessage(error)` branch and `Error(_) as error` short-circuit branch are gone (also closes the `aggregate-remove-dead-error-branches` plan in the same change).
- `StateChangeSlice_Callback.res` — decide-error branch now extracts `errorCode`/`errorDetail` and calls `reportRejected` on the same channel.
- Tests — `tests/aggregate/AggregateRejectionTest.res` (4 cases: single rejection, mixed batch, all-reject, payload-less variant) and `tests/commandtopic/CommandTopicHelpersRejectionTest.res` (3 cases: precedence over Accepted, precedence over Error→Conflict, fallback to Conflict).
- Docs — `aggregate.md` "Rejection contract" subsection; analysis doc marked resolved.
