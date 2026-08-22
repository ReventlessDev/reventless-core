# Plan: a slice that has given up says so

**Date:** 2026-08-22
**Status:** Proposed — nothing implemented. Found while making a `Geolocation` `Pending` row hold still
long enough to photograph, during
[done/semantic-geolocation.md](done/semantic-geolocation.md)'s browser walk.
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

## Steps

1. **`Abandoned` in `todoStatus`**, in both callbacks that share the shape, plus the filter change
   (`Failed && retryCount < maxRetries` stays the selection; the transition at the ceiling writes
   `Abandoned` rather than `Failed`). Tests: a row at the ceiling is written `Abandoned`, is not
   selected on the next pass, and a row below the ceiling still is.
2. **`maxRetries` on the todo row** (D3), and through to the generated view type.
3. **The exhaustion hook** (D2) on the two specs, defaulting to "no command", with the callback
   publishing what it returns exactly as the success path does.
4. **`GeocodeCustomerAddress` implements it**, mapping exhaustion to `MarkAddressUnresolvable` with a
   reason that says the geocoder never answered rather than that the address was ambiguous.
5. **Docs**: the slice guides, and the todo-status vocabulary wherever it is written down.

## Verification

- A todo driven past its ceiling reads `Abandoned`, in a unit test and in the deployed view.
- **The case that started this**: an over-long address on the deployed stack leaves the customer in
  `Unresolvable` with a reason, not in `Locating…` forever. This is a browser check, because "the row
  stops saying it is waiting" is the whole deliverable and only a person looking at it can confirm the
  wait reads as over.
- A slice that implements no hook behaves exactly as before — the same commands, the same todo rows
  bar the terminal status.

## Out of scope

- **Retry policy.** Counts, spacing, backoff, per-error-class rules. Untouched.
- **A dead-letter path for todos.** `Abandoned` rows stay where they are; sweeping, re-driving or
  expiring them is a separate question and wants asking once the state exists to sweep *on*.
- **`StateChangeSlice`'s `maxRetries`.** Same word, unrelated mechanism — it counts DCB append-conflict
  retries inside a single command, not passes over a durable todo.

## Follow-ups

- **Re-driving an abandoned todo** is the obvious next request, and the first thing that will show
  whether `Abandoned` should be a status or a status plus a timestamp.
- **The operator's queue** in [done/semantic-geolocation.md](done/semantic-geolocation.md) gets a second
  source of rows from this: addresses nobody is still working on, alongside addresses that came back
  ambiguous.
