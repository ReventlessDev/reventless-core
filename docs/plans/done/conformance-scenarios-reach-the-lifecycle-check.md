# Plan: a conformance suite's scenarios count for the lifecycle check

**Status:** ✅ R1–R3 built 2026-10-19, released 2026-10-21 in `reventless-gwt` 1.0.0-alpha.252.
On the online shop's ordering plugin, the
notification conformance suite run with the switch on records its 19 scenarios, and
`check-lifecycle` then shows `RequestNotification` undeliverable (2 scenarios) and deferred (1)
beside its own.<br/>
**Touches:** `reventless/gwt` (`src/ScenarioRecorder.res`, new; `src/Behavior_GWT.res`), its tests,
and `docs/guides/reverse-codegen-pipeline.md`. `check-lifecycle` is unchanged.

## Goal

A behavior scenario that runs is a scenario `check-lifecycle` can read, wherever it was written.
In particular, the scenarios of a trait's conformance suite, which run against the host's own
slice, count for the host's lifecycle check like the host's own scenarios do.

## Why

`check-lifecycle` reads what a command does from the scenario sidecars (`*.gwt.json`) the PPX
writes at build time from each `_GWT.res` file. The PPX reads the file's source, so it can only
name what the source spells out: a literal constructor in a `givenEvents`, `whenCmd` or `then*`
call inside a top-level `describe`.

A trait's conformance suite is written once, against the trait's binding:

```rescript
G.test("a request for a recipient nobody announced is undeliverable", () =>
  G.givenEvents(B.Consumed.created)
  ->G.whenCmd(B.request(B.transactional, "ref-4"))
  ->G.thenEvent(B.undeliverable(B.transactional, "ref-4"))
)
```

`B.request(…)` is a value the host's binding builds, so nothing in this source names the host's
command. And the host's test file only binds and registers the suite
(`NotificationConformance_GWT.res`), so it has no `describe` of its own, and no sidecar is written
for it. The suite runs and passes, and `check-lifecycle` sees none of it: in the online shop's
ordering plugin, the two outcomes of `RequestNotification` the suite covers, undeliverable and
deferred, read as shown by no scenario.

What the source cannot say, the run can: inside `Behavior_GWT.Make`, every step receives real
values, and the spec's schemas name them (`Message.encode(…)->Message.variantNameOfJson`, as the
authorisation check already does for commands).

## Shape

**`ScenarioRecorder`**, a small module in `reventless-gwt`:

- **When.** Only with `REVENTLESS_EMIT_SIDECAR` set to `1` or `true` in the test process, the
  switch the PPX already reads at build time. Otherwise every call is a no-op and a test runs
  exactly as today.
- **What.** Per test, the title and, in order: the history the command was decided on (`given`),
  the command (`when`), and what the test expects (`then`): the expected events, the expected
  error, no event, or a refusal. Each entry is `{kind, element, values: []}`, the sidecar's
  shape; `values` stays empty, since a run has values but no names for them.
- **Where.** Beside the test file, as `<File>_GWT.gwt.json`, in the format the PPX writes, with
  `stem` set to the spec's name, which is what `check-lifecycle` takes a file's component from,
  and `recorded: true`. A file whose tests run several specs writes one sidecar per further spec,
  `<File>_GWT.<Spec>.gwt.json`.
- **Never over the PPX.** A test file that already has a sidecar the PPX wrote (no `recorded`
  flag) is left alone: its source-read sidecar carries values and ids the run cannot.
- **The test file.** Under Jest, the running test's path (`expect.getState().testPath`). An
  external runner registered through `RunnerHook` names the file it is running with
  `ScenarioRecorder.setFile`.

**`Behavior_GWT.Make`** wraps each test's body in the recorder and records from `whenCmd` and
the `then*` assertions. Nothing else in the module changes.

## Steps

| Step | What | Done when |
|---|---|---|
| **R1** | `ScenarioRecorder` and its use in `Behavior_GWT.Make` | a test running a suite written against a binding, with the switch on, writes a sidecar `check-lifecycle` reads, naming the host's command and events |
| **R2** | Tests: the switch off writes nothing; a PPX sidecar is not overwritten; two specs in one file write two sidecars; `readCorpus` reads a recorded sidecar as the spec's component | the gwt package's tests pass |
| **R3** | The guide says that recorded sidecars exist, that they need a test run with the switch on, and what they cannot carry | the reverse-codegen guide's sidecar section |

## Risks

- **A recorded sidecar is only as fresh as the last test run with the switch on**, not the last
  build. A lifecycle check run straight after a build without the tests sees the previous run's
  recording, or none.
- **No values.** The lifecycle check compares ids from a scenario's values in a few places; a
  recorded scenario names its command and outcomes only.
- **A failing test is recorded as written**, since its expectations are what it states; the run
  reports the failure as it does today.
