# Plan: Preserve Command `msgId` as Event `causationId`

**Analysis**: [aggregate-command-handling-review.md](../../analysis/aggregate-command-handling-review.md) — Correctness §"Meta `msgId` is rewritten on every retry"

## Problem

[`Aggregate_Callback.updateMeta`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L48-L52) regenerates `msgId` and `time` per attempt:

```rescript
let updateMeta = (command') => {
  ...command'.meta,
  time: Message.nowAsISOString(),
  msgId: Message.uuid(),
}
```

The new `msgId` ends up on the durable event's `meta` field. Two consequences:

1. **Lost causation**: a downstream consumer cannot trace an event back to the producing command via `msgId`. The producer issued command `c1` with `msgId = X`; the durable event has `meta.msgId = Y` (a fresh UUID generated inside the Aggregate). Correlation is unrecoverable from the event alone.
2. **Retry asymmetry**: on retry-after-partial-write (current behaviour, see sibling plan [aggregate-multi-event-atomic-append.md](aggregate-multi-event-atomic-append.md)) the surviving event from attempt 1 has `msgId = Y1` and any new event from attempt 2 has `msgId = Y2`, even though they belong to the same logical command.

The producer's `msgId` is preserved as the SQS `topicItem.reference` for routing only — it never lands in durable storage.

## Goals

- Every durable event carries the original command's `msgId` as `causationId`.
- The event's `meta.msgId` remains a unique-per-event identifier (not the command's), preserving the existing convention that `meta.msgId` is the event's own ID.
- No format change to `meta` that breaks existing decoders — additive only.
- Re-tries don't churn the `causationId`: it's set once from the producer's command and never overwritten.

## Non-goals

- Renaming `meta.msgId`. Existing code reads it; rename is breaking. Add a sibling field instead.
- Plumbing a full chain (`correlationId` across multiple causations). That's a larger Event Modeling-level concern; one hop (command→event) is enough to close the immediate gap.

## Approach

Add a `causationId: option<string>` field to `Message.meta`. Populate from the command's `meta.msgId` at the point where events are stamped, leaving the existing `meta.msgId` regeneration untouched.

### Message.meta changes

In `reventless/reventless/src/Message.res`:

```rescript
@schema
type meta = {
  ...,
  msgId: string,
  time: string,
  @s.optional causationId?: string,  // NEW
}
```

`@s.optional` keeps the schema backwards-compatible — events written before the change decode fine (causationId is `None`).

### Aggregate stamping

In [`Aggregate_Callback.updateMeta`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L48-L52):

```rescript
let updateMeta = (command') => {
  ...command'.meta,
  time: Message.nowAsISOString(),
  msgId: Message.uuid(),  // event-specific
  causationId: Some(command'.meta.msgId),  // command's msgId
}
```

### Replay decoding

[`EventLog_Operations.decodeEvent`](../../reventless/reventless-core/src/components/EventLog/EventLog_Operations.res#L155-L175) and `Message.decomposeMeta`/`combineMessage` handle `meta` shape — confirm `causationId` round-trips through encode/decode without loss.

## Steps

### Step 1 — Add `causationId` to `Message.meta`

In `reventless/reventless/src/Message.res`:

- Add the optional field to the `meta` record and its schema.
- Update `decomposeMeta` and `nowAsISOString` callers if the field needs explicit handling.

### Step 2 — Stamp `causationId` in `Aggregate_Callback.updateMeta`

Update the function as above. No other Aggregate code change needed.

### Step 3 — Stamp `causationId` in StateChangeSlice and other command-handling paths

Same pattern. Find all sites that build event meta from a command:

- `StateChangeSlice_Callback.handleSingleCommand` (DCB path).
- `AutomationSlice_Callback` if it stamps event meta.
- Any other inbound translation slice that produces events.

Each preserves the producer's `msgId` as the event's `causationId`.

### Step 4 — Tests

In `reventless/reventless/tests/MessageTest.res`:

- `meta` round-trip with and without `causationId` set — both decode correctly.
- Old-format meta (no `causationId` key) decodes with `causationId = None`.

In `reventless/reventless-core/tests/components/Aggregate/Aggregate_CallbackTest.res`:

- A command with `meta.msgId = "cmd-123"` produces an event whose stored `meta.causationId = Some("cmd-123")` and whose `meta.msgId` is a fresh UUID.
- A multi-event command (5 events) → all 5 events share the same `causationId`, distinct `msgId`s.

In `reventless/reventless-core/tests/components/StateChangeSlice/*Test.res`:

- Same shape for the DCB path.

### Step 5 — Examples and docs

- Update [`docs/inner-workings/messages.md`](../../inner-workings/messages.md) to describe `causationId`.
- Note in [`docs/reventless-components/aggregate.md`](../../reventless-components/aggregate.md) that consumers can correlate events to commands via `meta.causationId`.

Move plan to `done/`. Update analysis to mark resolved.

## Open questions

- **What about `correlationId` (the broader chain)?** Out of scope for this plan. `causationId` covers the immediate command→event hop; `correlationId` for multi-hop traces (command → event → policy-triggered command → event) is a separate decision. If/when added, it should propagate through `meta` like `causationId`.
- **Should `causationId` be required (not optional)?** Existing stored events don't have it, so making it required breaks decode. Keep optional. New writes always populate it; old reads degrade gracefully.
- **What if a slice produces events without a causing command** (e.g. scheduled task)? `causationId = None`. The downstream consumer infers "spontaneous event" from the absence.

## Status

Not started.
