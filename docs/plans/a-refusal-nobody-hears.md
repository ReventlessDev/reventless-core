# Plan: a refusal nobody hears

> **Status:** Built 2026-11-08, every step but the alarm in [RNS5](#5-steps), which waits for a
> deployed stack to count an unheard refusal ([RNQ6](#4-decisions)). [RNS6](#5-steps) is deployed
> to alpha and exercised there: a refused command recorded its reason within one sweep. Two
> decisions taken differently, recorded at [RNQ2](#4-decisions) and [RNQ6](#4-decisions).
>
> **Questions and short answers:**
>
> 1. *What happens when a command is refused or rejected and no API caller is there to hear it, as with
>    an extension, an extension point, an automation, or an inbound or outbound translation? It is
>    logged, but what else should happen?* **Today almost nothing: one log line, and the queue message
>    is deleted. An automation notices only by its 15-minute timeout and never learns why; an outbound
>    translation has already marked its row done; an extension forgets the command. The fix has two
>    halves: the slices that keep a row should hear the target's answer where it answers right away
>    and record why it said no ([RNQ1](#4-decisions)–[RNQ3](#4-decisions)), and a refusal the domain
>    must react to should be written as an event rather than an error ([§3](#3-what-an-app-should-do-whatever-the-framework-does)).**
>    See [§2](#2-what-happens-today) for each source in turn.
>
> **Relates to:** [retry-exhaustion-is-not-a-state.md](retry-exhaustion-is-not-a-state.md), which made
> "gave up" a state (`Abandoned`) and gave the two work-list slices `onExhausted`. This plan is the next
> step: the slice did its part, and the *target* said no.
>
> **Ids:** `RNQ` (refusal nobody hears, question) for decisions in [§4](#4-decisions), `RNS` (step) for
> the steps in [§5](#5-steps).

---

## 1. In plain words

A command is a request: "reserve this stock", "mark this address unresolvable". The part of the system
that owns the data can say no. When a person sent the command through the API, the "no" goes back to
their screen and they decide what to do next.

Many commands are not sent by a person. An **automation** sends one when an event arrives ("an order
was placed, so reserve stock"). An **outbound translation** calls an outside service and sends the
answer back in as a command. An **extension** turns another plugin's event into a command here. An
**inbound translation** turns a webhook call into commands. In each case, nobody is waiting for the
answer.

So if the stock reservation is refused, today the order simply stays "placed" forever. The refusal is
written to a log, and that is all. No read model shows it, nothing reacts to it, and the slice that
sent the command does not know why it never saw the event it was waiting for.

## 2. What happens today

Every one of these sources sends with `publishJsons`, which returns when the message is sent, not when
the target has decided. Only the GraphQL door uses `publishJsonsAndWait`, which returns the verdict.

What the target does with a refusal is the same for all of them: it reports the outcome
(`reportRejected` in [CommandTopic_Helpers.res](../../reventless/core/src/components/CommandTopic/CommandTopic_Helpers.res)),
which writes a `command rejected` log line with `errorCode`, `cause`, `correlationId` and
`causationId`, and calls any hook registered with `registerCommandOutcome`. Locally such a hook feeds
the command outcome log; on AWS none is registered. A refusal for a business reason (`DomainRejection`) or
for lack of permission (`AccessRefusal`) then **settles the queue message**: it is deleted, because
sending it again would not change the answer
([Aggregate_Callback.res:454-487](../../reventless/core/src/components/Aggregate/Aggregate_Callback.res#L454-L487),
and the `Ok("rejected")` arm in
[StateChangeSlice_Callback.res](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)).
Only an infrastructure failure (`InfrastructureFailure`, the append failed) is left for the queue to
deliver again.

What the *sender* does differs:

| Source | What it does after sending | What a refusal leaves behind |
| --- | --- | --- |
| Automation | Row goes `Processing`. `resolve` marks it `Completed` when the expected event arrives. | No event comes. After 15 minutes the row counts as a failed attempt and the command is sent again ([AutomationSlice_Callback.res:472-484](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Callback.res#L472-L484)). A business refusal is repeated `maxRetries` times, 15 minutes apart, then `Abandoned`. `lastError` stays empty, so the row never says why. |
| Outbound translation | Row goes `Completed` as soon as the command back is sent ([OutboundTranslationSlice_Callback.res:426-427](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res#L426-L427)). | A row that says `Completed` for work the domain refused. |
| Inbound translation | Answers the webhook caller `Accepted` once the commands are sent. | The outside system believes its call was taken. |
| Extension, ExtensionPoint | Nothing kept. | The log line only. |

Three problems follow, from mild to serious:

- **The automation wastes its retries.** Up to 45 minutes of re-sending a command that will be refused
  each time, and when the row finally reads `Abandoned` it does not say what the target answered.
- **The outbound row reports success for a refusal.** That is the same kind of misreporting the
  retry-exhaustion plan removed for `Failed` ([its gap](retry-exhaustion-is-not-a-state.md#the-gap)).
- **On AWS a refusal of a system command is visible only to someone searching logs**, and the log line
  is at info level, beside every accepted command.

## 3. What an app should do, whatever the framework does

These hold even after the steps below, and the docs should say them, because most of the cure is in
how the target is written:

1. **Accept what is already done.** A command sent by the system may arrive twice. A repeat should
   return `Ok([])`, never an error. This alone removes most refusals of system commands.
2. **Check before sending.** An automation's work list is built from events. If it also follows the
   events that would make its command invalid (the order was cancelled), `process` can return `None`
   and never send it.
3. **Write a refusal the domain must react to as an event.** If reserving stock can fail for a business
   reason, let `decide` emit `StockReservationDeclined` instead of returning `Error`. Then a read model
   can show it, and an automation can react to it (cancel the order, tell the customer). Keep `Error`
   for commands a person sends, who sees it.
4. **Let the work item finish on either answer.** The automation's `resolve` should complete the row on
   the success event *and* on the refusal event, so a refusal does not look like silence.

The framework cannot do point 3 for an app: a refusal event needs a home in some entity's history, and
which one is exactly what the app knows. That is the same reason
[retry-exhaustion's D2](retry-exhaustion-is-not-a-state.md#d2-what-the-hook-is-allowed-to-return) gave
for not publishing an "abandoned" event on a slice's behalf.

What the framework *can* do is make sure the slices that keep a work list hear the answer, record it,
and stop wasting retries; and make an unheard refusal visible on a deployed stack.

## 4. Decisions

### RNQ1. How does a slice learn the target's answer?

Three ways, from cheapest to most complete:

- **(a) Wait where the target answers right away.** Use `publishJsonsAndWait` when the target's command
  topic offers it (a sync target), and keep `publishJsons` otherwise. An async target answers
  `Pending`, and the row falls back to today's timeout. **Where it actually yields a verdict:**
  locally, always ([LocalCommandTopicChannel.res](../../reventless/local/src/adapter/CommandTopic/LocalCommandTopicChannel.res)).
  On AWS, only when the target's handler runs in the same Lambda as the sender; otherwise the sync
  channel sends to the queue and answers `Pending`
  ([CommandTopicChannel_SQS_Sync.res:75-92](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Sync.res#L75-L92)),
  and the other SQS channels offer no waiting publish at all.
- **(a2) On AWS, invoke the target's command Lambda directly.** This is how the GraphQL door gets its
  verdict on AWS: AppSync invokes the target's Lambda, which runs the command inline and answers with
  the outcome ([DcbCommandTopicEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res)).
  A slice's Lambda could do the same through the AWS SDK. Costs: an invoke grant from each sender to
  each target, and the sender's Lambda waits while the target decides (a sweep of 50 rows sends 50
  commands; they can be sent in parallel, but the sweep's run time grows).
- **(b) Route the outcome back.** Publish every outcome of a system command to a topic the sending
  slice listens on, matched by message id. Works for async targets too, but it is new infrastructure
  (a topic per sender, or a shared one with filtering) and a new kind of message.
- **(c) Change nothing in the framework**; rely on [§3](#3-what-an-app-should-do-whatever-the-framework-does).

**Recommendation:** (a) first, then (a2), with (c)'s advice written into the docs either way. Most
targets are sync, since sync is the default and `@@reventless.async` is an opt-in for contention or
long-running work. (a) needs only that the slice builders are handed `publishJsonsAndWait` beside
`publishJsons`; it is complete locally and degrades to today's behavior on AWS, so it is safe to land
alone. (a2) is what makes it work on a deployed stack, and should be measured there before it is
relied on: whether the target's entry point answers a Lambda caller the same way it answers AppSync,
and what the waiting adds to a sweep. Revisit (b) if (a2) turns out too slow or too costly, or if an
async target with business refusals turns up in an app.

### RNQ2. What does a work-list row do with each answer?

| Answer | Automation row | Outbound translation row |
| --- | --- | --- |
| Accepted | stays `Processing`; `resolve` completes it, as today | `Completed`, as today |
| Pending (async target) | stays `Processing`; the timeout applies, as today | `Completed`, as today |
| Refused, business reason | failed attempt, `lastError` = the code and detail, retried on the **next pass** rather than after 15 minutes | `Abandoned` at once, `lastError` set *(built differently, see below)* |
| Refused, no permission | `Abandoned` at once, `lastError` set | same |
| Infrastructure failure | failed attempt, `lastError` set, retried on the next pass | same as automation |

*Built differently for outbound translations.* The table first said "same" for both columns. A
retried outbound row runs `translate` again, and so calls the outside service a second time: for
the payment example in the docs, a second charge. The ordering race that justifies retrying a
business refusal in an automation does not outweigh that, so an outbound business refusal ends the
row at once, with the reason, and `onExhausted` hears it. An infrastructure failure is still retried,
as a failed publish always was.

**Recommendation:** as in the table. The one choice that needs arguing is **retrying a business
refusal at all**. A refusal can be a matter of order rather than a verdict: an automation reacts to
`OrderPlaced` and sends `ReserveStock` before the product's own `ProductAdded` has reached the slice
that decides, so the target answers "unknown product" for a few seconds. Abandoning on the first "no"
would turn that race into a lost order. Counting it as a failed attempt heals the race on the next
pass, and a lasting "no" still ends in `Abandoned` after `maxRetries`, now with the reason on the row
and much sooner than 45 minutes. A permission refusal cannot heal by waiting (the system's own
commands carry no caller), so it ends at once. Revisit if a target needs to say "this will never
work" so its refusal is not repeated; that would be a new error kind on the target, not a change here.

### RNQ3. Which hook hears a refusal that ended the row?

When the row ends `Abandoned` because of a refusal, the slice may want to tell the domain, exactly as
when the retries ran out.

- **(a) Reuse `onExhausted`**, handing it `~lastError` so it can tell "never answered" from "refused,
  and here is why". The outbound hook already takes `~lastError`; the automation hook does not.
- **(b) A new `onRefused` hook.** A second required field on two published module types, so a second
  breaking change for every slice, to say something `onExhausted` with a reason already says.

**Recommendation:** (a). Add `~lastError: option<string>` to the automation's `onExhausted`, and have
the PPX add `~lastError as _` to an `onExhausted` written without it, the way
[NowInjection.ml](../../packages/reventless-ppx/src/ppx/NowInjection.ml) adds `~now as _` to `process`.
Then no existing slice breaks. Revisit if slices start parsing `lastError` strings to branch; that is
the sign the reason wants a type, not a string.

### RNQ4. What does an inbound translation answer its caller?

The webhook caller is an outside system. Telling it "accepted" when the target refused means it will
not retry and will not tell its own user.

**Recommendation:** wait where the target answers right away ([RNQ1](#4-decisions) (a), and (a2) on
AWS) and answer
with the first refusal: its error code and detail, as a rejection, which the transport turns into an
error status. The audit row records the target's answer too. A `Pending` answer stays `Accepted`, as
today. Revisit if one webhook call fans out to several targets and a partial refusal turns out to need
its own answer; today the first refusal wins and the others are in the log.

### RNQ5. What about extensions and extension points?

They keep no row, so there is nothing to mark and nothing to retry. Their command is the other
plugin's event, which already happened.

**Recommendation:** no new mechanism for them; the cure is [§3](#3-what-an-app-should-do-whatever-the-framework-does)
point 3 in the target plugin. What they get is the visibility in [RNQ6](#4-decisions). Revisit if
cross-plugin flows with business refusals become common enough that every target writing its own
refusal event is a burden; then a framework-level "refused" fact on the extension point is worth
designing.

### RNQ6. How does an unheard refusal become visible on a deployed stack?

The log line says `command rejected` at info level for every refusal, whether a person sent the
command or the system did. A command the system sent carries no caller claim (`meta.callerClaim` is
absent; see the owner marker in [CLAUDE.md](../../CLAUDE.md)).

**Recommendation:** log a refusal of a command with no caller claim at **warning** level, with
`unheard: true` in its fields, and add a metric filter on that line to the alarms the platform already
offers ([alarms.md](../guides/alarms.md)). A refusal a person sees on their screen stays at info.
Revisit if the warning turns out noisy for an app that relies on refusals as normal flow; that app
should be writing refusal events instead ([§3](#3-what-an-app-should-do-whatever-the-framework-does)
point 3), and the noise is the prompt.

*Built differently.* "No caller claim" alone would have warned about every refusal an inbound
translation's caller now hears, since its commands carry no claim either. The rule built is: no
caller claim, **nobody waiting inline** for the answer, and a business or permission refusal (an
infrastructure failure is delivered again by the queue, so it is not final). Such a refusal is
logged as a warning with `unheard: true` and counted as the `UnheardRefusal` metric, through the
same neutral metric line the DCB counts use; on AWS a log metric filter on DCB command handlers
turns it into a CloudWatch metric.

**Not built: the alarm itself.** The metric is dimensioned by slice, and a CloudWatch alarm needs a
concrete dimension. Checked on alpha 2026-11-08: the filters are on the three DCB command handlers'
log groups, and `UnheardRefusal` has never been written, so CloudWatch does not list the metric at
all. When a stack first counts one, the alarm takes four pieces:

1. **One alarm for every slice.** Three ways:
   - *One alarm per slice*, billed per alarm, over a list that must grow whenever a slice starts
     refusing.
   - *A second metric filter with the same pattern and no dimension*, so each command handler also
     writes a plugin-wide total, and one plain alarm per handler watches that. The per-slice
     metric stays, to find which slice refused.
   - *A Metrics Insights query alarm* (`SUM(UnheardRefusal)` grouped by slice), one alarm across
     the slices; not yet checked that CloudWatch alarms on such a query in this setup.
2. **A metric filter on the Aggregate command handlers.** They write the warning line, but
   nothing counts it there.
3. **The alarm in the alarms stack**, to the same target as the others, with missing data treated
   as fine, since a quiet stack writes no data point at all.
4. **[alarms.md](../guides/alarms.md)**, beside the rule that every unit has one `Errors` alarm.

**Recommendation:** still leave the alarm until a deployed stack shows a non-zero
`UnheardRefusal`; until then the warning line and the metric answer "does this happen", which is
the first question. When it does, build the plugin-wide total (the second way): one alarm per
handler, no slice list to keep, and the per-slice metric to look into. Meanwhile, lowering the
ERROR-level `decide rejected` line ([RNS6](#5-steps)'s notes) is what makes the warning stand out
in the logs. Revisit the choice if a plugin turns out to need one slice's refusals alarmed and
another's not.

## 5. Steps

| Step | What | Done when |
| --- | --- | --- |
| RNS1 | Hand `publishJsonsAndWait` to the automation, outbound and inbound translation builders beside `publishJsons` (the plugin wiring and both runtimes) ([RNQ1](#4-decisions) (a)). | each callback can call it where offered |
| RNS2 | Automation and outbound callbacks: send with it when offered, and apply [RNQ2](#4-decisions)'s table. Outbound stops marking `Completed` on a refusal. | unit tests for each row of the table, on both callbacks, mutation-checked |
| RNS3 | `~lastError` on the automation's `onExhausted`, with the PPX adding `~lastError as _` ([RNQ3](#4-decisions)). | an existing slice compiles unchanged; a refusal that ends a row reaches the hook with its reason |
| RNS4 | Inbound translation answers with the target's refusal ([RNQ4](#4-decisions)) and records it in the audit row. | a webhook test sees a rejection with the target's code |
| RNS5 | Warning-level line for a refusal with no caller claim, and the alarm's metric filter ([RNQ6](#4-decisions)). | the line on both backends; the filter in the alarms stack and guide |
| RNS6 | On AWS, a sender in another Lambda invokes the target's command Lambda directly and reads the outcome ([RNQ1](#4-decisions) (a2)): the invoke grant per sender and target, parallel sends within a sweep. | on the alpha stack, an automation whose command is refused records the reason within one sweep; sweep time measured before and after |
| RNS7 | Docs: [§3](#3-what-an-app-should-do-whatever-the-framework-does) in the automation and outbound pages ([automationslice.md](../../packages/doc/docs-app/components/automationslice.md#when-an-item-runs-out-of-retries), [outboundtranslationslice.md](../../packages/doc/docs-app/components/outboundtranslationslice.md#error-handling)), the work-list status table, and the inbound and extension pages. | docs site builds |

**Built (2026-11-08):** [RNS1](#5-steps) to [RNS3](#5-steps). Notes from building them:

- The waiting publish collected outcomes through one global slot, set and cleared around each inline
  run. Two runs in one process, overlapping or nested, would clear each other's and report a refusal
  as accepted; an automation waiting while a GraphQL mutation runs is exactly that. The slot became a
  waiter per message id (`inlineWaiters` in `CommandTopic_Helpers`), pinned by a nested-run test.
- The outcome types (`refusalCause`, `commandOutcome`, `publishJsonsAndWait`) moved down to
  `reventless-infra`'s `CommandTopic`, since the slices' module types live there; core re-exports
  them with the same constructors.
- An outbound slice whose target is an Aggregate is not waited on: the aggregates' topics are handed
  over as plain `publishJsons`.
- Automation rows gained `lastError`, which moved the four automation todo types in the GraphQL
  goldens and nothing else.
- Mutation-checked: dropping the "still `Processing`" guard fails the race-with-`resolve` test;
  not delivering refusals to waiters fails four.

**Built (2026-11-08):** [RNS4](#5-steps), [RNS5](#5-steps) without its alarm, and [RNS7](#5-steps).

- [RNS4](#5-steps): unlike an automation, an inbound translation on AWS runs in the DCB command
  Lambda beside the slices it targets, so its wait yields a verdict on a deployed stack too, in sync
  dispatch mode. The refusal's cause rides on the result, so the webhook answers `422` for a business
  refusal, `403` for a permission one, and `503` for a platform failure.
- An open door now passes the target's reasons to whoever calls it. The registration package was
  checked: `Register` answers `Ok([])` in every case, and `Registrations`' only refusals belong to
  `Invite`, whose caller is a signed-in inviter meant to hear them. The inbound page says so for
  door authors.

**Built (2026-11-08):** [RNS6](#5-steps), deployed to alpha and exercised there.

- The DCB command Lambda gained **Route P**: `{__platformCommands: true, commands: [...]}`, the
  commands already encoded, answered with one outcome each (`Pending` in async mode). Reachable only
  with `lambda:InvokeFunction`, granted to the automations' Lambda alone; the commands carry no
  caller claim, exactly as on the queue.
- The automations' Lambda invokes it (`DcbPlatformCommands_Runtime`) for every slice that sends to
  its plugin's DCB topic; a slice sending to an Aggregate's own queue keeps the queue.
- **The ordering was the hard part.** The automations' Lambda is finished before the DCB command
  Lambda is built, and the plugin program builds parts of itself inside output callbacks, so reading
  a registry lazily was not enough: the first preview showed it read empty. `DcbCommandFunctions`
  makes the config wait for the function instead, matched by the queue's `id` output, and resolved
  with the name's output so a preview of a new stack stays unknown rather than waiting forever. Every
  sync and async DCB command topic settles the wait, built or skipped.
- Preview of `online-shop-hybrid-ordering-aws` on alpha: `AllAutomationSlices` gains
  `commandFunction: "OrderingDcbCmdHandler-…"` in `HANDLER_CONFIG`, and the grant
  `AllAutomationSlices-invoke-OrderingDcbCmdHandler` is created.
- **Deployed to alpha 2026-11-08 13:44 UTC** (release `16944376f`; the platform and both plugin
  stacks deployed, the manifest bake afterwards failed on the open handshake race, which leaves the
  Lambdas as deployed). The live `AllAutomationSlices` config names `OrderingDcbCmdHandler-2007759`.
  In the 45 minutes after: ten sweeps, no warnings or errors in either Lambda, no `AccessDenied`.
  Sweeps took 36 to 53 ms once warm, as before the deploy; the first four were 158 to 352 ms while
  the new code warmed up.
- **Exercised on alpha 2026-11-08 14:40 UTC.** One invoke of `OrderingDcbCmdHandler-2007759` sent
  `PlaceOrder` (Express) and `CancelOrder` for `ord-20261108-rns6-001`; both were accepted, and
  their two events reached the automations' Lambda before `AutoShipOrder` sent its `ShipOrder`. The
  target refused it with `OrderAlreadyCancelled` (`DomainRejection`) on all three attempts, each a
  Route P invoke, and the row ended `Abandoned` with `lastError: "OrderAlreadyCancelled"` and
  `retryCount: 3`, 2.5 s after it was created. No `unheard` warning, as expected: the automation
  was waiting for the answer.
- **Sweep time with a command in it:** 55 ms with a warm target, against 36 to 53 ms without one.
  A sweep whose invoke meets a cold instance of the command Lambda took 1.8 s, the target's 1.7 s
  start-up included.
- **Seen on the way, not changed:** the three attempts ran on the next three passes, which the
  order's own follow-up events (the cancellation, the confirmation notification) set off within
  2.5 s. The retry that [RNQ2](#4-decisions) keeps to heal an ordering race is spent as quickly as
  events arrive, so under busy traffic it heals only a race shorter than that. Revisit if a
  refusal that a few seconds would have healed turns up `Abandoned`; a minimum spacing between
  attempts of one row is the remedy, which is the backoff [§6](#6-out-of-scope) leaves out.
- **Also seen:** every business refusal writes, beside the info-level `command rejected`, an
  ERROR-level `decide rejected` line from the slice's own callback (and the Aggregate's). It
  predates this plan and triggers no alarm, since the alarms watch the Lambda `Errors` metric, but
  it puts a refusal a person sees at ERROR, above the `unheard` warning meant to stand out.
  Recommendation: drop it to info, or remove it, since `command rejected` says the same.

[RNS1](#5-steps) to [RNS3](#5-steps) belong together and are complete locally; [RNS6](#5-steps) is what
makes them work on a deployed stack, and needs [RNS1](#5-steps) first. [RNS4](#5-steps) and
[RNS5](#5-steps) stand alone.
The PPX change in [RNS3](#5-steps) ships in the same commit as its use and needs a `reventless-ppx`
republish for external consumers.

## 6. Out of scope

- **Routing outcomes back from async targets** ([RNQ1](#4-decisions) (b)).
- **A framework-level refusal event.** The app writes it ([§3](#3-what-an-app-should-do-whatever-the-framework-does)).
- **Retry spacing and backoff.** Untouched, as in the retry-exhaustion plan.
