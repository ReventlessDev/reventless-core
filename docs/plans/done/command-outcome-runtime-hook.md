# Plan: a runtime hook for command outcomes

**Date:** 2026-08-08
**Status:** Done — 2026-08-08. Implemented as planned; anchors below verified against the code as
landed.
**Repos:** `reventless-core` only.

**Builds on** [done/runtime-extension-seam.md](done/runtime-extension-seam.md), which shipped the
cold-start registration path for out-of-tree runtime hooks. That plan's non-goal was explicit — "any
new hook. This adds the missing registration path for hooks that already exist." This adds the hook.

## Why

Of the four runtime hooks an extension can now register, none can observe what a command actually
did:

| Hook | Position |
| --- | --- |
| `CommandGenerator_Callback.registerCommandInterceptor` | A **gate**, before dispatch — `Allow \| Deny(string)`, returns before `Behavior.decide` runs |
| `QueryDb_Callback.registerQueryInterceptor` | Read side |
| `EventPublish_Callback.registerBeforePublish` / `registerAfterPublish` | The event path — and a **refused command publishes no event** |

So the framework can be asked to authorise a command, and can be told about the events that
followed one, but cannot be asked what became of the command itself. Concretely, a domain rejection
today produces one `EffectLogger.logError` line (`Aggregate_Callback.res:93-96`) and nothing else
structured. There is no way for an extension to answer:

- how often a given command is refused, and with which declared error;
- how many events a command actually produced, attributed to the command that caused them;
- whether a refusal was a **domain** decision or an infrastructure failure.

Those are ordinary operational questions — a rejection rate per command is a health signal, and a
refusal that is a bug looks identical to one that is the model working correctly unless the error
code is visible. The data exists; nothing can reach it.

## The datum already exists, at one chokepoint

Both write-side kinds already funnel every terminal command outcome through two functions in
`CommandTopic_Helpers.res:31-34`:

```rescript
let reportAccepted = (reference, result: acceptedResult) =>
  acceptedResultChannel.contents->Option.forEach(cb => cb(reference, result))

let reportRejected = (reference, result: rejectedResult) =>
  rejectedResultChannel.contents->Option.forEach(cb => cb(reference, result))
```

Called from `Aggregate_Callback.res:287,290,293` (`reportFinalOutcomes`) and
`StateChangeSlice_Callback.res:324,375`. Two properties make this the right site rather than a
convenient one:

1. **The call is unconditional; only the forwarding is not.** The side-channels exist for
   `publishJsonsAndWait` propagation and are `None` on the asynchronous path — but the *call* happens
   on every dispatch, so a hook placed inside these functions sees every outcome, not just the ones a
   caller waited for.
2. **It is already the single convergence point.** Both write-side component kinds reach it, so one
   hook covers aggregates and state-change slices without touching either callback's decision logic.

The outcome vocabulary is likewise already shaped: `commandOutcome` is
`Accepted({msgId, entityId?, eventCount}) | Rejected({msgId, errorCode, errorDetail}) | Pending({msgId})`,
and `errorCode` is the variant tag of the component's `Spec.errorSchema`.

## Change

1. **`CommandTopic_Helpers` gains a fifth hook** in the established shape — a module-level
   `ref<option<…>>`, a `registerCommandOutcome`, a `clearCommandOutcome`, defaulting to passthrough,
   exactly like the four the cold-start seam already reaches. It therefore needs **no new
   registration path**: an extension registers it from `onColdStart` alongside the others.

2. **Fire it from `reportAccepted` / `reportRejected`**, beside the existing side-channel forward.

3. **Carry the component identity.** The helpers take only `reference` and the result today, and an
   outcome is not interpretable without knowing which component produced it. Both call sites know it
   (`Spec.name`), so the two helpers grow a `~component` argument — an internal signature change with
   call sites in exactly two files.

4. **Keep domain rejections distinguishable from infrastructure failures.** `reportRejected` is
   *also* used for `AppendFailed` (`Aggregate_Callback.res:292-296`) — a storage failure, not a
   decision. A consumer that cannot tell the two apart would report a broken event log as a business
   rejection. The hook must mark which it is rather than leaving a consumer to pattern-match on the
   string `"AppendFailed"`.

## Rejected alternatives

- **At the `CmdRejected` construction sites** (`Aggregate_Callback.res:97`,
  `StateChangeSlice_Callback.res:429`). Two files instead of one, and it sees only the refusal half —
  losing the symmetry that makes `Accepted({eventCount})` observable from the same hook.
- **Beside the existing interceptor, at `CommandGenerator_Callback.res:143-149`**, where outcomes
  already return from `publishJsonsAndWait`. Appealingly symmetric with the pre-dispatch gate, but
  `publishJsonsAndWait` is an *optional* argument: a fire-and-forget command never returns an outcome
  there and would go unobserved. A hook whose coverage depends on how the caller dispatched is worse
  than no hook, because the gap is invisible.

