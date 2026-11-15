# Plan: the format is the type

**Date:** 2026-11-15<br/>
**Status:** ✅ [TF1](#tf1-closed-sets-held-as-variants-no-format-change) to [TF5](#tf5-the-few-as-left-on-owned-formats) built, 2026-11-15. [TF3](#tf3-the-sidecars-step-kinds-take-their-constructor-names) and [TF4](#tf4-the-repositorys-own-reports-and-structures-derived) change words
other readers see; they reach those readers with the release that carries them, the PPX and
`reventless/spec` together.<br/>
**Nature:** types and readers, no new behaviour. [TF1](#tf1-closed-sets-held-as-variants-no-format-change)
and [TF2](#tf2-the-lifecycle-check-reads-the-sidecar-into-variants) leave every file and every
wire word as it is. [TF3](#tf3-the-sidecars-step-kinds-take-their-constructor-names) and
[TF4](#tf4-the-repositorys-own-reports-and-structures-derived) change formats this repository owns,
writer and reader in the same release.<br/>
**Touches:** `reventless/spec` (the lifecycle check, `ComponentKind`, `CapabilityNeed`,
`Admission`, the plugin structure), `reventless/core` (`ComponentType`, `ResourceAttribution`),
`packages/reventless-ppx` (the sidecar's step words), `reventless/gwt`, `reventless/local`,
`reventless/infra`, `reventless/aws`, `traits/*`.

## In plain words

A closed set of words, such as a scenario step's kind or a finding's severity, is held in many
places here as a `string`. Readers compare it with `== "event"`, and each set has a `toString`
and an `ofString` written by hand, each listing the words again. A typo or a new word is found
only at run time, and a `switch` on a string can't tell when a case is missing.

The rule this plan applies:

- **A format this repository owns:** the type is the format. `@schema` derives it, and
  constructors and fields go on the wire by their own names. Nothing is written by hand, and
  there is no `@as` to keep a lower-case word. The packages are in alpha, so an owned format
  changes outright, writer and reader in one release.
- **A format someone else fixes** (AWS, DynamoDB, Postgres, HTTP, GraphQL, ICU message syntax,
  Jest's report, a JS API): a variant whose `@as` carries that exact text, converted at the edge.
  A field named by a keyword (`end`, `with`) keeps its `@as`.
- **Data a deployed app has stored** (event payloads, view rows, snapshots): left as written.
  Renaming it would change data already in a store.
- **A closed set held inside the code:** a regular variant, never a string, never a polymorphic
  variant. It is converted to text only at the edge that fixes the text.

## 1. What there is

An audit on 2026-11-15 found two things.

**`@as` annotations are almost all needed.** About 1000 lines carry `@as`, and some 95% name
someone else's text: the AWS SDK and Pulumi bindings (about 800 lines), AWS payload types in
`reventless/aws` (about 90), and the event names in node bindings (about 25). `reventless/core` and
`reventless/gwt` have none. The few on formats this repository owns:

| Where | Words | Verdict |
|---|---|---|
| `spec/src/components/InboundTranslationSlice.res` `webhookMethod` | `POST`, `PUT` | HTTP fixes them: keep ([TFQ4](#open-questions)) |
| `aws/scripts/DeployManifest.res` | `stack-defaults`, `depends-on` | kebab-case keys of a file people write: [TFQ3](#open-questions) |
| `spec/src/generator/Config.res` | `with` | a keyword: keep |
| `local/tests/adapter/GraphQL_SchemaInspectorTest.res` `sourceKind` | `tagged`, `ancestry`, `substrate` | a test's own type: drop the `@as` |

**Closed sets held as strings are the larger part.**

| Where | Shape | Size |
|---|---|---|
| `spec/src/lifecycle/CheckLifecycleModel.res` | `whenKind`, `thenKind` (the sidecar's step kinds), `shownOutcome.kind` (`event`, `error`, `noEvent`, named only in a comment), `finding.severity` (five words, named only in a comment), `declaredCommand.level` and `scenario.level` (`Collection`, `Instance` or `""`, built into `Reventless.Plugin.${level}` as text). About 25 comparisons and switch arms | large |
| `core/src/ComponentType.res` | `toString` and `ofString` of 27 arms each, and a second `toString` that writes `QueryDb` where the first writes `QueryDB` | medium |
| `spec/src/components/ComponentKind.res`, `spec/src/semantic/CapabilityNeed.res`, `spec/src/types/Admission.res` (`doorOfName`, and `def.strategy: string`) | `toString` and `ofString` pairs written by hand | medium |
| `ResourceAttribution`, `Visibility`, `ReadConsistency`, `Trait`, `Platform.viewModeToString`, `Plugin_Structure.labelFieldSourceToString`, `OutboundTranslation_GWT.statusToString`, `Platform_ComponentDefinitionsApi` | a small `toString` written by hand each | small |
| `Plugin_BuiltHook.typeSchema.kind`, `Plugin.visibility`, `LocalPlatformRegistry.store.kind`, `BakeManifest.registration.state`, `MismatchRender.normalized.kind`, `Catalogue.element.kind`, `ScenarioRecorder.entry.kind` | a `string` field that only holds a fixed set | medium |
| `LocalFeed.res`, `LocalPlatformObserve.res` | two parsers of log levels, one lower case and one upper case | small |
| `MessageFormat.Typed.kind` | ICU's words (`plural`, `select`, …), compared 8 times | small: a variant with `@as` |
| `traits/attachments`, `traits/notification`, `OutboundTranslation_GWT`, `AnsiStyle`, `AppLog`, `DcbEventLogStorage_Postgres_Ops`, the `PluginExtensionPoint_*` files | about 10 polymorphic variants | small |

Left alone: words someone else fixes (AWS status words, HTTP methods in the local servers, GraphQL
field names, content types by file extension) and `DateRange`'s `end`, which is both a keyword and
stored in event payloads.

## 2. Phases

### TF1 Closed sets held as variants, no format change

Every closed set in the second table becomes a regular variant, where it is still a string or a
polymorphic variant. Every file and wire word stays as it is today.

- A set that has a `toString`/`ofString` pair gets one list of its constructors, and both
  directions are derived from it. While the text is still the old text, a word that differs from
  its constructor's name keeps an `@as`. [TF4](#tf4-the-repositorys-own-reports-and-structures-derived)
  removes those.
- `ComponentType`'s two spellings of `QueryDB` are made one. Where each is read is found first,
  because a folder or file name may hold one of them ([TFQ5](#open-questions)).
- The two log-level parsers become one `logLevel` variant.
- `MessageFormat`'s kinds become a variant with ICU's words as `@as`.
- The polymorphic variants become regular variants with distinct constructor names.
- A field that must still read a word written by a newer build (`Admission.def.strategy` says so
  in its doc comment) becomes an `@unboxed` variant with an `Other…(string)` case. It keeps the
  word it does not know and writes it back unchanged ([TFQ2](#open-questions)).

Tests: each changed set reads and prints back its words unchanged, an unknown word included where
there is an `Other` case.

**Built.** Every set in the second table of [§1](#1-what-there-is) is a regular variant. Where a set
has text, the text comes from the case: `(case :> string)`, with an `@as` where today's word differs
from the case's name, and the reverse reads against one list of the cases. No file, structure, tag
or printed word changed. In detail:

- `ComponentType`'s `toString` and `ofString` are derived from one list. The case `QueryDb` keeps
  its name and carries `@as("QueryDB")`, the word it is deployed as. `toName` keeps `QueryDb`; see [TFQ5](#open-questions).
- `ComponentKind` carries its folder names as `@as` on the six slice cases, so `folderName` is
  derived. The accepting `folderToKind` stays as it was. A side effect: those six cases now hold the
  folder word at run time.
- `CapabilityNeed`, `Admission`'s doors, `Visibility`, `ReadConsistency`, `Trait`'s posture,
  `ResourceAttribution`'s scope and role, `labelFieldSource`, the definitions API's level and
  `Logger.level` are derived the same way.
- Fields that read a word a newer build may write are `@unboxed` with a case that keeps the word:
  `Admission.def.strategy` (`OtherStrategy`), the structure's `visibility` (`Visibility.t` gained
  `OtherVisibility`), and the local registry's `store.kind` (`OtherStore`), because the registry
  deletes an entry it cannot decode.
- The other string fields of the table hold variants: `typeSchema.kind`, the bake answer's state
  (the writer's and the script's states are one list, `BakeRegistrationState`; the script keeps a
  word it does not know), `MismatchRender.normalized.kind` (a new `Outcome.mismatchKind`),
  `Catalogue.element.kind` (with a case for each key part, and one that keeps an unknown text), and
  `ScenarioRecorder.entry.kind` (the sidecar's step kind of
  [TF2](#tf2-the-lifecycle-check-reads-the-sidecar-into-variants)).
- Both log-level parsers read through `Logger`: `levelOfLabel` for the API's upper-case enum,
  `levelOfWord` for a feed filter in any case, `warning` included.
- `MessageFormat`'s argument types are one variant with ICU's words as `@as`.
- The polymorphic variants are regular variants: the to-do status of the outbound GWT helpers, the
  log format, `AppLog`'s level, the Postgres lock strategy, the plugin connect/disconnect hook and
  the two traits' refusals. Their callers changed with them: the examples' GWT files and deciders,
  the traits' scaffold text, the conformance suite and two doc pages.

Left as it was: `Platform.viewModeToString`. Its cases carry options, so the word cannot be the case
itself; it stays the one switch that prints it. The words `Logger` reads from `LOG_LEVEL` were not in
the table and keep their own switch.

One reader outside this repository reads a field whose type changed: a test formatter that prints
`MismatchRender.normalized.kind` as a string. It has to print `(kind :> string)` now.

### TF2 The lifecycle check reads the sidecar into variants

`CheckLifecycleModel` reads the sidecar's step kinds once, at the edge, into a step-kind variant,
and switches on that variant from there on. `shownOutcome.kind`, `finding.severity` and the two
`level` fields become variants too. `level` reuses `Plugin.level` (`Collection | Instance`) as an
optional field, not `""`. The `Reventless.Plugin.${level}` text is printed from the variant.

The sidecar's words don't change in this phase, and neither does the check's report.

**Built.** `SidecarStepKind` (in `reventless/spec/src/lifecycle`) lists every step kind the PPX writes,
with today's words as `@as`, and an `OtherSidecarStep` case that keeps a word this build does not
know. The check reads a step's kind once, where it reads the sidecar, and switches on it from there;
a scenario's `whenKind` and `thenKind` are optional fields, absent where the step names none.
`ScenarioRecorder` writes through the same variant. `shownOutcome.kind` and `finding.severity` are
variants whose words are the report's, and `severities` is the order a run prints them in.
`declaredCommand.level` and the derived level are `level?: Plugin.commandLevel`; the golden and the
report print an absent level as `""`, as before. One reading narrowed: a published level that is
neither `Collection` nor `Instance` is now read as absent rather than kept as a word. The structure's
level is a sury-encoded `commandLevel`, so no structure holds such a word.

### TF3 The sidecar's step kinds take their constructor names

The PPX writes each step kind by the step-kind variant's constructor name (`Event`, `NoEvent`,
`SideEffect`, `NotUnderstood`, …), and `@schema` derives the reader. No `@as` is left on the
step kind. The OCaml writer and the ReScript reader share one list of names, so a word added to
one is found missing in the other by a test.

A sidecar is a build output, written again by every build, so no stored copy has to be converted.
Snapshots and goldens that hold sidecar text are written again. The PPX and `reventless/spec` are
released together, and readers of the sidecar outside this repository change in that same release
([TFQ1](#open-questions)).

**Built.** The PPX holds the step kinds as a variant of its own, `StepKind` (in
`packages/reventless-ppx/src/ppx`), and writes every `kind` and every `of` through its `word`,
which spells each case by its name: `Event`, `Command`, `Input`, `Error`, `SideEffect`, `State`,
`NoEvent`, `NoState`, `Forbidden`, `NoCommand`, `Todo`, `NoTodo`, `Capabilities`, `Sweep`,
`Process`, `Exhausted`, `Resolved`, `NotUnderstood`, `InputRefused`, `Sent`, `NothingSent`,
`TodoStatus`, `Retries`, `PublicEvent` and `Opaque`. `SidecarStepKind` dropped its `@as`s: it is
still `@unboxed` with `OtherSidecarStep(string)`, so a word reads as its case by identity, and it
gained `known`, the list of its cases. `ScenarioRecorder` writes through the same variant, so a
recorded sidecar carries the same words.

- One list: `SidecarStepKindTest` reads the arms of `StepKind.word` from the OCaml source and fails
  when an arm writes a word other than its constructor's name, when a word the PPX writes is not a
  case of `SidecarStepKind`, or when `known` and the PPX's list differ. It runs with the rest of the
  tests and needs no PPX binary.
- A word this build does not know now stops the lifecycle check for that plugin: it is reported
  under "could not read", naming the sidecar. A lower-case word says the sidecar was written by an
  older reventless-ppx and names the package to update; any other unknown word says the PPX is
  newer than `reventless/spec`. Before, such steps were dropped without a word and the model was
  derived from what was left.
- Changed with it: the PPX's unit tests and fixture suite, the lifecycle check's tests, the step
  kinds in [the reverse codegen pipeline guide](../guides/reverse-codegen-pipeline.md), and the
  comments that named the old words. No tracked file holds sidecar text: the sidecars are build
  outputs, and the lifecycle goldens and `LifecycleModel.res` files did not move.

### TF4 The repository's own reports and structures, derived

The formats this repository owns and writes for others to read take their type's names:

- the lifecycle check's report (`severity` and the outcome kinds)
- `typeSchema.kind`
- `visibility`
- the local registry's `store.kind`
- the bake manifest's registration `state`
- `ComponentType`'s and `CapabilityNeed`'s text

Each is derived with `@schema`, and the `@as` that [TF1](#tf1-closed-sets-held-as-variants-no-format-change)
kept for an old word goes. Before each format changes, its writers and readers are listed, and a
format a deployed app has stored (a baked manifest, a plugin structure inside a deployment) is
named and handled. Either it is written again on the next deploy, or it keeps its words with
`@as`.

**Built.** Each candidate's writers and readers were listed first. Three formats are written again
by every run and read only by code released with their writer, so their words are now their cases'
names, with no `@as`:

- The lifecycle check's `--json` report. A finding's `verdict` is `Contradicted`, `Unverified`,
  `Undeclared`, `LevelMismatch` or `Ambiguous`, and an outcome's `kind` is `EventOutcome`,
  `ErrorOutcome` or `NoEventOutcome`. The report's `version` is 2. The printed headings use the same
  words.
- `typeSchema.kind` (`RecordSchema`, `VariantSchema`, `UnknownSchema`), which travels only through
  the in-process plugin hooks.
- The bake function's registration `state` (`Registered`, `Unchanged`, `Matched`, `Missing`,
  `Behind`, `Diverged`). It is an answer the deploy script reads in the same run, never stored, and
  the script still keeps a word it does not know.

One more owned word went the same way: the to-do status a GWT mismatch prints (`Completed`, not
`#Completed`).

Kept, each with its `@as` or its words as they are:

- `ComponentType`: Pulumi type tokens, the `reventless:kind` tag and `runtimeKind`, all stored by a
  deployment. `QueryDb` keeps `@as("QueryDB")`.
- `ResourceAttribution`'s scope: AWS tags on deployed resources.
- The plugin structure's `visibility` and `labelFieldSource`, and `Admission`'s doors: the structure
  is stored in the Plugin read model and read back by a deployed platform.
- The local registry's `store.kind`: a file under `.reventless/running` that local tools of
  different versions read.
- `CapabilityNeed`, `Admission`'s strategies and `ReadConsistency`: already their cases' names,
  and stored in the structure or in a committed `capabilities.json`.
- `ComponentKind`'s folder names, `Logger`'s level words and the log format words: people write them,
  as folder names, `LOG_LEVEL` values and command-line flags.
- `Outcome.mismatchKind`: its words are the mismatch constructors' names, and the formatter's JSON
  carries them to an editor extension released on its own. The cases carry `Kind` only to stay
  distinct from those constructors.
- `MessageFormat`'s argument types: ICU's words.

The `Other` cases [TF1](#tf1-closed-sets-held-as-variants-no-format-change) added stay.

### TF5 The few `@as` left on owned formats

The test's `sourceKind` drops its `@as`. The deploy manifest's keys follow
[TFQ3](#open-questions), and the webhook method follows [TFQ4](#open-questions).

**Built.** `GraphQL_SchemaInspectorTest`'s `sourceKind` has no `@as`; none of its expectations read
the words. The deploy manifest's `stack-defaults` and `depends-on` and the webhook's `POST` and `PUT`
keep their `@as`, as [TFQ3](#open-questions) and [TFQ4](#open-questions) decided.

## Open questions

**TFQ1.** *Do the sidecar's step words change, or does a variant read today's lower-case words
with `@as`?* The words are written by the PPX and read by the lifecycle check and by tools
outside this repository. **Recommendation:** change them, in
[TF3](#tf3-the-sidecars-step-kinds-take-their-constructor-names). The sidecar is rebuilt on every
build, so no data has to be converted, and with the change a step kind's name is the same
everywhere. The cost is one coordinated release of the PPX and `reventless/spec`. After it, a
project still on the old PPX writes words the new reader doesn't know, so the reader's `Other`
case has to name the PPX version to update to.

**Decided (2026-11-15):** changed, as recommended, in
[TF3](#tf3-the-sidecars-step-kinds-take-their-constructor-names). The `Other` case's reason names
the package to update rather than a version: the matching version is the one released with the
reader.

**TFQ2.** *Does a structure field keep `string` so an older reader decodes a newer structure?*
`Admission.def.strategy` does so on purpose. **Recommendation:** an `@unboxed` variant with an
`OtherStrategy(string)` case. It decodes any word, keeps the one it doesn't know, and every reader
still switches on a variant. The tolerance stays, and the strings go.

**TFQ3.** *Do the deploy manifest's kebab-case keys (`stack-defaults`, `depends-on`) become
camelCase so the type can name them?* **Recommendation:** keep them with `@as`. People write this
file by hand, and kebab-case is the convention of the YAML it sits beside. The type is still the
format; only these two keys are spelled for the file.

**Decided (2026-11-15):** kept with `@as`, as recommended.

**TFQ4.** *Does `webhookMethod` write `Post`/`Put`?* **Recommendation:** no. The word is an HTTP
method, which HTTP fixes in upper case, so `@as("POST")` stays.

**Decided (2026-11-15):** `@as("POST")` and `@as("PUT")` stay, as recommended.

**TFQ5.** *Which spelling does `ComponentType`'s `QueryDb` keep?* One `toString` writes `QueryDB`
and another `QueryDb`. **Recommendation:** find where each spelling is read at the start of
[TF1](#tf1-closed-sets-held-as-variants-no-format-change). Then name the constructor by the
spelling that is stored or used as a folder name (`QueryDB` is a valid constructor name), so the
text and the name are the same and both functions are derived.

**Answer (2026-11-15):** both spellings are stored, so both stay. `toString`'s `QueryDB` is the
component's Pulumi type token, the `reventless:kind` tag on its resources and the `runtimeKind` a
Lambda's environment carries, which `ofString` reads back at cold start. Readers outside this
repository accept both `QueryDB` and `QueryDb` there. `toName`'s `QueryDb` is the suffix of every
physical resource name the query store makes (`ProductsQueryDb`) and of the local platform's bus
keys. `toName` is a second set of words, the short names (`Aggr`, `CmdGen`, …), not a second
spelling of the kind. The case keeps its name `QueryDb` and carries `@as("QueryDB")`, so `toString` and
`ofString` are derived and no stored word changed; `toName` keeps its own switch. The role tag's `QueryDb`
(`ResourceAttribution.Role`) is a third word, also stored, and unchanged.
