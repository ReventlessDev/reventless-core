# Plan: Make OutboundTranslationSlice run on the local platform

**Status:** Done (2026-07-24) — root cause was an un-unwrapped event envelope; all five
steps landed and every acceptance criterion is met. See "Outcome" below.
**Origin:** [online-shop-hybrid-demo-data.md](online-shop-hybrid-demo-data.md) — the one acceptance criterion that plan could not meet. Also flagged as out-of-scope-but-open by [online-shop-hybrid-order-lifecycle.md](online-shop-hybrid-order-lifecycle.md).

The `SendOrderConfirmation` OutboundTranslationSlice in the hybrid example's
Ordering plugin does not run at all on the local platform. Measured across a
seeded run of 150 orders:

- 150 `OrderPlaced` events appended;
- `SendOrderConfirmationTodos` holds **0 rows** — phase 1 `collect` never fires,
  so this is not the 60s heartbeat waiting to drain phase 2;
- **0** `EmailService` calls;
- the `AutoShipOrder` AutomationSlice, consuming the *same* events from the
  *same* DCB event topic, produces its full set of rows.

A component that silently does nothing is worse than one that fails: the
example's Event Graph draws `SendOrderConfirmation` reaching an external
`EmailService` box, its GWT tests pass, and its TODO view exists and is
queryable — every signal a reader has says it works.

---

## Motivation

OutboundTranslationSlice is a shipped framework component with an example, a
docs entry and a test suite, and on the only platform anyone develops against
it is inert. Whatever the cause, the same class of gap can hide in any
component whose only coverage is callback-level.

### What has been ruled out by reading the code

Recording these so the investigation does not re-walk them:

- **Not composition.** The generated
  [`Plugin.res`](../../examples/online-shop-hybrid/ordering/src/Plugin.res)
  builds `SendOrderConfirmationSlice` and passes it in both
  `makePluginDefinition(~outboundTranslationSlices=…)` and
  `make(~outboundTranslationSlices=…)`.
- **Not the topic it is given.**
  [`Dcb_Builder.res`](../../reventless/core/src/components/Dcb/Dcb_Builder.res)
  constructs each outbound slice with `~dcbEventLog` — the plugin's own DCB
  event log, which is where `OrderPlaced` lands.
- **Not the `allEventTopics` dict key.**
  [`OutboundTranslationSlice_Builder.res`](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Builder.res)
  keys its single-entry topic dict by `Spec.name`, where AutomationSlice keys by
  `<pluginName>DcbEventLog`. Locally this cannot be the cause:
  [`LocalEventCollectorChannel.connect`](../../reventless/local/src/adapter/EventCollector/LocalEventCollectorChannel.res)
  subscribes on `resource.name` from the topic outputs and ignores the dict key.
  It is still an inconsistency worth resolving (see step 4) and it may well
  matter on AWS.
- **Not `finish`.** `EventCollectorRuntimeBuilder.finish` is bound but never
  called in either the outbound *or* the automation builder, and the local
  implementation is `() => ()`.
- **Not source dispatch.** `AutomationSlice_Callback` filters events by
  `meta.service == sourceName`; the outbound callback has no such dispatch —
  `phase1` folds over whatever it is handed.
- **Not single-subscriber routing.** `LocalBus.subscribeToEventStream` is
  PubSub-hub based and supports many subscribers per topic.

### Where to look

The two surviving candidates, in order:

1. **Decode.** The handler does `Message.splitMessage` then
   `DcbDecode.makeDecoder(Spec.consumedEventSchema).decode`. The slice declares
   `OrderPlaced({orderId, customerId})`
   ([`SendOrderConfirmation.res`](../../examples/online-shop-hybrid/ordering/src/Order/OutboundTranslationSlice/SendOrderConfirmation.res))
   while the appended event carries `{orderId, customerId, productIds,
   shippingMethod}`
   ([`PlaceOrder.res`](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder.res)).
   Field-subset decoding is supposed to be supported and a failure warns
   (`DcbDecode: dropped event … drift?`) — so check the console output of a
   seeded run first. Its absence rules this out in one run; its presence
   *is* the answer.
2. **Subscription timing.** The outbound slice creates its EventCollector inside
   `queryDb->Component.operations->Pulumi.Output.apply(…)`. If that Output
   resolves after publishing starts, early events are missed — and since
   `phase1` is the only writer to the TODO list, missing *all* of them means
   zero rows. Instrument the point where `LocalEventCollectorChannel.connect`
   registers the drain relative to the first publish.

Note also a latent second defect in the same builder, independent of the above:
`publishJsons` is resolved through a side-effect `ref` (`publishJsonsRef`) while
AutomationSlice deliberately captures it via `Output.all2` — its comment records
that the ref shape "silently dropped Phase 2" when it raced the first event.
The outbound builder still has the shape that was fixed there. It will bite as
soon as phase 1 works.

## Steps

1. **Reproduce and root-cause.** Run the hybrid local platform, seed with
   `pnpm run demo-data`, and instrument the slice's handler: log on stream
   arrival (before decode), on decode result, and on `phase1` entry. Capture
   whether events arrive at all. Follow the two candidates above in order.
   Everything downstream depends on which one it is — do not pre-commit to a
   fix shape here.
2. **Fix the cause.** Scope stays inside
   `OutboundTranslationSlice_Builder` / `OutboundTranslationSlice_Callback` and,
   if the cause is decode drift, the example's `consumedEvent` declaration.
3. **Adopt the AutomationSlice `Output.all2` shape** for `publishJsons` so
   phase 2 cannot race the first event — the fix already proven in
   [`AutomationSlice_Builder.res`](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Builder.res).
   Do this even if step 1 lands elsewhere; the ref shape is a known-bad pattern
   carrying a comment that says so in its sibling.
