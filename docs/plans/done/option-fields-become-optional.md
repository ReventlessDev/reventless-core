# Plan: record fields typed `option` become optional fields

**Date:** 2026-10-25<br/>
**Status:** Done. [R1](#r1-group-a-the-published-plugin-structure) to
[R5](#r5-group-e-internal-results-and-tool-records-case-by-case) landed one commit each; group E
stands at its kept baseline of 18 records and 23 fields.<br/>
**Repos:** `reventless-core`; `reventless-tools` follows when it takes the new version (see
[Risks](#risks)).<br/>
**Grounds:** [the inventory](../../analysis/done/option-fields-that-could-be-optional.md), produced by
`pnpm run inventory:option-fields`: 245 fields in 133 record types, in six groups. Groups A to E
move here; group F stays `option`, for the reason the inventory gives.<br/>
**Tools:** [the inventory script](../../../scripts/inventory-option-fields.mjs) says what is left, and
[the refactor script](../../../scripts/refactor-option-fields.mjs) (`pnpm run refactor:option-fields
--group <A..E> [--only f.res,g.res] [--write]`) rewrites one group: the declarations exactly, and the
literal and pattern sites by field name. Both stay in `scripts/` for the next refactoring of this
kind.

## In plain words

A field written `name: option<T>` has to be written at every place a record is built, as `Some(x)`
or `None`; a field written `name?: T` may be left out, and reading it gives the same `option<T>`.
For a record sury serializes the two compile to the same schema, so nothing on the wire changes:
no event, no stored structure, no GraphQL type, no golden. What changes is the source: fewer
`: None,` lines, and a new field no longer forces an edit to every literal.

This plan moves every field the inventory marked as "absence means not given", one group per commit,
with a script doing the mechanical part and the compiler naming what the script got wrong.

## What the script does, and what it leaves to the compiler

For each field of the group's records it rewrites the declaration `name: option<T>` to `name?: T`
inside the declaring record, then every site in the tracked sources where the field is written: a
literal's `name: Some(expr)` becomes `name: expr`, also when the `Some(` closes on a later line; a
literal's `name: None` disappears, except in a record spread (`{...r, name: None}`), where it clears
the field and so becomes `name: ?None`; and in a pattern (the text before `=>` on a line, or a line
starting `|`) `name: Some(x)` and `name: None` become `name: ?Some(x)` and `name: ?None`. Text inside
a string literal is left alone. The dry run lists every edit with its file and line.

After `--write` and a first build, `--fix-build` rebuilds the root and prefixes `?` wherever the
compiler says an `option` value is passed to the now-optional field (`name: ?value`, punned
`?name`), until it names nothing more of that kind. In [R1](#r1-group-a-the-published-plugin-structure) that was 42 sites, each a separate
compiler stop.

What it cannot know, and the compiler refuses afterwards:

- **A field name another record shares.** `plugin`, `chapter`, `config`, `region` occur in records
  of several groups. Rewriting group A's `plugin` also rewrites a literal of `Semantic.memberTarget`,
  a group E record still typed `option`; the build refuses that hunk and it is reverted (or that
  record is moved early, when it is as simple).
- **A value already of type `option`** passed as `name: value`. It needs `name: ?value`; the build
  names it, and `--fix-build` answers it.
- **A value computed by a `switch`** that yields `None` or `Some(...)`: the field needs
  `name: ?switch ...`; the build names it and `--fix-build` does not, since the column points at an
  arm.
- **A record taken apart by punning**, `({manifest, stack}) =>` or `| Ok({summary}) =>`. On an
  optional field a bare pun binds the unwrapped value and matches only when the field is present,
  so it becomes `?manifest`. The build names it wherever the binding is then used as an `option`;
  a pun whose binding is used as the plain value would compile as a partial match, which the
  zero-warning build reports as a non-exhaustive pattern.
- **A field computed by a ternary or a `switch`** yielding `None` / `Some(...)`: it needs
  `name: ?(c ? Some(x) : None)` or `name: ?switch ...`.
- **An empty literal.** A record whose every field was `None` becomes `{}`, which needs its type:
  `ref(({}: context))`.
- **A punned function parameter** whose type is inferred from the first record it fills: the `?`
  goes on that first use, which is not where the compiler reports the mismatch.
- **A comment** that quotes a field, which the script skips, and so stays a comment about the old
  spelling until read.

So each step is: dry run, read the report, `--write`, `--fix-build`, fix or revert what it leaves,
format the touched files, run the full `pnpm run build`, the tests and the checks, commit.

## Rules every step keeps

- **One group, one commit**, with the compiled outputs the root build re-emits
  (`pnpm run check:fresh-outputs` after `pnpm run build`).
- **Nothing reaches the wire.** `pnpm run check:graphql` and `pnpm run check:dcb-scope` pass
  without `--update`; if either asks for an update, the step did something it should not have.
- **Group F is not touched**, nor any record the step's table below says to keep.
- **No new `option` field** is written while a step is open; the global rule for new fields holds.
- **The inventory is re-run at the end of each step** and its count is the step's exit.

## Steps

### R1: group A, the published plugin structure

The fifteen records of `Plugin.res`, 47 fields; about 390 edits in 35 files, of which 214 are
`: None,` lines in the ten structure literals of the tests and `Platform_Admin_Structure`. The
builder `Plugin_Structure` already writes `requiredRoles: ?rolesFor(...)`, which is the form every
other builder field takes after this step.

Watch for: the `chapter` field, shared by six of these records and nothing outside the group; the
`plugin` field, shared with `Semantic.memberTarget` (group E) and two deploy records (group D), whose
literals the build will refuse and the step reverts.

**Exit:** the inventory shows no `option` field in `Plugin.res`; the ten literals carry no `: None,`
line; the plugin-structure, baked-manifest and admin-API tests pass; the stored structure of a
running local platform decodes (start the hybrid local platform once).

**Done.** 27 files; the compiled `Plugin.res.mjs` is byte-identical, which is the wire claim
checked directly. What the build refused and was reverted: `Semantic.referenceTarget.plugin`
and `memberTarget.plugin`, `ResourceAttribution.context.plugin`, the handler entries' `plugin`
(group D), `Pairing.extensionPointDef.group`, `CheckLifecycleModel.declaredCommand` and
`declaredView` (`aggregateIdField`, `allowedStates`, `targetState`, `lifecycleField`),
`PgQueryResolver_Lambda.binding` (`ownerField`, `retiredField`, `retiredValues`) and the
`visibility` of `StateAnnotations.stateAnnotationSpec`. The hybrid local platform started on its
stored database with no decode warning. Three tests were red before this step and still are,
for a reason it does not touch (the admission fields): `AdminApiSchemaDriftTest`'s two "every
record field reaches the wire" and `PluginDefinitionRequiredScalarsTest`.

### R2: group B, command-line arguments

Thirteen records, 22 fields, about 75 edits in 21 files: the `args` records of the AWS scripts and
`PrepareAccounts`, and the `observed` record of `CliArgs`. Each is built by one parse function and
read by one `main`.

**Exit:** the inventory shows no `option` field in a `scripts/` directory or in `CliArgs`; each tool's
`--help` and one usage mistake still answer as its test says.

**Done.** 21 files. Reverted: the `region` of `Lambda.NotFound` / `CouldNotLook` and of
`Platform_ProvidedGroups`. By hand: the module-qualified labels the script then did not read
(`{Provision.providerId: None, ...}`, which it now writes as `?None` so the qualifier stays), and
three punned destructures in `ProvisionAdmin`, `BakeManifest` and `DeployApp`.

### R3: group C, bindings to JavaScript APIs

Ten records, one field each, in `rescript/aws-sdk`, `rescript/pulumi-aws` and `rescript/mcp-sdk`.
Declarations only; the script finds no literal to rewrite, because these records are read from the
library, never built here.

**Exit:** the inventory shows no `option` field under `rescript/`; the bindings packages build and
their tests pass.

**Done.** 22 declarations in eight files and nothing else: no site needed a change, and no
compiled output moved. The inventory had listed ten. Its field pattern let an attribute
(`@as("X")`) run across the lines after it, so a run of attributed fields counted as its last
one; it now reads an attribute as one token and records each field's line, and the refactor
script rewrites the declaration on that line rather than in the first record of that name (two
files declare `output` once per submodule). Groups A, B and D to F are unaffected by the fix.

### R4: group D, runtime and deploy configuration built in one place

37 records, 72 fields, about 185 edits in 54 files: the `handlerEntry`, `specInfo`, `*Config` and
`*Info` records the AWS deploy programs hand to the function entry points, and five framework
records (`Monitoring.announcement`, `ResourceAttribution.context`, `FTPHandler.connectionParams`,
`ScheduleTime.awsSchedule`, `RuntimeHints.t`, the generator's `runtimeHints`). Each is built by one
builder and read by one entry point; several are read off `process.env` JSON in the Lambda, where
an absent key is already what `None` was.

Do it in two commits if the diff is unwieldy: the `reventless/aws` records, then the five framework
records.

**Exit:** the inventory shows no `option` field in the listed files; the aws suite passes; a
`pulumi preview` of the hybrid AWS platform shows no diff (the entry-point configuration is
serialized into the function environment, and the serialization of an absent field is unchanged).

**Done.** 74 fields in 39 records, in one commit. Reverted: `Semantic.referenceTarget.plugin`
and `memberTarget.plugin`, a test's own `call` record, and `Plugin_Helpers.eventCollectorContext`'s
`connectExtension`, all sharing a name with a moving field. The `pulumi preview` was not run: it
needs the AWS account, and a preview of this platform submits a CloudFront invalidation. The
claim it was to check holds by construction instead: every `HANDLER_CONFIG` is written field by
field (a template string or an explicit JSON encoder), and a literal that drops `name: None` drops
a key whose value was `undefined`, which `JSON.stringify` omits either way.

The inventory had a second blind spot, found here: in a one-line record (`{a: string, b:
option<T>}`) it read only the first field. It now reads a field after a comma as well. That
surfaced three more fields in group B (`BakeManifest.written`, `ProvisionAdmin.request`) and two
in group D (`AppSyncEventsSigner_Ops.creds`, `AppSync_Adapter.getSchemaCreationStatusResult`), moved
in this commit, and took group E from 73 fields to 90 and group F from 21 to 22.

### R5: group E, internal results and tool records, case by case

42 records, 73 fields, about 410 edits in 111 files, the largest step because its records are
built in many places (the plugins read model, the seed, the generator). Not all of them move. The
rule is the inventory's: absence as "not given" moves, a `None` the logic decides on stays.

| Record | Decision | Why |
|---|---|---|
| `PluginsReadModelSpec.state` and `queryResult` | move | optional parts of a stored row; absence is "the plugin has none" |
| `Platform_Admin.outputs`, `Dcb_Builder.dcbResult`, `Plugin_Helpers.builderOutputs` and `eventCollectorContext` | move | builder outputs a platform may or may not have |
| `Platform_BakedManifest.selection` | move | an absent selection is "all" by default, already read with `getOr` |
| `GraphQL_SchemaInspector.queryFieldInspection`, `GraphQL_ServerInstance.diagnostics` | move | diagnostics that may be absent |
| `Projection.overlays` | move | an overlay a spec may not declare |
| `Auth_ActiveRole.conformanceCase` | move | a test table; absent request and expectation are "not in this case" |
| `InboundTranslationResolvers_GraphQL.pendingCall` | move | a caller a queued call may not carry |
| `LocalPlatformRegistry.store` | move | a path the registry may not know |
| `Seed_Connect.connection`, `Seed_Users.user`, `AccountsManifest.fill`, `DeploymentProvenance.t` | move | records read from files where the key is absent or present |
| `Discovery.discoveredFile`, `Pairing.extensionPointDef`, `PlatformCodegen.provenance`, `CheckLifecycleModel.declaredCommand` | move | generator records mirroring optional parts of a declaration |
| `Semantic.memberTarget` and `storeTarget` | move | a qualifier a declaration may omit; also unblocks the `plugin` collision of [R1](#r1-group-a-the-published-plugin-structure) |
| `StateAnnotations.stateAnnotationSpec` | move | annotations a spec may or may not carry |
| `Geocoding.candidate` | move | a provider may not score |
| `DcbScopeInference.sliceShape.partitionHint` | keep | `None` is "infer it", a branch the inference takes |
| `StateAnnotations.retiredSpec.values`, `OwnerScope.retiredScope.values` | keep | `None` means "the boolean form", a branch the predicate takes |
| `SortKey_Filter.result.nextToken`, `EventLogChangeFeed.batch.cursor`, `PgChangeFeed.batch.cursor` | keep | `None` is "no more pages", the loop's stop |
| `EventLogChangeFeed.classicEvent.msgId` | keep | an id the feed decides to mint when absent |
| `PluginDecision.state.current` | keep | decision state: no version yet is a state `decide` switches on |
| `AutomationSlice_Route.routed.resolved` | keep | `None` is "unroutable", a branch |
| `CommandTopic.operations` and `CommandTopic_Builder.operations` (`publishJsonsAndWait`) | keep | presence is a capability the caller switches on |
| `Api.querySchemaEntry.authorization` | keep | `None` is "the default rule", decided at the door |
| `ReventlessSeedAws_Quiesce.held.priorReserved` | keep | `None` is "nothing to restore", a branch |
| `Template.scope.value` | keep | `None` is a scope with no value, which the renderer treats as a case |

Run the script with `--only` for the moving records' files, so the kept ones are not rewritten; the
inventory's group E count afterwards is the kept rows' field count, and that number becomes the
inventory's new baseline for the group.

**Exit:** the inventory's group E lists exactly the kept records above; the spec, core, local and
seed suites pass.

**Done.** 36 records, 67 fields. The table held, with two overturned and twelve added:

- **Overturned: `StateAnnotations.stateAnnotationSpec` stays `option`.** The `@@reventless.spec`
  PPX writes its literals, with `name: None`, into every annotated spec file. Moving it means
  changing the PPX and republishing it in lockstep, since an app outside this repository runs the
  published binary; a source-only tidy-up does not justify that.
- **Also kept, not in the table:** `Plugin.pluginDefinition`'s `apiSchemaFragment` and
  `structure`. Their schema is an explicit `Offload.optionSchema` written on the type, which wraps
  the option itself; an optional field would change it. The inventory does not count them, because
  the attribute sits after the colon.
- **Added and moved,** by the rule above: the example views' `Orders`, `NotificationDeliveries` and
  `RegistrationWindows` states, the local backends' `relayLogEntry`, `Platform_ProvidedGroups.pool`,
  `Pairing.aggregateDef`, `Util_Promise.result` (a binding for `Promise.allSettled`),
  `EmitCapabilities.args`, `CheckLifecycleModel.declaredView`, `Semantic.referenceTarget` and
  `storeTarget.threshold`, `ShellEnvironment.t`.
- **Added and kept:** the GWT harness rows (`Automation_GWT.sourced`, `Query_GWT.row`), as group F
  keeps its harnesses; `Seed_Client.t.token`, mutable sign-in state the client acts on; and
  `Template.scope.schema`, beside the kept `value`.

Shared names cost the most here. `expected` belongs to GWT's mismatch records too, `displayName`
to fixture states, `deliveryWindow` and `firstProductName` to the `OrderPlaced` event that feeds the
`Orders` view, and `apiSchemaFragment`, `structure` and `kind` to `pluginDefinition`; the build named
each, and those hunks went back. A pass that put `?` on every pun of a moved field's name was tried
and withdrawn: a bare pun on a field that was already optional means "present" in a `switch` arm,
and `?` would have changed which arm matches without a compile error. Puns were fixed where the
compiler named them, which it does for every one that matters: a bare pun on a now-optional field
is either a type mismatch or a non-exhaustive match, and both stop the build.

[R4](#r4-group-d-runtime-and-deploy-configuration-built-in-one-place) left one site behind, found here: the plugin generator wrote `RuntimeHints` literals as
`memorySize: Some(2048), timeout: None`. The refactor rewrote the generated `Plugin.res` files but
not the generator, so `pnpm run check:traits`, which regenerates them, failed. The generator now
writes only the hints an entry gives, regenerating is byte-identical, and the fix was folded into
the [R4](#r4-group-d-runtime-and-deploy-configuration-built-in-one-place) commit.

## Acceptance

- `pnpm run inventory:option-fields` shows groups A to D empty and group E at its kept baseline.
- The full root build is warning-free, `check:fresh-outputs` passes after it, and `check:graphql`,
  `check:dcb-scope` and `check:lifecycle` pass without updates.
- Every test project passes, and the hybrid local platform starts and serves its stored plugin
  structures.
- The inventory analysis is moved to its "done" state in the same final commit, with the kept
  baseline recorded.

## Risks

- **Silent meaning change in a pattern.** A pattern `{name: Some(x)}` rewritten by mistake as a
  literal, `{name: x}`, would match every record and bind `x` as an `option`. The build catches the
  cases where `x` is then used as a `T`; a pattern that only tests presence and discards `x` would
  not be caught. The dry run's report marks every pattern edit, and [R1](#r1-group-a-the-published-plugin-structure) to [R5](#r5-group-e-internal-results-and-tool-records-case-by-case) read that list before
  `--write`.
- **The structure's old readers.** A deployed plugin's structure decodes with the new record type
  unchanged, since the schema is unchanged; verified by starting the local platform against the
  stored structures in [R1](#r1-group-a-the-published-plugin-structure).
- **A spread's `None` is a value.** `{...r, name: None}` clears a field the base record may have
  set; deleting the line keeps the base's value and still compiles whenever another field remains.
  [R1](#r1-group-a-the-published-plugin-structure) met sixteen of these in the tests, found after the fact; the script now writes them as
  `name: ?None`.
- **Other repositories build these records.** `reventless-tools` builds `Plugin.res` records in
  about ten files (`dev/`, `codegen/`, mostly tests). A `name: None` or `name: Some(x)` there stops
  compiling against the next published `reventless-spec`, which makes each step a source-breaking
  change for that repository even though the wire is unchanged. Each step's commit says so, and
  the consuming repository moves when it takes the new version.
- **The script's scope.** It rewrites by field name across the whole tree. Where the name is shared
  with a record that stays `option` the build refuses the hunk; the plan accepts that round trip
  rather than making the script know types.

## Outcome

`pnpm run inventory:option-fields` shows groups A to D empty and group E at 18 records, 23 fields.
The full root build is warning-free, `check:graphql`, `check:dcb-scope` and `check:lifecycle` pass
without updates, `check:traits` passes, every test project passes, and the hybrid local platform
starts on its stored database and serves its plugin structures. The one test that failed in a
full run, `UserStore.reload watch`, is a file-watch timing test the change does not touch; it
passes alone.

The inventory's counts at filing were low. Its field pattern let an attribute run across the
lines after it, so a run of `@as`-attributed fields counted as one, and it read only the first field
of a one-line record. Both are fixed; the tables in
[the inventory](../../analysis/done/option-fields-that-could-be-optional.md) are as filed.

## Honesty ledger

- **Measured:** the counts and edit numbers are the scripts' dry-run output on 2026-10-25; the wire
  identity is read off the compiled `Plugin.res.mjs`, where both spellings produce the same sury
  schema.
- **Judged, not measured:** the move-or-keep decisions of [R5](#r5-group-e-internal-results-and-tool-records-case-by-case) come from reading each record's use
  once; a step may overturn one when the code says otherwise, and should say so in its commit.
- **Not verified:** that every pattern edit the script proposes is a pattern; the dry run's
  classification is a heuristic on `=>` and `|`, which is why the report is read before `--write`.