## Non-goals

- **No new registration path.** That shipped; this is one more hook on it.
- **No aggregation, persistence or transport.** The hook reports one outcome, synchronously, and
  returns. What an extension does with it is the extension's business — the same division the four
  existing hooks keep.
- **No change to what callers receive.** `commandOutcome` and the GraphQL `CommandResult` union are
  untouched; this is an observation point, not a new result shape.
- **No change to decision logic.** `Behavior.decide` and both callbacks' control flow are unmodified.

## Acceptance

- An extension registered through the cold-start seam observes every terminal command outcome for
  aggregates and state-change slices, on both the awaited and the fire-and-forget dispatch paths.
- Each observation carries the owning component, the command's outcome, and — for a refusal — the
  error code, with domain rejections distinguishable from infrastructure failures.
- With no extension registered, the hot path is unchanged: one `ref` read against `None`, the same
  cost the other four hooks pay.
- The existing callback and command-topic tests pass untouched; new coverage pins that the hook fires
  on the asynchronous path, which is the property the side-channel does not have.

---

## As built

The shape, in `CommandTopic_Helpers` (re-exported by `CommandTopic`, and through it by
`reventless-local`'s re-export, so both platforms reach it under one name):

```rescript
type refusalCause = DomainRejection | InfrastructureFailure

type observedOutcome =
  | OutcomeAccepted({entityId: option<string>, eventCount: int})
  | OutcomeRejected({errorCode: string, errorDetail: string, cause: refusalCause})

type commandOutcomeReport = {component: string, reference: string, outcome: observedOutcome}

let registerCommandOutcome: (commandOutcomeReport => unit) => unit
let clearCommandOutcome: unit => unit
```

Where the shipped shape resolves something the plan left open:

- **Constructors are prefixed `Outcome*`.** `commandOutcome` — the producer-facing result and the
  GraphQL `CommandResult` union — lives in the same module and already owns `Accepted`/`Rejected`.
  Reusing those names would have shadowed it for the code below, and the plan's non-goal was that
  `commandOutcome` stay untouched. Distinct names keep both readable with no annotation games.
- **`~cause` is a required argument, not a defaulted one.** A default would let a rejection site
  added later report infrastructure as a domain decision by saying nothing. Required, the compiler
  makes each of the four rejection sites state which it is.
- **A throwing hook is logged and swallowed.** The outcome it observes has already happened, so
  letting an observer fail a settled command would turn an extension into an outage — the same
  failure policy §5.4 of the cold-start seam settled on.

## Acceptance, as verified

| Criterion | Evidence |
| --- | --- |
| Every terminal outcome observed for both write-side kinds, on both dispatch paths | `CommandOutcomeHookTest` — no side-channel is installed anywhere in the file, so every case runs the fire-and-forget path; aggregate and slice arms both covered |
| Observation carries owning component, outcome, and error code | Asserted per case as `(component, reference, disposition, errorCode, eventCount)` |
| Domain rejections distinguishable from infrastructure failures | Aggregate: `decide` → `AlreadyExists`/`DomainRejection` vs `failNextAppend` → `AppendFailed`/`InfrastructureFailure`. Slice: `ItemAlreadyExists`/`DomainRejection` vs exhausted retries → `Conflict`/`InfrastructureFailure` |
| Reachable from the cold-start seam with no new registration path | `CommandOutcomeHookTest` — "an out-of-tree extension can register it from onColdStart" registers inside `onColdStart`, then a later command is observed |
| Unregistered hot path unchanged | "with nothing registered nothing is observed and the command is unaffected" — one `ref` read against `None` |
| Existing tests pass untouched | Full suite green: 311 suites / 2806 tests across 16 jest projects (was 310 / 2794; +1 suite, +12 tests, all new). Full root build, zero warnings |

**Not verified on real AWS.** Same standing as the cold-start seam it builds on: covered by unit
tests, but no extension has yet consumed it on a live stack.

## Appendix: code anchors (as landed, 2026-08-08)

| Fact | Anchor |
| --- | --- |
| The hook, and the fire point | `CommandTopic_Helpers.res` — `registerCommandOutcome` / `fireCommandOutcome`, called from `reportAccepted` / `reportRejected` |
| Aggregate call sites (domain, accepted, append failure) | `Aggregate_Callback.res` — `reportFinalOutcomes` |
| Slice call sites (accepted ×2, exhausted append, domain) | `StateChangeSlice_Callback.res` — `handleSingleCommand` |
| Coverage | `reventless/core/tests/commandtopic/CommandOutcomeHookTest.res` |
| User-facing documentation | `packages/doc/docs-infrastructure/callback-hooks-and-adapter-wrapping.md` § Command Outcome |
