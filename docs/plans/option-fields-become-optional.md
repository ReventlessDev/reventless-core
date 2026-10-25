# Plan: record fields typed `option` become optional fields

**Date:** 2026-10-25<br/>
**Status:** Filed, not started. Steps [R1](#r1-group-a-the-published-plugin-structure) to
[R5](#r5-group-e-internal-results-and-tool-records-case-by-case), one inventory group each, in that
order.<br/>
**Repos:** `reventless-core` only.<br/>
**Grounds:** [the inventory](../analysis/option-fields-that-could-be-optional.md), produced by
`pnpm run inventory:option-fields`: 245 fields in 133 record types, in six groups. Groups A to E
move here; group F stays `option`, for the reason the inventory gives.<br/>
**Tools:** [the inventory script](../../scripts/inventory-option-fields.mjs) says what is left, and
[the refactor script](../../scripts/refactor-option-fields.mjs) (`pnpm run refactor:option-fields
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
literal's `name: Some(expr)` becomes `name: expr`, a literal's `name: None` disappears, and in a
pattern (the text before `=>` on a line, or a line starting `|`) `name: Some(x)` and `name: None`
become `name: ?Some(x)` and `name: ?None`. The dry run lists every edit with its file and line.

What it cannot know, and the compiler refuses afterwards:

- **A field name another record shares.** `plugin`, `chapter`, `config`, `region` occur in records
  of several groups. Rewriting group A's `plugin` also rewrites a literal of `Semantic.memberTarget`,
  a group E record still typed `option`; the build refuses that hunk and it is reverted (or that
  record is moved early, when it is as simple).
- **A `Some(` whose closing paren is on a later line.** Left as it is; the build names it.
- **A value already of type `option`** passed as `name: value`. It needs `name: ?value`; the build
  names it.
- **A comment** that quotes a field, which the script skips, and so stays a comment about the old
  spelling until read.

So each step is: dry run, read the report, `--write`, build, fix or revert what the compiler names,
run the tests, re-emit the outputs, commit.

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

### R2: group B, command-line arguments

Thirteen records, 22 fields, about 75 edits in 21 files: the `args` records of the AWS scripts and
`PrepareAccounts`, and the `observed` record of `CliArgs`. Each is built by one parse function and
read by one `main`.

**Exit:** the inventory shows no `option` field in a `scripts/` directory or in `CliArgs`; each tool's
`--help` and one usage mistake still answer as its test says.

### R3: group C, bindings to JavaScript APIs

Ten records, one field each, in `rescript/aws-sdk`, `rescript/pulumi-aws` and `rescript/mcp-sdk`.
Declarations only; the script finds no literal to rewrite, because these records are read from the
library, never built here.

**Exit:** the inventory shows no `option` field under `rescript/`; the bindings packages build and
their tests pass.

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
- **The script's scope.** It rewrites by field name across the whole tree. Where the name is shared
  with a record that stays `option` the build refuses the hunk; the plan accepts that round trip
  rather than making the script know types.

## Honesty ledger

- **Measured:** the counts and edit numbers are the scripts' dry-run output on 2026-10-25; the wire
  identity is read off the compiled `Plugin.res.mjs`, where both spellings produce the same sury
  schema.
- **Judged, not measured:** the move-or-keep decisions of [R5](#r5-group-e-internal-results-and-tool-records-case-by-case) come from reading each record's use
  once; a step may overturn one when the code says otherwise, and should say so in its commit.
- **Not verified:** that every pattern edit the script proposes is a pattern; the dry run's
  classification is a heuristic on `=>` and `|`, which is why the report is read before `--write`.
