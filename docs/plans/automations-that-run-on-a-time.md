# Plan: automations that run on a time

**Status.** Planned 2026-10-15. Nothing built yet; [S0](#s0-check-what-the-analysis-assumes) comes
first.

**Analysis:** [automations-that-run-on-a-time.md](../analysis/automations-that-run-on-a-time.md)
(*the analysis*; §-references below are its sections). Its decisions and its recommendations
[T1](../analysis/automations-that-run-on-a-time.md#9-open-questions) to
[T11](../analysis/automations-that-run-on-a-time.md#9-open-questions) were agreed on 2026-10-15,
[T10](../analysis/automations-that-run-on-a-time.md#9-open-questions) as its version B.

**In plain words.** An `AutomationSlice` today reacts to events only. This plan lets the same
slice run on a time: a time written in its spec (*every morning at 06:00*), a time an event sets
or clears (*at the hour each customer chose*), or once (*ten minutes after an order is placed*).
The platform's Scheduler only fires; it sends the slice a `Tick` from a framework `Clock` source,
and what the tick means stays in the slice's mappings and `process`, exactly as for an event. No
new component type and no new spec type: a *scheduled automation* is an automation with a
`schedule` or a `reschedule` ([§5](../analysis/automations-that-run-on-a-time.md#5-the-design-of-a)).

**Why now.** Recurring work cannot be written as an automation at all today: schedules are only
made at run time, by a Task, an extension point or a side-effect handler, and fire a payload on
a queue rather than an automation's run
([§2](../analysis/automations-that-run-on-a-time.md#2-what-exists-today)). The two scheduler
adapters also disagree on every wall-clock time, and the AWS `Daily` expression is malformed
([the scheduler analysis §3.3](../analysis/infrastructure-outside-the-capability-model.md#33-the-two-implementations-do-not-agree-about-the-vocabulary),
[§3.4](../analysis/infrastructure-outside-the-capability-model.md#34-a-latent-defect-in-the-aws-arm)).

**Goal.** The four cases of [§8](../analysis/automations-that-run-on-a-time.md#8-examples-from-the-online-shop)
can be written as automations, tested with the GWT DSL at a fixed time, run locally and on AWS
with the same firing times, and read back from the plugin's structure.

**Non-goals.** A slice type of its own for time
([§4](../analysis/automations-that-run-on-a-time.md#4-three-ways-to-run-on-a-recurring-time)).
Making the scheduler a declared platform capability (the scheduler analysis's later stages).
Replaying ticks missed while an application was down
([T5](../analysis/automations-that-run-on-a-time.md#9-open-questions)). The move to Effect 4
([its plan](effect-v4-migration.md)), with which this plan only has to stay compatible
([Risks](#risks)).

**Phases** are numbered S0 to S7 (S for *schedule*). The plan's own open questions are numbered
P1 to P3 ([Open questions](#open-questions)).

---

## Rules every phase keeps

1. **One mechanism.** Every schedule, declared or set, recurring or once, is a key and a
   `Schedule.time` in the slice's query store, and reaches the slice as `Tick({key, at})`
   ([§5.6](../analysis/automations-that-run-on-a-time.md#56-schedules-set-by-events)).
2. **The platform knows only when.** Nothing about a slice's work is given to the Scheduler but
   the slice's name and the key ([§5](../analysis/automations-that-run-on-a-time.md#5-the-design-of-a)).
3. **Local and AWS agree by test**, not by reading: every shape of time has a test that builds
   both platforms' forms from one value and compares the firings.
4. **Existing automations compile unchanged.** Everything added to a spec or a mapping is
   optional and defaulted by the PPX.
5. **Date and time work goes through Effect's `DateTime`, `Cron` and `Clock`**, bound in
   [`rescript/effect`](../../rescript/effect/); nothing else calls them directly, so the Effect 4
   move stays inside that package
   ([§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time)).
6. **ReScript, closed sets as regular variants**, `rescript format` after every edited file.
7. **One commit per phase**, once its tests pass.

---

## S0: check what the analysis assumes

No code. The analysis rests on facts read from code or documentation and not yet tried. Each is
checked, and the result written into this section with its date; a phase whose premise fails is
changed before it starts.

| # | Assumption | How it is checked | If it fails |
|---|---|---|---|
| 1 | The local platform has no automation sweep ([§2](../analysis/automations-that-run-on-a-time.md#2-what-exists-today)) | read the local platform's wiring; run an automation whose `process` returns `None` and watch whether it is retried | [S2](#s2-the-local-platform-sweeps) is dropped |
| 2 | The PPX can inject `let schedule = None`, a default `reschedule` into `Mapping.Make`, and `~now` into a `process` that does not take it ([T4](../analysis/automations-that-run-on-a-time.md#9-open-questions)) | read the `@@reventless.spec` and `@@reventless.automation` transforms in [reventless-ppx](../../packages/reventless-ppx); try it on one golden | `~now` becomes a required argument with a codemod over the examples |
| 3 | EventBridge Scheduler: names of 1 to 64 characters from letters, digits, `-`, `_`, `.`; schedule groups; the `<aws.scheduler.scheduled-time>` input placeholder; *delete after completion*; a zone per schedule; how a local time in a skipped or repeated hour fires; the default quotas ([§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names)) | the AWS documentation, then one schedule created by hand in a test account | the naming or the daylight-saving rule in [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) changes |
| 4 | The Pulumi AWS provider has the Scheduler's schedule group, and the IAM it needs; `rescript/pulumi-aws` can bind them | the provider's docs and the existing bindings | bindings are added in [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) |
| 5 | Effect 3.22's `DateTime` (`zoneMakeNamed`, `makeZoned`, `add`) and `Cron` (`make`, `next`) do what [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) needs, including month ends and daylight saving; their Effect 4 names | a scratch script against each; the Effect 4 changelog | another library is chosen, behind the same bindings |
| 6 | The only callers of `Schedule.rate` are the spec, the two adapters, `ScheduleOps` and a few tests ([T10](../analysis/automations-that-run-on-a-time.md#9-open-questions)) | a search across core, the examples and the published packages that depend on core | the callers found join [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) |

**Exit:** the table's last column is filled in for all six, dated, and any phase it changes is
updated.

## S1: one type for a time, and the schedulers agree

The analysis's [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) and
[T10](../analysis/automations-that-run-on-a-time.md#9-open-questions); stage 1 of
[the scheduler analysis](../analysis/infrastructure-outside-the-capability-model.md#stage-1--converge-the-semantics-a-bug-fix-not-a-model-change).

- **The type.** `Schedule.time` replaces `Schedule.rate` in
  [Schedule.res](../../reventless/spec/src/types/Schedule.res): `interval`, `weekday`,
  `calendar`, `period`, `localTime`, `moment`, `zone` and
  `time = Every | Calendar | Once`; the schedule record becomes `{name, time, payload}`.
- **The bindings.** `DateTime` and `Cron` in `rescript/effect`, as far as
  [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) needs them.
- **The shared reading.** One module in core, beside `ScheduleOps`, with `nextFiring(time,
  ~after)`, `resolveOnce(time, ~from)` (an `After` to an `At` in the schedule's zone, from a
  given instant), the zone check, and the AWS expression of a time (`rate(...)`, `cron(...)` or
  `at(...)`, with its zone).
- **Local.** `LocalScheduledPublisher` waits for `nextFiring` and waits again after each firing;
  a once-only time fires one timer. The 24-hour interval goes.
- **AWS.** The scheduled publisher moves from CloudWatch Events rules to EventBridge Scheduler:
  one schedule group per owner, the target input carrying the scheduled time, *delete after
  completion* for a once-only time. The role's `events:*` on all resources gives way to the
  Scheduler actions on the platform's own groups.
- **Callers.** `ScheduleOps.minutesFromNow` becomes `Once({moment: After(Minutes(n))})`; the
  plugin connect timeout, the Task, extension-point and side-effect-handler paths, and their
  tests follow.

**Tests:** `nextFiring` for each shape, with a zone, across a daylight-saving change in both
directions, on the 29th to 31st of a month, for `Monthly` with `every` and for `Yearly`; the
resolution of `After` across a month's end; the AWS expression of each shape; **the agreement
test**: for a set of times, the AWS expression parsed by Effect's `Cron` and the local
`nextFiring` give the same next ten firings; the local publisher firing at a calendar time under
`TestClock`.

**Exit:** all suites green on in-memory, SQLite and AWS; a Task schedule and the plugin connect
timeout work on a deployed stack, by hand.

## S2: the local platform sweeps

Only if [S0](#s0-check-what-the-analysis-assumes) item 1 confirms it. The local platform runs the
automation sweep as AWS does, every five minutes, over every automation's pending and failed
items, through the same entry the AWS sweep uses. The interval can be shortened for development
([P3](#open-questions)).

**Tests:** an item `process` left pending is retried by the local sweep; a failed item is retried
up to `maxRetries`.

**Exit:** a deadline written as in [§3](../analysis/automations-that-run-on-a-time.md#3-deadlines-today)
passes locally without another event.

## S3: the time inside the functions

The analysis's [§6](../analysis/automations-that-run-on-a-time.md#6-the-time-inside-the-functions).

- `collect` and `resolve` get the source event's recorded time on their `context`.
- `process` gets `~now`, from Effect's `Clock`; the PPX supplies it to a `process` that does not
  take it ([S0](#s0-check-what-the-analysis-assumes) item 2).
- The GWT DSL gains `atTime(t)`, which fixes `now` and the recorded time of the events a
  scenario gives.

**Tests:** the deadline of [§8.1](../analysis/automations-that-run-on-a-time.md#81-a-deadline-an-order-not-shipped-in-three-days-is-cancelled)
as two scenarios, *at day 3 then `CancelOrder`* and *shipped on day 2 then nothing*; every
existing automation's suite unchanged and green.

**Exit:** a deadline is testable at a fixed time; no existing automation changed.

## S4: declared schedules

The analysis's [§5.1 to §5.5](../analysis/automations-that-run-on-a-time.md#51-the-spec) and
[§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names).

- **The spec** gains `let schedule: option<Schedule.time>`; the PPX injects `None` when absent and
  writes the declared time into `.model.json`.
- **The `Clock` source**, `Reventless.Clock`: `name`, `@schema type event = Tick({key, at})`,
  `itemId(key, at)`.
- **The runtime** turns a Scheduler invocation (`{slice, key, at}`) into `Tick({key, at})` for
  the slice's mappings, then runs `process` as for an event batch. The automation runtime is
  given the scheduler's operations.
- **Schedule rows** in the slice's existing `<Slice>Todo` store: id `schedule#<key>`, `rowKind:
  "schedule"`, `key`, `time`, `setBy`, `setAt`, `platformName`. An item id from `collect` that
  starts with `schedule#` is refused and logged. Rehydration of the to-do list is unchanged.
- **The declared default** is written under `default` after a deploy unless an event has already
  set it, and the platform's schedules are reconciled with the rows ([P1](#open-questions)).
- **The PPX's records:** `.wiring.json` marks the mappings that read `Clock`; a build fails when a
  slice maps `Clock` with neither a `schedule` nor a mapping that reschedules.
- **The plugin's structure** carries the declared time.
- **The GWT DSL** gains `whenTick(key, at)`, through the same path as `whenSweep`.

**Tests:** the demand report of [§8.2](../analysis/automations-that-run-on-a-time.md#82-a-declared-schedule-the-demand-report-every-morning)
end to end in memory: the tick makes the day's item, `process` sends `RequestDemandReport`, the
returned event resolves it; the same tick delivered twice adds one item; a `collect` id starting
with `schedule#` refused; the build check; the declared time in `.model.json`.

**Exit:** the demand report runs locally at its time and on a deployed stack, by hand; the
schedule row is visible through the store's query.

## S5: schedules set by events

The analysis's [§5.6](../analysis/automations-that-run-on-a-time.md#56-schedules-set-by-events) and
the once-only part of [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time).

- **`reschedule`** on `Mapping`, returning `Set({key, time})` or `Clear({key})`; the PPX injects
  `_ => []` where absent and marks the mapping in `.wiring.json`.
- **The runtime** writes each change to the schedule rows first, then to the platform; an
  `After` is resolved with the event's recorded time; a once-only key is cleared when its tick
  arrives.
- **Rebuild and reconcile**: rebuilding a slice replays `reschedule` over its source events in
  order, writes the declared default unless `default` is set, and brings the platform's group in
  line; a once-only time already past is not made again
  ([T7](../analysis/automations-that-run-on-a-time.md#9-open-questions)).
- **The store's list query** gains the optional `rowKind`, absent for a to-do row, and a filter
  on it ([T11](../analysis/automations-that-run-on-a-time.md#9-open-questions)).
- **The GWT DSL** gains `thenSchedules`.

**Tests:** the moved report of [§8.3](../analysis/automations-that-run-on-a-time.md#83-the-same-schedule-moved-by-an-event)
(an event replaces the declared default, and a later deploy keeps it); the digest of
[§8.4](../analysis/automations-that-run-on-a-time.md#84-a-schedule-per-customer-the-marketing-digest)
(set, fire, resolve by `reference`, clear on unsubscribe); the reminder of
[§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) (set ten minutes
after the recorded time, cleared when the order ships, cleared after it fires); a rebuild that
reproduces the rows and removes a stray platform schedule.

**Exit:** the digest runs on a deployed stack for two recipients with different zones, by hand;
a rebuild leaves the platform's group equal to the rows.

## S6: the guide, the words and the examples

- **The component guide** ([automationslice.md](../../packages/doc/docs-app/components/automationslice.md))
  gains *Running on a time*: the three shapes, declared and set schedules, the `Clock` mapping,
  why `resolve` still matters, which to use (the analysis's flowchart).
- **The terminology guide** ([terminology-guide.md](../guides/terminology-guide.md)) takes the
  analysis's [Words](../analysis/automations-that-run-on-a-time.md#words).
- **The online shop** gains the examples [P2](#open-questions) chooses, with their GWT
  scenarios.

**Exit:** the guide's examples compile as written; the shop's suites pass.

## S7: release

Released with the next core alpha. The changelog names the breaking change: `Schedule.rate` is
replaced by `Schedule.time`, and callers of `createSchedule` change their schedules' `rate` to
`time`.

**Exit:** published, and the online shop builds against the published packages.

---

## Risks

- **Effect 4.** [Its migration](effect-v4-migration.md) is planned for when 4.0 has settled. The
  new `DateTime` and `Cron` bindings are kept inside `rescript/effect`
  ([Rules](#rules-every-phase-keeps) 5), and [S0](#s0-check-what-the-analysis-assumes) item 5
  notes their Effect 4 names, so whichever lands second has one package to follow.
- **Daylight saving.** Local and AWS could still disagree on a skipped or repeated local time;
  the agreement test of [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) covers both
  changes of the year, and [S0](#s0-check-what-the-analysis-assumes) item 3 fixes AWS's rule
  first.
- **A deploy that changes every scheduled caller at once** ([S1](#s1-one-type-for-a-time-and-the-schedulers-agree)):
  the move to EventBridge Scheduler replaces the platform's scheduling resources. A schedule made
  at run time by an older version is not carried over; [S1](#s1-one-type-for-a-time-and-the-schedulers-agree)'s
  deploy check covers the two built-in callers.

## Open questions

**P1. How is the declared default put on the platform after a deploy?** A Pulumi resource per
declared schedule, or the runtime's reconcile run after the deploy?
**Recommendation: the runtime's reconcile.** The schedule rows are the truth
([§5.6](../analysis/automations-that-run-on-a-time.md#56-schedules-set-by-events)); if Pulumi
also made schedules, two owners would fight over the same group. Pulumi creates the group and the
permissions only, and the deploy ends by asking each scheduled slice to reconcile, as it already
asks plugins to reconnect.

**P2. Which examples go into the online shop?**
**Recommendation: the deadline
([§8.1](../analysis/automations-that-run-on-a-time.md#81-a-deadline-an-order-not-shipped-in-three-days-is-cancelled))
and the digest ([§8.4](../analysis/automations-that-run-on-a-time.md#84-a-schedule-per-customer-the-marketing-digest)).**
Between them they exercise the sweep, `~now`, the `Clock`, `reschedule`, a key per customer and
`resolve` by reference. The demand report and the reminder stay as compiled snippets in the
guide; adding them would add two decisions the shop does not otherwise need.

**P3. How often does the local sweep run?**
**Recommendation: every five minutes, as on AWS, shortened by an environment variable** for a
developer who does not want to wait; the default keeps local behaviour equal to deployed.
