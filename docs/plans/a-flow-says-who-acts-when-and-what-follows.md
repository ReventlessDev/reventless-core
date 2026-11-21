# Plan: a flow says who acts, when, and what follows

**Date:** 2026-11-21<br/>
**Status:** 📋 Proposed 2026-11-21, nothing built. Steps numbered FS1 to FS13, open questions
FSQ1 to FSQ5, each with a recommendation. *FS* is short for *flow step*.<br/>
**Repos:** `reventless-core` only.<br/>
**Owns:** the flow test: [`Flow_GWT.res`](../../reventless/gwt/src/Flow_GWT.res), how the PPX
records a flow's steps beside it, and the four flow files of the example shops.<br/>
**Builds on:** [the flow and extension test kinds](done/gwt-flow-and-extension-test-kinds.md),
which built the flow test; [the aggregate step](done/flow-gwt-aggregate-step.md);
[the sidecars read automations and translations](done/the-sidecars-read-automations-and-translations.md),
which records a flow's ordered steps and added the step for a way in;
[a row can belong to the caller](done/owner-scoped-identity-and-reads.md), whose read decision
[FS8](#fs8-a-view-is-read-as-a-person) reuses.

> **Questions and short answers**
>
> - *What is wrong with a flow today?* **Its shape is right; seventeen things in it are not.** A
>   flow can pass while what it describes is not true, it has no time and no person, a failure
>   does not say which step failed, and it reads worse than it needs to
>   ([§2](#2-what-is-wrong-today)).
> - *What comes first?* **The renaming, once, with the four example files rewritten as its test**:
>   one naming for all steps, each system's steps ready under the part's own name, repeated
>   values named ([FS1](#fs1-one-naming-for-the-steps), [FS2](#fs2-a-system-offers-its-steps-ready-made)).
>   It goes first so that nothing is built on names that then change.
> - *What does a reader of the steps file get?* **The step a failure belongs to and the part
>   behind every step** ([FS3](#fs3-a-failure-names-its-step)). First release.
> - *What does a flow gain after that?* **It runs what was sent, states less of a row where it
>   means to, keeps time, and says who acts and who looks**
>   ([FS4](#fs4-a-step-runs-what-was-just-sent) to [FS8](#fs8-a-view-is-read-as-a-person)),
>   **reacts once and leaves no reaction out, and starts after another flow**
>   ([FS9](#fs9-what-reacts-reacts-once-and-nothing-else-does),
>   [FS10](#fs10-a-flow-starts-after-another)). Second release.
> - *And then?* **The scope check without a test, true ids, and the parts that have no step**
>   ([FS11](#fs11-a-boundarys-scope-is-checked-without-a-test) to
>   [FS13](#fs13-the-parts-that-have-no-step)).
> - *What can run side by side?* **After the renaming, most of it**; the PPX is the narrow
>   place ([§3](#3-steps)).

---

## 1. Scope

**In:** the flow test and what it records. Every change keeps a flow one chain of steps over one
shared record, each step running the part's own code with no bus and no timers.

**Out:**
- A flow run against a running platform. The seed plays steps into one; that stays the seed's.
- A language of its own for flows, or a flow the runtime reads.
- The tests of a single part, except where a step needs the same thing there
  ([FS6](#fs6-expectations-that-are-missing), [FS8](#fs8-a-view-is-read-as-a-person)).

---

## 2. What is wrong today

Read from [`Flow_GWT.res`](../../reventless/gwt/src/Flow_GWT.res) and the four example files
([hybrid, one system](../../examples/online-shop-hybrid/ordering/tests/Flow/OrderingFlow_GWT.res),
[hybrid, two systems](../../examples/online-shop-hybrid/platform-local/tests/Flow/HybridFlow_GWT.res),
[DCB](../../examples/online-shop-dcb/platform-local/tests/Flow/DcbFlow_GWT.res),
[aggregates](../../examples/online-shop-aggregates/platform-local/tests/Flow/AggregatesFlow_GWT.res)).

| # | Finding | Step |
|---|---|---|
| 1 | A command an automation or an extension sent is typed a second time to be run. The two are values of two types and are never compared | [FS4](#fs4-a-step-runs-what-was-just-sent) |
| 2 | Only the reactions the author names happen. An automation that would react and change the outcome is silently absent; at a fan-out of two commands the flow runs one | [FS9](#fs9-what-reacts-reacts-once-and-nothing-else-does) |
| 3 | A reaction step sweeps the whole record each time, less what later events settled; it cannot say what is new | [FS9](#fs9-what-reacts-reacts-once-and-nothing-else-does) |
| 4 | Both ends of an extension point run with the id `gwt-id` unless the event came from an aggregate; a way out runs with an empty source id | [FS12](#fs12-the-record-keeps-the-id-an-event-was-recorded-under) |
| 5 | A flow has no time: an entry of the record has none, a reaction runs at the machine's clock, no schedule comes due. A view row reads *1970-01-01* | [FS7](#fs7-a-flow-keeps-time) |
| 6 | A command step has no caller, though a decision's own test has `asCaller` | [FS8](#fs8-a-view-is-read-as-a-person) |
| 7 | A view step states one whole row or nothing: not some fields, not *no such row*. The DCB command step has no *records nothing* | [FS6](#fs6-expectations-that-are-missing) |
| 8 | No step for what a way out sends and the answer to it, for a query, for a side effect | [FS13](#fs13-the-parts-that-have-no-step) |
| 9 | A flow cannot start after another flow; what came before is typed as events | [FS10](#fs10-a-flow-starts-after-another) |
| 10 | A failure carries no step: the mismatch has what was expected and found, the hint reads `Flow.decide` | [FS3](#fs3-a-failure-names-its-step) |
| 11 | Each part is set up under a name the author makes up (`Cat`, `Sync`), in a block above the tests; eleven lines in the two-system flow | [FS2](#fs2-a-system-offers-its-steps-ready-made) |
| 12 | `CommandStep` and `ViewStep` beside `AutomationSlice`, `OutboundSlice`, `InboundSlice`; the deprecated `AutomationStep` and `OutboundStep` still there; `whenPublishedThrough`, `whenExtensionReacts` | [FS1](#fs1-one-naming-for-the-steps) |
| 13 | The same literal written out each time: one price 22 times in the two-system flow | [FS1](#fs1-one-naming-for-the-steps) |
| 14 | A flow carries a title and nothing else: no place for what it tells | [FS3](#fs3-a-failure-names-its-step) |
| 15 | The steps file names a step by the made-up name only: a reaction step is `whenReacts` through `Auto`, with no part | [FS2](#fs2-a-system-offers-its-steps-ready-made), [FS3](#fs3-a-failure-names-its-step) |
| 16 | The check that a boundary derives its scope is a test with no steps, written by hand per system | [FS11](#fs11-a-boundarys-scope-is-checked-without-a-test) |
| 17 | A view step checks what a row holds, not whether the caller may read it. No test without a running platform reads a view as a person | [FS8](#fs8-a-view-is-read-as-a-person) |

What stays as it is: **an event is stated in full.** The event a step records is what the next
step runs on; a flow that left its values out would hide what it is there to show.

---

## 3. Steps

Three releases. **Release A** after [FS3](#fs3-a-failure-names-its-step): what a reader of the
steps file needs. **Release B** after [FS10](#fs10-a-flow-starts-after-another):
what a flow written from a told sequence of steps needs, since such a sequence has people and
times, follows on earlier ones, and must not leave a reaction out. **Release C** the rest.

Within a release the steps do not all wait for each other:

| Step | Needs | Can run beside |
|---|---|---|
| [FS1](#fs1-one-naming-for-the-steps) | nothing | nothing: it renames what every other step touches |
| [FS2](#fs2-a-system-offers-its-steps-ready-made), [FS3](#fs3-a-failure-names-its-step) | [FS1](#fs1-one-naming-for-the-steps) | each other |
| [FS4](#fs4-a-step-runs-what-was-just-sent), [FS6](#fs6-expectations-that-are-missing), [FS7](#fs7-a-flow-keeps-time), [FS8](#fs8-a-view-is-read-as-a-person) | release A | each other; [FS8](#fs8-a-view-is-read-as-a-person)'s shared read function needs no flow at all and can start with [FS1](#fs1-one-naming-for-the-steps) |
| [FS9](#fs9-what-reacts-reacts-once-and-nothing-else-does) | [FS2](#fs2-a-system-offers-its-steps-ready-made), [FS4](#fs4-a-step-runs-what-was-just-sent) | [FS6](#fs6-expectations-that-are-missing) to [FS8](#fs8-a-view-is-read-as-a-person) |
| [FS10](#fs10-a-flow-starts-after-another) | [FS7](#fs7-a-flow-keeps-time), for the time a flow hands on | [FS8](#fs8-a-view-is-read-as-a-person), [FS9](#fs9-what-reacts-reacts-once-and-nothing-else-does) |
| [FS11](#fs11-a-boundarys-scope-is-checked-without-a-test) | [FS2](#fs2-a-system-offers-its-steps-ready-made) | anything after release A |
| [FS12](#fs12-the-record-keeps-the-id-an-event-was-recorded-under), [FS13](#fs13-the-parts-that-have-no-step) | release A | anything |

The PPX is the narrow place: [FS1](#fs1-one-naming-for-the-steps), [FS2](#fs2-a-system-offers-its-steps-ready-made), [FS3](#fs3-a-failure-names-its-step), [FS6](#fs6-expectations-that-are-missing) and [FS10](#fs10-a-flow-starts-after-another) change what it records, and its two
binaries are rebuilt for each. Steps that touch it are best landed one after the other even
where the table lets them run side by side.

Every step that touches the PPX rebuilds both binaries (macOS, and Linux through Docker) and
adds a fixture under the PPX tests. Every step keeps the four example files green under jest.

### FS1 One naming for the steps

- **One ending, `Step`, for every step**, and the two deprecated steps removed:

  | Today | After |
  |---|---|
  | `CommandStep` | `DecisionStep` |
  | `AggregateCommandStep` | `AggregateStep` |
  | `ViewStep` | `ViewStep` |
  | `AutomationSlice` (and the deprecated `AutomationStep`) | `AutomationStep`, taking the slice as written |
  | `OutboundSlice` (and the deprecated `OutboundStep`) | `OutboundStep`, taking the slice as written |
  | `InboundSlice` | `InboundStep` |
  | `ExtensionPointStep`, `ExtensionStep` | unchanged |

- **Two verbs said as what happens**: `whenPublishedThrough` becomes `whenPublished`,
  `whenExtensionReacts` becomes `whenReacts`, the verb an automation step has.
- **No alias for the old names.** The four example files are the only users in this repository;
  an app outside it gets a compile error that names the new step, through a deprecated module
  that holds only a comment ([FSQ1](#4-open-questions)).
- **Repeated values named once**, in the examples file each flow already opens: the book, the
  priced line, the total. Events stay stated in full.
- **The PPX**: the verb lists of [`SidecarEmit.ml`](../../packages/reventless-ppx/src/ppx/SidecarEmit.ml)
  take the new verbs; the old ones go.
- **The guide** ([given-when-then](../../packages/doc/docs-app/given-when-then.md)) gets its
  flow section rewritten once, here.

**Exit:** the four example files rewritten and green; the three flow tests of the gwt package
green; no `Slice` in a step's name; the price literal of the two-system flow written once.

### FS2 A system offers its steps ready-made

- **Each system has a module of its steps under the parts' own names**, generated where the
  system's list of parts is, so that a flow reads `Ordering.Flow.PlaceOrder.whenCommand(…)` and
  the block of made-up names above the tests goes ([FSQ2](#4-open-questions): `generate-plugin`
  writes it as `tests/Flow.res`).
- **A flow across systems** opens the flow modules of the systems it crosses; it still lives in
  the platform's package, which is the only one that holds both.
- **Setting a step up by hand stays possible**, for a flow over parts that belong to no
  generated system, as in the gwt package's own tests.
- **The steps file records the part of every step**: its system, its kind and its name, beside
  the name it was called through. A reaction step and a view step, which name no command or
  event, are no longer nameless.

**Exit:** the four example files with no step set up by hand; every entry of their steps files
names a part; a PPX fixture for a hand-set-up step, whose part is read from the functor's
arguments.

### FS3 A failure names its step

- **Every step numbers itself** as the flow passes it.
- **The mismatch carries the step**: its number, its verb and its part. A new field on the
  flow's outcome, not a new mismatch kind; the JSON formatter's schema version moves.
- **The hint names the part**: `Ordering.PlaceOrder.decide`, not `Flow.decide`
  ([`Hint.res`](../../reventless/gwt/src/Hint.res)).
- **The human and the editor formatters** print *step 6 of 11, ShipOrder*. Of the formats, only
  jest's is in this repository; the runner and its formatters are not. The step therefore travels
  in what every formatter already prints, the hint: `Hint.format` opens with the step, and
  `Hint.toJson` carries it as `step`.
- **`~tells` on a flow's test**: a free name for what the flow tells, recorded in the steps
  file. This repository gives it no meaning. It is here, in the first release, because a reader
  of the steps file joins a flow to what it tells by it.

**Exit:** a flow of the gwt package's tests that fails at its sixth step says so in all four
formats. **Release A.**

### FS4 A step runs what was just sent

- **`whenIssued` on a decision step**: takes the commands the last reaction, extension or way
  in sent, decodes each through the decision's command schema and runs them in order. A command
  the decision cannot read fails the step, with the command and the schema's reason.
- **A fan-out is run whole**: two commands sent, two run. `whenIssued(~only=…)` runs one, and
  says in the steps file that the others were left.
- **`thenIssuesCommand(s)` stays**, as the place to state what is expected; `whenCommand` with a
  typed command stays, for a step a person takes.
- The example files use it wherever a command is typed twice today.

**Exit:** a test in which the automation's command and the decision's differ in one field: it
passes today, typed twice, and fails with `whenIssued`.

### FS5 Expectations on events stay whole

Nothing is built here; it is written down so that it is not built by accident. An event is not
stated by its kind alone, and no step compares *some fields* of an event. The one exception is
[FS6](#fs6-expectations-that-are-missing)'s *accepted*.

### FS6 Expectations that are missing

- **`thenRowShows(id, pick, expected)` on a view step**: the row is built as today, `pick` is
  applied to it, and the result is compared with `expected`. The fields `pick` leaves out are
  built and not compared. `pick` is code over the view's own row type, so a renamed field stops
  the build. The steps file records the fields picked and their values.
- **`thenNoRow(id)`** on a view step, as `thenNoState` on a view's own test.
- **`thenNoEvent`** on the DCB decision step, as the aggregate step has it.
- **`thenAccepted`** on both decision steps: passes if the decision did not refuse and compares
  no event. It is for a flow written with no author present, whose worked-out values nobody has
  confirmed; the steps file marks the step as *values open* so that a tool can ask for them.
  The guide says it is not for a flow a person writes.
- **The whole-row step is renamed `thenRow`** (from `thenViewState`), with
  [FS1](#fs1-one-naming-for-the-steps) if it lands in the same release, else here.

**Exit:** each on a fixture; the guide says what `thenRowShows` does not notice (a wrong field
it did not pick), and that the view's own test states the whole row.

### FS7 A flow keeps time

- **An entry of the record has a time.** A step may say when it happens (`~at`); a step that
  says nothing happens at the time of the step before it; a flow starts at a fixed instant, as
  today.
- **Events are recorded with that time**, so a view row that keeps *placed at* or a trail of
  states shows the story's times, not 1970.
- **A reaction step runs at the flow's time**, not the machine's clock.
- **`whenTimePasses(~until)`**: runs every schedule that comes due up to then, declared or set
  by an event, as `whenTick` does in an automation's own test
  ([`Automation_GWT.res`](../../reventless/gwt/src/Automation_GWT.res)); the commands they send
  are the step's sent commands.
- **Time only moves forward**; a step earlier than the one before it fails the flow.

**Exit:** a flow in which an automation with a schedule set by an event sends its command an
hour later, and not before; the ordering flow's view row with the times of its steps.

### FS8 A view is read as a person

- **`asCaller` before a decision step**, as in a decision's own test
  ([`Decision_GWT.res`](../../reventless/gwt/src/Decision_GWT.res)): the role rule and the
  ownership rule are checked, and `thenForbidden` is a flow's expectation too.
- **`asCaller` before a view step**: the row is built as today, then the caller is asked for:
  refused for the whole view, not the row's owner, or the row retired all read as *no row*,
  which is what the platform answers.
- **One function for *may this caller read this row***, in the spec package beside
  [`OwnerScope.res`](../../reventless/spec/src/types/OwnerScope.res): the view's role rule
  ([`Authorization.res`](../../reventless/spec/src/types/Authorization.res)), the owner
  decision and the retirement decision, and the comparison of the row's field with the caller's
  id. The view step calls it. So do the read paths that compare by hand today and can call
  ReScript: the shared list evaluator
  ([`QueryDbListQuery.res`](../../reventless/core/src/components/Api/QueryDbListQuery.res)) and
  the local resolver
  ([`QueryDbResolvers_GraphQL.res`](../../reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res)).
  The AppSync resolver's generated source stays a mirror; its own tests hold it to the rule.
- **One caller for both**: the caller of a command step is mapped to the identity the read
  decision takes; the groups that read every row are given to the flow, since they are a
  setting of the deployment ([FSQ3](#4-open-questions)).
- **The same on a single view's test and a single query's test**
  ([`Projection_GWT.res`](../../reventless/gwt/src/Projection_GWT.res),
  [`Query_GWT.res`](../../reventless/gwt/src/Query_GWT.res)), so that a reading rule is first
  shown where the view is.
- A step with no caller behaves as today.

**Exit:** the ordering flow reads its order as the customer who placed it and gets no row as
another customer; the same two on the order view's own test; the local resolver's and the list
evaluator's tests unchanged and green on the shared function.

### FS9 What reacts reacts once, and nothing else does

- **First, a test of what happens today**: one reaction step called twice over the same record.
  The reading of the code says it reports the same commands twice unless a later event settled
  them. The step is built on what the test shows.
- **A flow remembers, per automation, what it has handled**; a reaction step reports what is
  new since that automation's last step.
- **`thenNothingElseReacts`**, given the flow modules of [FS2](#fs2-a-system-offers-its-steps-ready-made):
  runs every automation and extension of those systems the flow did not name over the record,
  and fails if one would send a command, naming it.
- **`whenSettled`**: runs reactions and the commands they send until nothing is sent, with a
  bound that fails the flow at a loop. For a flow that means *and then the app does the rest*.

**Exit:** a flow that names one of two automations reacting to the same event fails
`thenNothingElseReacts`; the two-system flow's fan-out run whole.

### FS10 A flow starts after another

- **`after(flow)` in place of `start`**: the record and the time of another flow, which must
  have passed. The steps file records the flow it starts after, by its id.
- The example files drop their typed-in *the product is already synced* for the flow that
  syncs it.

**Exit:** the ordering flow starting after the catalog's; a failing first flow reported once,
on itself, and the second as *not run*. **Release B.**

### FS11 A boundary's scope is checked without a test

- **The check of `thenBoundaryScopeResolves` runs for every system**, with no test written:
  as a test generated with the system's flow module ([FS2](#fs2-a-system-offers-its-steps-ready-made)),
  named for the system ([FSQ4](#4-open-questions)).
- `thenBoundaryScopeResolves` goes from the flow harness; the example files lose their four
  hand-written tests of it.

**Exit:** a system added to an example with a slice whose partition does not resolve fails its
generated test with no line written for it.

### FS12 The record keeps the id an event was recorded under

- **Every entry keeps its id**, DCB entries too: the id the platform would record it under.
- **The extension point step, the extension step and the way out step pass it on**; `gwt-id`
  and the empty source id go.

**Exit:** a way out whose `collect` keys on the source id, tested in a flow; the two-system
flow green with no synthetic id.

### FS13 The parts that have no step

Each on its own, when a flow needs it:

- **What a way out sends, and the answer.** `whenSent` on the way out step runs the real
  `translate` against the fakes that stand in for an outside service
  ([`Capabilities_Fake.res`](../../reventless/gwt/src/Capabilities_Fake.res)); the command the
  answer becomes is the step's sent command, for [FS4](#fs4-a-step-runs-what-was-just-sent).
- **A query.** `QueryStep` over a view: a filter, a count, a list, read as the caller of
  [FS8](#fs8-a-view-is-read-as-a-person).
- **A side effect.** A step that runs it over the record and states what it did.
- A scheduled task stays out: it is bound to infrastructure.

**Exit:** per step, one flow of an example that uses it. **Release C** closes with what is
built of this step.

---

## 4. Open questions

**FSQ1.** *Do the old step names keep working for a release?* **Recommendation:** no alias that
works. A module under the old name whose only content is a deprecation that names the new step,
removed one release later. A flow is test code; a clear compile error costs its author a
minute, and two names for one step cost every reader.

**FSQ2.** *Where are a system's ready-made steps generated?* **Answered while building
[FS2](#fs2-a-system-offers-its-steps-ready-made):** by `generate-plugin`, into the system's tests
folder as `tests/Flow.res`. The list of parts that gives `dcbSliceSchemas` is read by
`generate-plugin`, not by the PPX, which sees one file at a time. Written into `src`, the steps
would make every running bundle carry the test package and jest. The tests folder is in the
system's namespace and is not dev-only, so a platform reaches the steps as `OrderingPlugin.Flow`.
The file is written only where the tests folder exists and the system depends on the test
package.

**FSQ3.** *How does a flow know the groups that read every row?* **Recommendation:** a flow's
test takes them (`~elevated`), with none as the default; the ready-made caller for an operator
is exempt as it is for commands. Reading the deployment's setting would tie a test to an
environment.

**FSQ4.** *A generated scope test, or a refusal at build time?* **Recommendation:** the
generated test. Deploy and boot already refuse a boundary that fails; the gap is that nothing
says so earlier, and a test says it with the reasons, where an author looks.

**FSQ5.** *Does `thenAccepted` belong in core at all?* It exists for a tool that writes flows.
**Recommendation:** yes, small and marked. Without it such a tool either writes values nobody
confirmed, which then look confirmed, or writes nothing and proves no connection.

---

## 5. Verify

Per release: the gwt package under jest (no CLI runner lives in this repository any more), the PPX tests, the three example
shops built and their tests green, zero warnings. Release A and [FS6](#fs6-expectations-that-are-missing) change what the steps file
holds: its schema version moves, and whatever in this repository reads it is updated in the same step.
