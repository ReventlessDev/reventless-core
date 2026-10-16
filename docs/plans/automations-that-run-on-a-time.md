# Plan: automations that run on a time

**Status.** Planned 2026-10-15. [S0](#s0-check-what-the-analysis-assumes) done 2026-10-15,
including a hand test of EventBridge Scheduler; its findings are folded into the phases below.
[S1](#s1-one-type-for-a-time-and-the-schedulers-agree) built and deployed 2026-10-16. [S2](#s2-the-local-platform-sweeps) and
[S3](#s3-the-time-inside-the-functions) built 2026-10-16. [S4](#s4-declared-schedules) is built
and committed, its deployed check moved to [S5](#s5-schedules-set-by-events). S5's framework half is
built, uncommitted ([where it stands](#where-s5-stands-2026-10-16)).

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

| # | Assumption | How it is checked | If it fails | Result, 2026-10-15 |
|---|---|---|---|---|
| 1 | The local platform has no automation sweep ([§2](../analysis/automations-that-run-on-a-time.md#2-what-exists-today)) | read the local platform's wiring; run an automation whose `process` returns `None` and watch whether it is retried | [S2](#s2-the-local-platform-sweeps) is dropped | **Holds.** [S2](#s2-the-local-platform-sweeps) stays, with two additions |
| 2 | The PPX can inject `let schedule = None`, a default `reschedule` into `Mapping.Make`, and `~now` into a `process` that does not take it ([T4](../analysis/automations-that-run-on-a-time.md#9-open-questions)) | read the `@@reventless.spec` and `@@reventless.automation` transforms in [reventless-ppx](../../packages/reventless-ppx); try it on one golden | `~now` becomes a required argument with a codemod over the examples | **Holds, by reading.** Each injection has a precedent; the trial on a golden moves to the first phase that needs it ([S3](#s3-the-time-inside-the-functions)) |
| 3 | EventBridge Scheduler: names of 1 to 64 characters from letters, digits, `-`, `_`, `.`; schedule groups; the `<aws.scheduler.scheduled-time>` input placeholder; *delete after completion*; a zone per schedule; how a local time in a skipped or repeated hour fires; the default quotas ([§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names)) | the AWS documentation, then one schedule created by hand in a test account | the naming or the daylight-saving rule in [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) changes | **Partly fails: the daylight-saving rule.** Naming, groups, placeholder, deletion and zones hold, by the documentation and by hand. A `rate` needs a `StartDate` |
| 4 | The Pulumi AWS provider has the Scheduler's schedule group, and the IAM it needs; `rescript/pulumi-aws` can bind them | the provider's docs and the existing bindings | bindings are added in [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) | **Fails as expected.** The provider has both resources, but nothing binds them. The runtime SDK client is missing too. Both go into [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) |
| 5 | Effect 3.22's `DateTime` (`zoneMakeNamed`, `makeZoned`, `add`) and `Cron` (`make`, `next`) do what [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) needs, including month ends and daylight saving; their Effect 4 names | a scratch script against each; the Effect 4 changelog | another library is chosen, behind the same bindings | **Holds, with two traps** that [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) has to avoid |
| 6 | The only callers of `Schedule.rate` are the spec, the two adapters, `ScheduleOps` and a few tests ([T10](../analysis/automations-that-run-on-a-time.md#9-open-questions)) | a search across core, the examples and the published packages that depend on core | the callers found join [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) | **Holds for `rate`.** The AWS permissions are spread further than assumed; they join [S1](#s1-one-type-for-a-time-and-the-schedulers-agree) |

**Exit:** the table's last column is filled in for all six, dated, and any phase it changes is
updated.

### What S0 found

**1. The local sweep.** Nothing sweeps locally. The local AutomationSlice builder passes the
core maker through unchanged
([AutomationSlice_Builder.res](../../reventless/local/src/components/AutomationSlice_Builder.res)).
Core runs `phase2` only inside the event handler. It exposes `processPending`, but nothing in
the local platform calls it. The only local timers are the plugin heartbeat
([LocalHeartbeatRunner.res](../../reventless/local/src/adapter/Heartbeat/LocalHeartbeatRunner.res)) and
the scheduled publisher. No test retries an item that `process` left pending; the tests call
`phase2` twice by hand. Two things for [S2](#s2-the-local-platform-sweeps):

- `processPending` does not write the to-do list back to the query store afterwards, as the event
  path does. The AWS sweep does all three steps (load, `phase2`, sync); the local one must too.
- A slice's `heartbeatInterval` is read nowhere, on either platform. Its spec documents it in
  seconds, while the plugin heartbeat counts its own `heartbeatInterval` in minutes. This is
  [T6](../analysis/automations-that-run-on-a-time.md#9-open-questions), still open.

**2. The PPX.** All three injections are feasible:

- `let schedule = None` follows `externalSystem = None`, a folder-gated suffix injected only when
  absent (`AuthorizationInjection.ml`).
- `~now` follows `TypeAnnotationInjection`, which already walks `process` through its
  `Function$` wrapper. Adding a labelled layer raises the arity from 2 to 3.
- `reschedule` is the one with no pass to extend. Today only the wiring sidecar's emitter
  recognises `Mapping.Make(Source, Target, {...})`. A new walk has to append to the third
  argument, the way `inject_external_system_into_inner_module` appends to an inner module. The
  older three-file `_Mappings.res` form goes through a different path and needs the same walk.
- Both sidecars are written from the source *before* any injection. `.model.json` keeps only the
  keys in `config_keys`, so `schedule` has to be added there. Otherwise the declared time never
  reaches the sidecar ([S4](#s4-declared-schedules)).

**3. EventBridge Scheduler** (the
[schedule types](https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html),
[CreateSchedule](https://docs.aws.amazon.com/scheduler/latest/APIReference/API_CreateSchedule.html),
[context attributes](https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-schedule-context-attributes.html)
and [quotas](https://docs.aws.amazon.com/scheduler/latest/UserGuide/scheduler-quotas.html) pages):

- **Names hold.** A schedule's name and a group's name are each 1 to 64 characters matching
  `[0-9a-zA-Z-_.]+`.
- **Deletion holds.** `ActionAfterCompletion: DELETE` exists. A completed one-time schedule
  counts against the quota until it is deleted.
- **Zones hold.** `ScheduleExpressionTimezone` takes an IANA name, for `cron` and `at` only.
- **The placeholder holds.** `<aws.scheduler.scheduled-time>` is filled in as
  `2022-03-22T18:59:43Z`.
- **The daylight-saving rule fails.** When a `cron` time falls in the hour skipped in spring, AWS
  **skips that firing** and runs normally the next day. A time that occurs twice in autumn runs
  once, at the first occurrence. The analysis's rule "the next valid minute" is wrong for
  `Calendar`, and the local `nextFiring` must skip as AWS does. The documentation does not say
  how `at(...)` treats a skipped local time. The hand test shows only that such a schedule is
  accepted; when it fires cannot be seen before the next spring change. Until then, a `Once`
  resolved into a skipped hour is moved forward by the gap. That is what Effect does (item 5).
- **`rate` has a start rule.** `rate(...)` knows minutes, hours and days, and `rate(n days)` is
  24 hours, so `Every` stays zone-free as planned. Without a `StartDate`, a `rate` schedule fires
  as soon as it is created. AWS is given a `StartDate` one interval after creation, and the local
  timer waits the same interval.
- **The quotas** are higher than the analysis assumed: 10,000,000 schedules per region, not a
  million. Groups are limited to **500 per region**. With one group per scheduled slice and
  stack, that limit is the one to watch ([Risks](#risks)).

**The hand test** (2026-10-15, eu-central-1). One schedule group held probe schedules that sent
their input to an SQS queue; everything was deleted afterwards.

- **The `at(...)` time and the placeholder.** An `at(...)` at 00:06 in Europe/Berlin fired at
  22:06Z, and its input held `"at": "2026-10-15T22:06:00Z"`. The placeholder is UTC, to the
  second, with a `Z`. With `DELETE`, the schedule was gone after it fired.
- **A `rate` without `StartDate` fires within a minute** of being created. Its scheduled time is
  the moment of creation, to the second (`22:03:31Z`), so its later firings are not on the minute
  either. With `StartDate`, it first fired exactly then and on the minute after that. That
  confirms the `StartDate` rule above. `Clock.itemId` cuts `at` to the minute, so either way a
  retried tick names the same item.
- **Delivery lag.** Messages arrived 4 to 41 seconds after their scheduled time, within the
  documented 60-second precision. `<aws.scheduler.attempt-number>` was `1`.
- **Names.** A 64-character name was accepted; 65 characters and a name containing `:` were
  refused.
- **Daylight saving.** An `at(2027-03-28T02:30:00)` in Europe/Berlin, inside the skipped hour,
  was accepted.
- **Today's `Daily` expression** (`cron(0 6 * * * *)`) is refused outright. The same time
  with `?` as the day-of-week field is accepted.

**4. Pulumi and the SDK.** `@pulumi/aws` 7.19.0 ships `aws.scheduler.Schedule` and
`aws.scheduler.ScheduleGroup`. [rescript/pulumi-aws](../../rescript/pulumi-aws/) binds neither;
the layout to follow is one file per resource (`Cloudwatch_EventRule.res`). The runtime creates
schedules through the SDK, and `@aws-sdk/client-scheduler` is neither installed nor bound in
[rescript/aws-sdk](../../rescript/aws-sdk/). Only the CloudWatch Events client is.

**5. Effect** (3.22.2; 4.0.5 is now `latest`):

- Month ends work: 31 January plus a month is 28 February.
- An unknown zone is `None`.
- A cron time in the repeated hour fires once.
- `Monthly` on the 31st skips the short months. AWS's `L` covers "the last day".
- Effect 4 renames `unsafeMakeZoned` to `makeZonedUnsafe`, `zoneUnsafeMakeNamed` to
  `zoneMakeNamedUnsafe` and `Cron.unsafeParse` to `parseUnsafe`. Its `Cron.parse` returns a
  `Result` instead of an `Either`.

Two traps:

- **A `Cron` without a zone uses the machine's zone.** The bindings always pass one, UTC when the
  time has none.
- **`DateTime.add` on a zoned value treats `hours: 24` as wall-clock time.** It gives 23 elapsed
  hours across the spring change, while `hours: 1` is elapsed time. `After(Minutes | Hours)` is
  therefore added to the instant, and `Days` and longer in the zone.

In a skipped hour, Effect's `Cron` moves a firing forward by the gap (02:30 becomes 03:30)
rather than skipping it, unlike AWS (item 3). `nextFiring` checks the wall-clock time of
`Cron.next`'s answer and moves on to the next day when it differs.

**6. The callers.**

- `Schedule.rate` and its constructors are read only where the plan assumed:
  [Schedule.res](../../reventless/spec/src/types/Schedule.res), the two adapters,
  [ScheduleOps.res](../../reventless/core/src/util/ScheduleOps.res) and the local tests (plus
  one in `reventless/aws/tests`).
- `ScheduleOps.nextTime` has no caller and goes.
- The AWS `Daily` expression is confirmed malformed: it has `*` in both day fields.
- The Task directive, the extension-point directive handler, the SideEffectHandler, the GWT stub
  runtime and the scaffold in the tools repository pass a whole `schedule` through without
  reading it. They need no change beyond the record's field.
- Nothing in the UI, tools or business repositories builds a `rate`.
- The AWS permissions reach further than the adapter:
  - `events:*` on all resources is granted three times: the scheduler role, the Task bucket's
    Lambda policy, and the command topic's Lambda policy.
  - Each command topic's SQS queue policy admits the `events` principal, on a condition naming
    `rule/*`.
  - All four change with the move to Scheduler.

## S1: one type for a time, and the schedulers agree

The analysis's [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) and
[T10](../analysis/automations-that-run-on-a-time.md#9-open-questions); stage 1 of
[the scheduler analysis](../analysis/infrastructure-outside-the-capability-model.md#stage-1--converge-the-semantics-a-bug-fix-not-a-model-change).

- **The type.** `Schedule.time` replaces `Schedule.rate` in
  [Schedule.res](../../reventless/spec/src/types/Schedule.res): `interval`, `weekday`,
  `calendar`, `period`, `localTime`, `moment`, `zone` and
  `time = Every | Calendar | Once`; the schedule record becomes `{name, time, payload}`.
- **The bindings.** `DateTime` and `Cron` in `rescript/effect`, as far as
  [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) needs them. A
  `Cron` is always built with a zone, UTC when the time has none
  ([S0](#what-s0-found) item 5). In `rescript/pulumi-aws`: `Scheduler_Schedule` and
  `Scheduler_ScheduleGroup`. In `rescript/aws-sdk`: the `@aws-sdk/client-scheduler` commands the
  runtime uses (create, update, delete, get, list).
- **The shared reading.** One module in core, beside `ScheduleOps`, with `nextFiring(time,
  ~after)`, `resolveOnce(time, ~from)` (an `After` to an `At` in the schedule's zone, from a
  given instant), the zone check, and the AWS expression of a time (`rate(...)`, `cron(...)` or
  `at(...)`, with its zone).
  - **The daylight-saving rule is AWS's** ([S0](#what-s0-found) item 3). A `Calendar` time in
    the skipped hour does not fire that day. One in the repeated hour fires once, at the first
    occurrence. A `Once` in the skipped hour is moved forward by the gap; AWS accepts such a
    time, but its firing is not observable before the next spring change.
  - **`After(Minutes | Hours)` is added to the instant**, and `Days` and longer in the zone
    ([S0](#what-s0-found) item 5).
  - **An `Every` first fires one interval after it is set**, on both platforms. On AWS that is the
    schedule's `StartDate`.
- **Local.** `LocalScheduledPublisher` waits for `nextFiring` and waits again after each firing;
  a once-only time fires one timer. The 24-hour interval goes.
- **AWS.** The scheduled publisher moves from CloudWatch Events rules to EventBridge Scheduler:
  one schedule group per owner, the target input carrying the scheduled time, *delete after
  completion* for a once-only time. The `events:*` grants give way to the Scheduler actions on
  the platform's own groups, in all three places that hold them: the scheduler role, the Task
  bucket's Lambda policy and the command topic's Lambda policy. The command topic's queue policy
  admits the Scheduler's role instead of the `events` principal ([S0](#what-s0-found) item 6).
- **Callers.** `ScheduleOps.minutesFromNow` becomes `Once({moment: After(Minutes(n))})`; the
  plugin connect timeout, the Task, extension-point and side-effect-handler paths, and their
  tests follow. `ScheduleOps.nextTime`, which nothing calls, goes.

**Tests:** `nextFiring` for each shape, with a zone, across a daylight-saving change in both
directions (a calendar time in the skipped hour skipped for that day), on the 29th to 31st of a
month, for `Monthly` with `every` and for `Yearly`; the
resolution of `After` across a month's end; the AWS expression of each shape; **the agreement
test**: for a set of times, the AWS expression parsed by Effect's `Cron` and the local
`nextFiring` give the same next ten firings; the local publisher firing at a calendar time under
`TestClock`.

**Exit:** all suites green on in-memory, SQLite and AWS; a Task schedule and the plugin connect
timeout work on a deployed stack, by hand.

### What S1 did

Built 2026-10-16. All suites pass (457 suites, 5184 tests), and `pulumi preview` of the
hybrid example's platform stack creates the role, the group and its policy.

**On the deployed alpha stack** (2026-10-16):

- **The first deploy failed.** EventBridge Scheduler refuses a tag with an empty value, and a
  platform-scoped resource's `reventless:plugin` and `reventless:component` are empty. The
  preview could not show it. The fix, `AWS.Tags.withoutEmpty` on the group, deployed cleanly.
- **The plugin connect timeout works.** In the hour after the deploy, the plugins' heartbeats
  created or replaced their disconnect schedules 26 times without an error. Each schedule is
  an `at(…)` in UTC, deleted after it fires, with the plugin extension point's queue as target
  and the new role.
- **A Task schedule could not be checked by hand**: no Task in the hybrid example creates one.
  `TaskBucketEntryPoint_OpsTest` covers its dispatch.
- **Every stack that builds a Scheduler gets its own group.** On alpha that is the platform and
  each plugin stack, as each had its own CloudWatch Events role before. That counts towards
  the 500 groups a region allows ([Risks](#risks)).

- **The shared reading** is
  [ScheduleTime.res](../../reventless/core/src/util/ScheduleTime.res): `nextFiring`,
  `resolveOnce`, `validate` (every problem of a time in one message) and `toAws`. Its tests
  include the agreement test, eight calendar times in six zones
  ([ScheduleTimeTest.res](../../reventless/core/tests/util/ScheduleTimeTest.res)).
- **The bindings:**
  - `DateTime`, `Cron` and `Clock` in [rescript/effect](../../rescript/effect/src/).
  - `EventBridgeScheduler` (create, update, delete) in [rescript/aws-sdk](../../rescript/aws-sdk/src/).
    The client is pinned to the other clients' release, so the Lambda layer carries one SDK core.
  - `Scheduler.ScheduleGroup` in [rescript/pulumi-aws](../../rescript/pulumi-aws/src/Scheduler/).
- **The documentation** of the Scheduler, the Task, the SideEffectHandler and both
  ScheduledPublisher adapters now uses `Schedule.time`.

Where it departs from the plan above:

- **No Pulumi `Schedule` binding, and no `get` or `list` command.** Schedules are made at run
  time ([P1](#open-questions) recommends the same for declared ones), and nothing reads one back
  until the reconcile of [S5](#s5-schedules-set-by-events), which adds what it needs.
- **One group per platform scheduler, named after its role.** The runtime already receives the
  role's ARN in about fifteen places. Naming the group after the role gives the runtime the group
  too, without a second value threaded through all of them. The groups per scheduled slice of
  [§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names)
  come with [S4](#s4-declared-schedules).
- **The target input is the payload, unchanged.** Today's callers deliver their own payloads,
  and adding the scheduled time to them would change what their consumers receive. The time
  comes with the framework's own input, `{slice, key, at}`, in [S4](#s4-declared-schedules).
- **The command topic's Lambda may manage the schedules of every scheduler group in the
  account** (`SchedulerRole-*`). Its policy is built without the scheduler role, unlike the Task
  bucket's, which is scoped to the one group.
- **The local publisher runs on plain timers, tested under Jest's fake clock rather than
  `TestClock`.** Every time it waits for comes from `ScheduleTime`, so the date work still goes
  through Effect ([Rules](#rules-every-phase-keeps) 5). Effect's fibers under fake timers would
  make the tests depend on Effect's internal scheduling.
- **Effect never wakes from a sleep longer than 2³¹ ms, and Node fires such a timer at once.**
  The local publisher waits at most a day at a time.
- **A once-only time already past never fires**, locally as on AWS. Before, the local platform
  fired a `Single` at once, whatever its date.

## S2: the local platform sweeps

[S0](#what-s0-found) item 1 confirmed it. The local platform runs the automation sweep as AWS
does, every five minutes, over every automation's pending and failed items. Like the AWS sweep,
it loads the to-do list, runs `phase2` and writes the list back to the query store; core's
`processPending` does only the middle step and gains the other two. The interval can be
shortened for development ([P3](#open-questions)). A slice's `heartbeatInterval` stays unread
([T6](../analysis/automations-that-run-on-a-time.md#9-open-questions)).

**Tests:** an item `process` left pending is retried by the local sweep; a failed item is retried
up to `maxRetries`.

**Exit:** a deadline written as in [§3](../analysis/automations-that-run-on-a-time.md#3-deadlines-today)
passes locally without another event.

### What S2 did

Built 2026-10-16; the exit holds
([AutomationSweepTest.res](../../reventless/local/tests/components/automationslice/AutomationSweepTest.res)).

- **One local sweep for every automation**, as on AWS:
  [LocalAutomationSweep.res](../../reventless/local/src/components/LocalAutomationSweep.res).
  - Each slice the local builder makes registers its `processPending`.
  - Every five minutes the sweep runs them one after another. A failing slice is logged and the
    rest still run.
  - `REVENTLESS_LOCAL_SWEEP_SECONDS` shortens the interval ([P3](#open-questions), as
    recommended).
  - The timer is `unref`ed, so it never keeps a process or a test run alive.
- **`processPending` writes the to-do list back** to the query store after `phase2`, on both
  platforms.
- **A sweep and an event's own `phase2` can overlap safely.** `phase2` marks an item
  `Processing` before its first `await`, so the two never send the same command.

Two findings change what the plan assumed:

- **No load.** The local sweep does not load the to-do list from the store, unlike AWS. The core
  `QueryDb` operations have no scan, and while the process runs, the slice's in-memory list is
  already current. After a restart on SQLite, pending rows stay unswept until an event reaches
  the slice. That gap predates the sweep.
- **The sweep never resends an item stuck in `Processing`.** `phase2` takes only `Pending` items,
  and `Failed` items under `maxRetries`, on both platforms. The analysis
  ([§5.2](../analysis/automations-that-run-on-a-time.md#52-the-tick-is-a-source)) and the
  component guide counted on the sweep to send again a command that was published but never
  answered. The guide is corrected. A tick's item, whose resolving event may never come, needs
  that resend, so [S4](#s4-declared-schedules) adds it: a timeout after which a `Processing`
  item counts as pending again.

## S3: the time inside the functions

The analysis's [§6](../analysis/automations-that-run-on-a-time.md#6-the-time-inside-the-functions).

- `collect` and `resolve` get the source event's recorded time on their `context`.
- `process` gets `~now`, from Effect's `Clock`; the PPX supplies it to a `process` that does not
  take it ([S0](#what-s0-found) item 2). That rewrite is tried on one PPX golden first. If it
  fails, `~now` becomes a required argument, with a codemod over the examples.
- The GWT DSL gains `atTime(t)`, which fixes `now` and the recorded time of the events a
  scenario gives.

**Tests:** the deadline of [§8.1](../analysis/automations-that-run-on-a-time.md#81-a-deadline-an-order-not-shipped-in-three-days-is-cancelled)
as two scenarios, *at day 3 then `CancelOrder`* and *shipped on day 2 then nothing*; every
existing automation's suite unchanged and green.

**Exit:** a deadline is testable at a fixed time; no existing automation changed.

### What S3 did

Built 2026-10-16; the exit holds. The deadline runs as GWT scenarios
([AutomationDeadlineGwtTest.res](../../reventless/gwt/tests/AutomationDeadlineGwtTest.res)) and
on the local runtime ([AutomationSweepTest.res](../../reventless/local/tests/components/automationslice/AutomationSweepTest.res)).
The three example automations compile unchanged.

- **`process` takes `~now`.** The runtime reads it from Effect's `Clock` once per `phase2`. The
  PPX's new pass ([NowInjection.ml](../../packages/reventless-ppx/src/ppx/NowInjection.ml)) adds
  `~now as _` to a `process` literal without it. The trial ran as fixtures in the PPX's test
  script rather than a JSON golden: one `process` without `~now`, one that reads its own.
- **`recordedAt` on the context**, from the envelope's `meta.time`, for every event the runtime
  delivers.

Where it departs from the plan above:

- **`recordedAt` is optional and reaches `collect` only.** It is optional so that a context
  built by hand, in tests or by other code, still compiles. `resolve` takes no context, and
  giving it one would change every mapping's signature for a need nothing names.
- **`atTime(t)` fixes when the events happened, and `~now` when the sweep runs.** One time cannot
  serve both, because a deadline needs the events on day 0 and the sweep on day 3. Without `~now`
  the sweep runs at the latest recorded time, so `givenEvents(es)->atTime(t)->whenSweep` still
  runs wholly at `t`. `Mapping(M).event(e, ~recordedAt)` dates a single event, and
  `whenProcess(~now)` and `whenCollect(~recordedAt)` cover the unit steps.
- **Code the PPX does not see must take `~now` itself.** That is a `process` in an `Automation`
  module written by hand, or in a `SliceSpec` given to the deprecated `Automation_GWT.Make` or
  `Flow_GWT.AutomationStep`. In this repository that meant seven test fixtures; for anyone else
  it is the one breaking part of this phase.

## S4: declared schedules

The analysis's [§5.1 to §5.5](../analysis/automations-that-run-on-a-time.md#51-the-spec) and
[§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names).

- **The spec** gains `let schedule: option<Schedule.time>`; the PPX injects `None` when absent and
  writes the declared time into `.model.json`, which needs `schedule` among the sidecar's
  `config_keys` ([S0](#what-s0-found) item 2).
- **The `Clock` source**, `Reventless.Clock`: `name`, `@schema type event = Tick({key, at})`,
  `itemId(key, at)`.
- **A `Processing` item counts as pending again after a timeout**, so the sweep resends a
  tick's command that no event answered ([What S2 did](#what-s2-did)).
- **The runtime** turns a Scheduler invocation (`{slice, key, at}`) into `Tick({key, at})` for
  the slice's mappings, then runs `process` as for an event batch. The automation runtime is
  given the scheduler's operations.
- **No schedule rows yet** ([D1](#decisions-2026-10-16)). A declared schedule's truth is the
  spec; the rows come with [S5](#s5-schedules-set-by-events), in a store of their own.
- **The declared default is put on the platform at deploy** by a deploy-time invocation of the
  automation Lambda, which reconciles it ([D2](#decisions-2026-10-16)). It goes into the stack's
  scheduler group under the name `<slice>.default` ([D3](#decisions-2026-10-16)).
- **A slice that maps `Clock` without a `schedule` fails at plugin assembly**, not in the PPX:
  the PPX sees the automation file without its spec. Assembly reports it at the same moments:
  deploy, boot and tests.
- **The plugin's structure** carries the declared time.
- **The GWT DSL** gains `whenTick(key, at)`, through the same path as `whenSweep`.

**Tests:** the demand report of [§8.2](../analysis/automations-that-run-on-a-time.md#82-a-declared-schedule-the-demand-report-every-morning)
end to end in memory: the tick makes the day's item, `process` sends `RequestDemandReport`, the
returned event resolves it; the same tick delivered twice adds one item; the assembly check;
the declared time in `.model.json`; a `Processing` item sent again after the timeout.

**Exit:** the demand report runs locally at its time and on a deployed stack, by hand; the
platform's schedule `<slice>.default` matches the declared time after a deploy.

### Decisions, 2026-10-16

Three changes to the analysis's design, taken while building this phase. They are numbered D1
to D3.

**D1. Schedule rows get a store of their own, `<Slice>Schedules`, made only for a scheduled
slice.** The analysis put them in the to-do store
([§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names),
[T11](../analysis/automations-that-run-on-a-time.md#9-open-questions)), so that every stored row
still decodes. It would not:

- A to-do row requires `item`, `status`, `createdAt` and `retryCount`, and the store's GraphQL
  type makes them non-null. One store means making those optional.
- Optional fields cost the runtime its type safety: `phase2`, retries and rehydration all read
  them.
- Readers see both kinds of row mixed. The automatic UI shows the to-do list as a panel, and
  anything that counts pending work would have to filter by `rowKind`.
- A rebuild has to pick out the schedule rows with a filtered scan, without touching the to-dos.
- The schedules cannot get an access rule of their own. Per-customer schedules say who receives
  messages and when, which may warrant a narrower one.

The cost of [D1](#decisions-2026-10-16) is one table, its resolvers and its query per scheduled slice. Built in
[S5](#s5-schedules-set-by-events); [S4](#s4-declared-schedules) has no rows. The reserved
`schedule#` prefix goes too: with its own store, `collect` may use any id.

**D2. A deploy-time Lambda invocation reconciles the declared schedules**, the pattern of the
Postgres migration (`Lambda.Invocation` in `PgMigration_Builder.res`). It runs again when a
declared schedule changes, and a failure fails the deploy. The alternatives:

- A Pulumi `aws.scheduler.Schedule` per declared schedule would put a default back on the next
  deploy after an event replaced it ([P1](#open-questions)).
- The Lambda reconciling on its first run after a deploy would surface a failure only in its
  logs.

**D3. One schedule group per stack, the one its Scheduler already has**, not one per scheduled
slice as in
[§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names).
A region allows 500 groups by default, and alpha already holds three: the platform and each
plugin stack. A schedule is named `<slice>.<key>`, hashed when it is too long or holds other
characters ([§5.8](../analysis/automations-that-run-on-a-time.md#58-keys-and-rows-in-the-query-store-and-the-platforms-names)'s
rule). Reconcile lists the group by the slice's name prefix, once
[S5](#s5-schedules-set-by-events) adds the list.

### Where S4 stands, 2026-10-16

Built and tested, not committed. The full suite passes: 461 suites, 5206 tests; the PPX's
own tests pass, 450 checks. Only the deployed check of the exit is left
([below](#what-is-left-of-s4)).

- **Spec:**
  - `Reventless.Clock`, with `Tick({key, at})`, `itemId` and `defaultKey`.
  - `let schedule` on the spec.
- **PPX:** `schedule_suffix` injects `None`, and `.model.json` records a declared time as its
  source text (`SidecarEmit.schedule_value`). Both have a check in the PPX's test script.
- **Core:**
  - The `tick` operation; `tickEvent` builds the `Clock` envelope.
  - The `Processing` timeout of 15 minutes, counted as a failed attempt.
  - The assembly check.
  - `sourceNames` without `Clock`.
  - No reserved item ids ([D1](#decisions-2026-10-16)).
- **Local:** `LocalTimers`, shared by the scheduled publisher and the new
  `LocalAutomationSchedules`, which ticks a slice's declared schedule
  ([AutomationScheduleTest.res](../../reventless/local/tests/components/automationslice/AutomationScheduleTest.res)).
- **AWS:**
  - The automation Lambda takes a tick as a third kind of invocation without records, beside
    the sweep: `{"reventlessTick": {slice, key, at}}`, with `at` filled in by the Scheduler
    ([AutomationSliceEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/AutomationSliceEntryPoint_Ops.res)).
    It runs as an event batch does: load, phase 1, sync, phase 2, sync. A tick for a slice the
    Lambda does not host throws, so the Scheduler retries and the error is logged.
  - The Lambda gets the stack's scheduler role as `SCHEDULER_ROLE_ARN`, may manage the schedules
    of its group and pass the role, as Tasks may. The scheduler role may invoke the Lambda.
  - Each deploy invokes the Lambda to reconcile the declared schedules
    ([D2](#decisions-2026-10-16)). Its input carries the declared times, so a changed time
    re-runs it.
  - A schedule is named `<slice>.<key>`. When that is not a valid name, it is the slice's name
    cut to 40 characters, a dot and 16 hex digits of the key's SHA-256
    ([D3](#decisions-2026-10-16)).
- **The plugin's structure:** an optional `schedule` on `automationSliceDef`, also in the admin
  API's SDL, its encoder and `AdminApiSchemaDriftTest`; the platform API golden is refreshed.
- **GWT:** `tick` and `whenTick`, and `AutomationScheduleGwtTest`.

Where it departs from the plan above:

- **The reconcile also removes `<slice>.default` from an automation that declares no
  schedule**, so taking a schedule out of a spec takes it off the platform. It therefore runs on
  every stack with automations, not only on those with a declared time. The schedule of a slice
  deleted from the plugin stays until [S5](#s5-schedules-set-by-events) adds the list that
  reconcile needs to find it.
- **The reconcile reads each time from the spec module the Lambda runs**, not from its input.
  The input only makes Pulumi invoke again when a time changes.
- **The structure carries the time as its JSON text, in a `String`.** A stored structure is
  served by the admin API as it is stored, and the time as an object in a `String` field would
  fail that read. The admin API keeps away from `AWSJSON` for the same reason.

### What is left of S4

- **The deployed check of the exit moves to [S5](#s5-schedules-set-by-events)** (2026-10-16).
  It needs a scheduled automation on a deployed stack, and the online shop has none:
  [P2](#open-questions) leaves the demand report out of it. The digest that S5's exit deploys
  goes through the same tick path and the same reconcile.

## S5: schedules set by events

The analysis's [§5.6](../analysis/automations-that-run-on-a-time.md#56-schedules-set-by-events) and
the once-only part of [§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time).

- **`reschedule`** on `Mapping`, returning `Set({key, time})` or `Clear({key})`; the PPX injects
  `_ => []` where absent and marks the mapping in `.wiring.json`. This takes a new walk into the
  third argument of `Mapping.Make`, in the merged `_Automation.res` form and the older
  `_Mappings.res` form ([S0](#what-s0-found) item 2).
- **The schedules store** `<Slice>Schedules` ([D1](#decisions-2026-10-16)), made only for a
  slice that declares a `schedule` or has a mapping that reschedules. A row per key: `key`,
  `time`, `setBy` (the event's id, or `declared`), `setAt`, `platformName`.
- **The runtime** writes each change to the schedule rows first, then to the platform; an
  `After` is resolved with the event's recorded time; a once-only key is cleared when its tick
  arrives.
- **Rebuild and reconcile**: rebuilding a slice replays `reschedule` over its source events in
  order, writes the declared default unless `default` is set, and brings the platform's group in
  line; a once-only time already past is not made again
  ([T7](../analysis/automations-that-run-on-a-time.md#9-open-questions)).
- **The schedules store's own list query** answers *when does it run, and who set it*. The
  to-do store is unchanged, so [T11](../analysis/automations-that-run-on-a-time.md#9-open-questions)'s
  `rowKind` falls away ([D1](#decisions-2026-10-16)).
- **The declared default is written into the schedules store** by the reconcile of
  [D2](#decisions-2026-10-16), unless an event has set `default`.
- **The GWT DSL** gains `thenSchedules`.

**Tests:** the moved report of [§8.3](../analysis/automations-that-run-on-a-time.md#83-the-same-schedule-moved-by-an-event)
(an event replaces the declared default, and a later deploy keeps it); the digest of
[§8.4](../analysis/automations-that-run-on-a-time.md#84-a-schedule-per-customer-the-marketing-digest)
(set, fire, resolve by `reference`, clear on unsubscribe); the reminder of
[§5.7](../analysis/automations-that-run-on-a-time.md#57-three-shapes-of-a-time) (set ten minutes
after the recorded time, cleared when the order ships, cleared after it fires); a rebuild that
reproduces the rows and removes a stray platform schedule.

**Exit:** the digest runs on a deployed stack for two recipients with different zones, by hand;
a rebuild leaves the platform's schedules of the slice equal to its rows. The deploy that checks
it also checks [S4](#s4-declared-schedules)'s exit: the reconcile puts the schedules on the
platform, and their ticks reach the slice.

### Where S5 stands, 2026-10-16

The framework half is built and tested, not committed: 464 suites, 5237 tests; the PPX's
tests, 451 checks. Left: the digest in the online shop and the deployed check
([below](#what-is-left-of-s5)).

- **Spec:** `scheduleChange = Set({key, time}) | Clear({key})`, and `reschedule` on `Mapping`
  and `MappingImpl`.
- **PPX:** [RescheduleInjection.ml](../../packages/reventless-ppx/src/ppx/RescheduleInjection.ml)
  adds `let reschedule = _ => []` to a `Mapping.Make` third argument without one, in the merged
  `_Automation.res` form and the older `_Mappings.res` form. `.wiring.json` records
  `reschedules` per mapping, as written.
- **Core:** [AutomationSlice_Schedules.res](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Schedules.res),
  shared by the runtime and the GWT DSL:
  - A row per key: `key`, `time`, `setBy` (the event's `msgId`, or `declared`) and `setAt`.
  - `apply` folds one change. An `After` is counted from the event's recorded time, and a time
    that cannot fire is refused and logged.
  - `fired` drops a once-only schedule's row when its tick arrives.
  - `declare` brings the spec's time in under `default`.
  - `reconcile` brings the platform in line with the rows.
  - The callback folds `reschedule` in phase 1 and queues the platform's changes; its driver
    stores the rows first, then tells the platform. `rebuildSchedules` folds a list of events
    into empty rows.
- **The schedules store** `<Slice>Schedules` is made for a slice that maps the `Clock`, with its
  own list query, and is registered beside the to-do store.
- **The platform's side** is `platformSchedules` (`put`, `removeName`, `names`, `nameOf`):
  - Locally, [LocalAutomationSchedules.res](../../reventless/local/src/components/LocalAutomationSchedules.res)
    holds the timers, and each slice reconciles when it is made.
  - On AWS, the automation Lambda loads and syncs the rows, follows them with EventBridge
    Scheduler, and lists the group with `ListSchedules`, which the Lambda is granted on every
    resource. The deploy's reconcile now runs on every build as well as on a changed time.
- **GWT:** a scenario folds `reschedule` after the declared time; `thenSchedules` compares the
  rows by key ([AutomationRescheduleGwtTest.res](../../reventless/gwt/tests/AutomationRescheduleGwtTest.res),
  and the moved report in [AutomationScheduleGwtTest.res](../../reventless/gwt/tests/AutomationScheduleGwtTest.res)).
- **Tests:**
  - The moved report, the digest and the reminder as GWT scenarios.
  - The digest on the local runtime, two recipients in two zones, with a rebuild that removes
    a stray timer ([AutomationRescheduleTest.res](../../reventless/local/tests/components/automationslice/AutomationRescheduleTest.res)).
  - The rows and the reconcile against a fake platform
    ([AutomationSliceSchedulesTest.res](../../reventless/core/tests/automationslice/AutomationSliceSchedulesTest.res)).
  - The AWS names, and the order of steps in the Lambda.

Where it departs from the plan above:

- **Clearing `default` leaves a row** with no time, so a later deploy does not put the
  declared time back (the stopped report of
  [§8.3](../analysis/automations-that-run-on-a-time.md#83-the-same-schedule-moved-by-an-event)).
  Any other key's row is removed.
- **No `platformName` on the row.** The name follows from the slice and the key, and the
  platform's side gives it (`nameOf`), so storing it would be a second copy.
- **The time is stored as JSON text**, for the reason the structure stores it so
  ([What S4 did](#where-s4-stands-2026-10-16)).
- **The reconcile does not put again a row an event set** when the platform holds it: that
  row reached the platform when it changed. It puts what is missing, the declared time, and
  removes what the rows do not hold.
- **A rebuild is an operation, not a trigger.** Nothing in the framework rebuilds an
  automation yet; `rebuildSchedules(events)` is there for whatever does, and is tested.
- **The assembly check accepts a `Clock` mapping without a declared time** when the slice
  reads any event, since one of them may set a schedule. A `Set` on a slice that maps no
  `Clock` is logged and skipped.
- **Locally, a restart reads no rows back**, the gap [What S2 did](#what-s2-did) noted for
  the to-do list.

### What is left of S5

- **The digest in the online shop**, pulled forward from [S6](#s6-the-guide-the-words-and-the-examples):
  `ChooseDigestTime` on `NotificationPreferences` and the `MarketingDigest` automation of
  [§8.4](../analysis/automations-that-run-on-a-time.md#84-a-schedule-per-customer-the-marketing-digest),
  with its GWT scenarios.
- **The deployed check**, which also covers [S4](#s4-declared-schedules)'s exit.

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
  changes of the year, and [S0](#what-s0-found) item 3 took AWS's rule from its documentation.
  The rule for a one-time `at(...)` in a skipped hour is undocumented. AWS accepts such a
  schedule, but when it fires can only be seen at the next spring change, on 2027-03-28 in
  Europe.
- **Schedule groups.** EventBridge Scheduler allows 500 groups per region by default, and the
  design takes one per scheduled slice and stack. A region holding several stacks with many
  scheduled slices would need the quota raised, or one group per plugin
  ([S0](#what-s0-found) item 3).
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
asks plugins to reconnect. **Decided 2026-10-16:** a deploy-time Lambda invocation does the
asking ([D2](#decisions-2026-10-16)).

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
