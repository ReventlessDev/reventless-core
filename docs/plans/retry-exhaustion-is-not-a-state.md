# Plan: a slice that has given up says so

**Date:** 2026-08-22
**Status:** **Implemented 2026-08-22** — all five steps. Found while making a `Geolocation` `Pending`
row hold still long enough to photograph, during
[done/semantic-geolocation.md](done/semantic-geolocation.md)'s browser walk.
Full build warning-free, 358 suites / 3634 tests green, GraphQL goldens refreshed, docs site builds.
Two decisions were taken differently from what is written below; both are recorded at their step.
**Repos:** `reventless-core` only.

**Goal.** When a slice's todo row exhausts its retries, that is a *state the row is in* and a *fact the
domain can act on* — not the absence of further activity.

**Non-goal.** Changing the retry policy: how many attempts, how they are spaced, whether they back off.
Three attempts may well be right. The question here is what happens after the third.

---

## The gap

`AutomationSlice_Callback` and `OutboundTranslationSlice_Callback` share one todo-row machinery: a row
carries `status: Pending | Processing | Completed | Failed`, a `retryCount`, and a `lastError`, and each
pass selects work with

```rescript
row.status == Pending || (row.status == Failed && row.retryCount < Spec.maxRetries)
```

([AutomationSlice_Callback.res:192-195](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Callback.res#L192-L195),
and the same line in `OutboundTranslationSlice_Callback`). When `retryCount` reaches `maxRetries` the
row stops matching. Nothing marks it, nothing publishes, nothing logs a decision. **The work is
abandoned by falling out of a filter.**

Two things follow, and the second is the serious one.

**`Failed` means two opposite things.** A row at `retryCount: 1` will be picked up on the next pass; a
row at `retryCount: 3` never will. Both read `Failed`. The todo is a queryable view — the deployed SDL
exposes `status`, `retryCount` and `lastError` on
`Ordering_GeocodeCustomerAddressTodo` — so an operator *can* tell them apart, by comparing `retryCount`
against a `maxRetries` that exists only in ReScript source they are not reading. A view that requires
knowing a constant in the code to interpret a status is not reporting a status.

**The domain is never told.** This is where it stops being a reporting problem. Abandonment is a real
outcome — "we asked four times and are not asking again" — and no command is published for it, so no
aggregate learns it and no read model reflects it.

## What it costs, in the one case that exists today

`GeocodeCustomerAddress_Translation` returns `Error` when the geocoder is unavailable
([GeocodeCustomerAddress_Translation.res:19](../../examples/online-shop-hybrid/ordering/src/Customer/OutboundTranslationSlice/GeocodeCustomerAddress_Translation.res#L19)),
deliberately: an outage is not a verdict about an address, so the row must not be marked
`Unresolvable`. That is right, and it is the reasoning
[done/semantic-geolocation.md](done/semantic-geolocation.md)'s D5 argues for at length. It holds for
attempts one through four. On the fifth pass there is no attempt, and the `Customers` row is still
`Pending({requestedFor})`.

So `Geolocation.Pending` now carries two meanings: *the geocoder will answer shortly* and *nobody is
going to ask again*. **That is precisely the collapse the type was introduced to undo** — D1's argument
was that `option<GeoPoint.t>` could not distinguish "has not run" from "ran and failed", and an
operator cannot act on a state that means two things. The union fixed it for the geocoder's *answers*
and the retry machinery reintroduced it underneath, for the geocoder's *silence*.

Reproduced on the deployed stack: an address the geocoder rejects outright (an over-long one) leaves a
customer in `Locating…` in the shell, indefinitely, with no indication that the wait is over.

## The decision this turns on

### D1. A terminal status, or a signal, or both

Three shapes, and they are not alternatives so much as increasing commitments.

| | What it adds | What it leaves undone |
| --- | --- | --- |
| **A. `Abandoned` status** | the todo view stops lying; `Failed` means "will retry" and `Abandoned` means "will not" | the domain still never hears; the read model still says `Pending` |
| **B. An exhaustion hook** | the slice maps abandonment onto a command of its own choosing | every slice must remember to implement it, and the ones that forget are exactly today's behaviour |
| **C. Both** | the view is honest *and* the domain can react | more surface, and B's per-slice question still has to be answered |

*Built as C, in one pass rather than two — see the note under Steps.*

**C, with A first.** A is a strictly-contained change to the shared callback — one arm of a status
variant and one filter — and it removes the misreporting on its own, for every existing slice, with no
spec change and nothing for a slice author to opt into. B cannot be retrofitted silently the way A can,
because a hook nobody implements changes nothing; it needs each slice to decide what abandonment
*means* for its domain, and that decision is the point rather than an obstacle.

Doing A alone would be defensible and is the natural first commit. Shipping B without A would not: the
domain would learn something the operator's own view still contradicts.

### D2. What the hook is allowed to return

The natural shape is the one `translate` already has — an optional command — so a slice that has
nothing to say returns `None` and behaves exactly as today. `GeocodeCustomerAddress` returns
`MarkAddressUnresolvable` with a reason naming the exhaustion rather than a candidate, which lands the
`Customers` row in `Unresolvable` and puts it in front of a human. That is the same event the confident
path already produces, so no new event type and no projection arm is owed.

**The temptation to resist** is a framework-level "abandoned" event published on the slice's behalf.
It would need a home in an event log that belongs to some aggregate, and the framework does not know
which — that is exactly the knowledge the per-slice hook has and the framework does not.

### D3. `maxRetries` becomes observable, or the view stays uninterpretable

Whatever else changes, a caller reading a todo needs to know the ceiling the count is racing. Cheapest
honest option: carry `maxRetries` on the todo row beside `retryCount`, so the two travel together and
the view needs no out-of-band constant. It is one field on a shape that already carries five.

*Built as an **optional** field, and it had to be.* Todo rows are not only written — the AWS entry
point rehydrates `Pending`/`Failed` rows from DynamoDB through `Util_Sury.fromJson`, and that restore
**swallows a decode failure per row** (`| exception _ => count`). A required field would therefore not
have failed loudly on rows written before it existed; it would have made them silently vanish from the
sweep, which is a worse version of the bug this plan is about.

## Steps

*One decision taken differently.* D1 argued A first and B after, and the reason A was safe to ship
alone still holds. What the plan had not priced is that **B cannot be added without deciding how a
slice that does not implement it compiles**: ReScript module types have no optional fields, so
`onExhausted` is either injected by the PPX (a source change, a local dune rebuild, a version bump in
the same commit and a republish lockstep for external consumers) or it is a **breaking module-type
change**. The breaking change was chosen deliberately: the seven in-repo slices were updated with it,
and an external slice fails to compile with "the value `onExhausted' is required but not provided",
which names the decision it has to make rather than defaulting it to silence.

1. ✅ **`Abandoned` in `todoStatus`**, in both callbacks that share the shape, plus the filter change
   (`Failed && retryCount < maxRetries` stays the selection; the transition at the ceiling writes
   `Abandoned` rather than `Failed`). Tests: a row at the ceiling is written `Abandoned`, is not
   selected on the next pass, and a row below the ceiling still is.

   *Two mechanisms, not one, and each is pinned separately.* The ceiling is marked at the **moment of
   the failing attempt**, which handles every row this build writes. A **normalising sweep** at the top
   of `phase2` also converts any `Failed` row already at or past the ceiling — what an older build left
   behind, and what a Spec that lowers `maxRetries` strands under itself. Mutation-checked: breaking
   the transition fails two tests, disabling the sweep fails a third.

   The AWS restore scan gets the change for free and improves: it reads `Pending`/`Failed` only, so an
   `Abandoned` row is no longer carried into memory to be filtered out on arrival.
2. ✅ **`maxRetries` on the todo row** (D3), and through to the generated view type.
3. ✅ **The exhaustion hook** (D2) on the two specs, defaulting to "no command", with the callback
   publishing what it returns exactly as the success path does.
4. ✅ **`GeocodeCustomerAddress` implements it**, mapping exhaustion to `MarkAddressUnresolvable` with a
   reason that says the geocoder never answered rather than that the address was ambiguous.
5. ✅ **Docs**: the slice guides, and the todo-status vocabulary wherever it is written down.

## Verification

- ✅ **A todo driven past its ceiling reads `Abandoned`** — unit-tested on both callbacks, and pinned
  by mutation. The GraphQL goldens moved with it: `Abandoned` on three todo status enums and
  `maxRetries: Float` on three todo types, and nothing else, which is the whole schema cost.
- ✅ **The hook is exercised in all four shapes it can take**: a slice that answers has its command
  published (with `meta.service` naming the target, the same rule the success path follows); a slice
  that stays silent publishes nothing and the row is still `Abandoned`; the hook is handed the
  `lastError` that ended it; and a **failed announcement leaves the row `Abandoned`** rather than
  dropping it back to `Failed`, since the budget is precisely what ran out.
- ✅ **A slice that answers `None` behaves exactly as before** bar the terminal status — which is what
  the two example slices that had nothing to say now assert by doing.
- ❌ **Not yet observed on a deployment.** The case that started this — an over-long address leaving
  the customer in `Unresolvable` with a reason rather than in `Locating…` forever — is a browser check
  against a deployed stack, and needs this released and deployed first. It is the deliverable, so it
  stays owed: "the row stops saying it is waiting" is only confirmable by a person looking at it.

## Out of scope

- **Retry policy.** Counts, spacing, backoff, per-error-class rules. Untouched.
- **A dead-letter path for todos.** `Abandoned` rows stay where they are; sweeping, re-driving or
  expiring them is a separate question and wants asking once the state exists to sweep *on*.
- **`StateChangeSlice`'s `maxRetries`.** Same word, unrelated mechanism — it counts DCB append-conflict
  retries inside a single command, not passes over a durable todo.

## Follow-ups

- **Release note.** `onExhausted` is a required field on two published module types, so a consumer
  writing their own AutomationSlice or OutboundTranslationSlice gets a compile error until they declare
  it. That is the intended prompt, but it is a major-version conversation and wants saying out loud in
  the changelog rather than discovered at a build.

- **Re-driving an abandoned todo** is the obvious next request, and the first thing that will show
  whether `Abandoned` should be a status or a status plus a timestamp.
- **The operator's queue** in [done/semantic-geolocation.md](done/semantic-geolocation.md) gets a second
  source of rows from this: addresses nobody is still working on, alongside addresses that came back
  ambiguous.