4. **Harmonise the topic-dict key** with the AutomationSlice convention
   (`<pluginName>DcbEventLog`), and check whether the AWS EventCollector runtime
   routes by dict key — if it does, this is the same bug waiting on the
   deployed side.
5. **Cover it with a platform-level test.** The existing coverage
   ([`OutboundTranslationSliceCallbackTest.res`](../../reventless/local/tests/components/outboundtranslationslice/OutboundTranslationSliceCallbackTest.res))
   calls `phase1` / `phase2` directly and passes while the component is inert —
   it cannot observe wiring. Add a test that publishes an event through a
   running local platform and asserts a TODO row appears, mirroring whatever
   the AutomationSlice equivalent does.

## Acceptance

- A seeded hybrid run produces `SendOrderConfirmationTodos` rows — one per
  `OrderPlaced` admitted by `collect` — and a matching count of `EmailService`
  calls.
- Rows reach `Completed` (phase 2 drains) without waiting on the heartbeat.
- The demo-data seeder's warning about the empty view is removed, and its
  "non-empty grids on every queryable view" check covers all 9 views.
- New platform-level test green; full suite green; zero build warnings.

## Risks

- **The fix may be in the example, not the framework.** If it is decode drift,
  the framework behaved correctly and the example's `consumedEvent` was wrong —
  in which case the real deliverable is making that failure *loud*, since a
  warning on the console was not enough to stop it shipping.
- **AWS is unverified either way.** Nothing here demonstrates the deployed path
  works; step 4 is the only place this plan looks at it. If AWS turns out to be
  broken too, split it rather than growing this plan.

---

## Outcome (2026-07-24)

**Root cause: neither surviving candidate.** It was the event envelope.

Events travel the topic as `{id, meta, event}` envelopes (`Message.composeEventJson'`).
Every other consumer unwraps the inner `event` before splitting —
`AutomationSlice_Callback.phase1` does it with a comment saying why, and
`StateViewSlice_Builder` does the same. `OutboundTranslationSlice_Builder` called
`Message.splitMessage` on the **envelope**, which has no `TAG` key, so `splitMessage`
returned its `"Unknown"` fallback, `DcbDecode` missed the lookup, and the event was
dropped by the `| None => None` arm.

That arm is silent by construction: the `DcbDecode: dropped event … drift?` warning
only fires in the `WithFields` **parse-failure** branch, never on an unknown tag. So
step 1's "check the console for the warning first" heuristic could not have found it —
the absence of the warning was consistent with both the working and the broken case.

Candidate 1 (decode drift) was ruled out directly: driving `DcbDecode.makeDecoder`
with `SendOrderConfirmation`'s `consumedEventSchema` and the exact four-field
`OrderPlaced` payload decodes cleanly to the two-field subset. Field-subset decoding
works as documented. Candidate 2 (subscription timing) never came into play.

### What landed

| Step | Outcome |
|---|---|
| 1 | Root-caused via a new platform-level fixture rather than a seeded run — reproduced the zero-row symptom in 0.6s. |
| 2 | Unwrap `event` before `splitMessage` in `OutboundTranslationSlice_Builder`, matching `StateViewSlice_Builder`. |
| 3 | `publishJsonsRef` replaced by the `Output.all2` capture; the now-unused `Logger.fromEnv()` and its `publishJsons not yet resolved` error path are gone with it. |
| 4 | Key harmonised to `<pluginName>DcbEventLog`, derived from the DcbEventLog component's own resource name. |
| 5 | `OutboundTranslationSlicePlatformTest` + fixtures, modelled on `AutomationSliceSelfDeadlockFixtures`. |

### Step 4's open question, answered

**AWS does not route by dict key** — `EventCollectorChannel_Helpers.toResources` reads
`Dict.valuesToArray`, and both the SQS and DynamoDbStream channels merge specs with
`Dict.assign` before using values only. So this was *not* the same bug waiting on the
deployed side; the deployed path was never broken by the key.

The key still mattered for a lesser reason, which is why it was harmonised anyway:
`Dict.assign` merges channel specs by key, so a slice-specific key makes one shared
topic appear once **per slice** instead of collapsing to a single entry the way
AutomationSlice's convention does.

### Coverage note

The gap this plan set out to close was structural, and the new test is the part that
closes it: `OutboundTranslationSliceCallbackTest` called `phase1`/`phase2` directly and
stayed green through the entire outage. The new test publishes a command through the
real chain — StateChangeSlice → DcbEventLog → event topic → EventCollector → phase 1 →
phase 2 — and asserts on the recorded external call, so nothing between the topic and
the translation can go inert silently again. It records `collect` and `translate` calls
separately so a regression says which phase stalled.

### Acceptance

- ✅ Seeded hybrid run: `Ordering_SendOrderConfirmationTodos` = **150 rows**, one per
  `OrderPlaced`, and **150** `[EmailService]` calls in the platform log — was 0 and 0.
- ✅ All 150 rows `Completed` with `retryCount` 0; phase 2 drained without the 60s heartbeat.
- ✅ Seeder carve-out removed — `Unfillable` → `Seeded`, all **9 of 9** views non-empty
  and the run ends with no warning. The example README's "one view the seed cannot fill"
  paragraph is gone too.
- ✅ Full suite green: **192 suites / 1419 tests**. Zero build warnings.

### Not done here

Nothing demonstrates the **deployed** path end-to-end. The envelope fix is
backend-agnostic (it is upstream of any channel) and AWS routing was cleared by
reading, but no AWS run exercised an OutboundTranslationSlice. Worth a rung on the
next real-AWS pass rather than a plan of its own.
