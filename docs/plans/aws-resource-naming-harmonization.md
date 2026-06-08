# Plan: AWS Resource Naming Harmonization

Implements the proposal in [docs/analysis/aws-resource-naming-harmonization.md](../analysis/aws-resource-naming-harmonization.md). Goal: collapse the three coexisting naming patterns into one scheme — `<Scope><Stem><Kind>[<Variant>]` — with one canonical `<Kind>` suffix per AWS resource type, sourced from a single place (`ComponentType.toName`) plus a small fixed vocabulary, and delete every hand-rolled suffix string.

## Status

- **Phase 1 (the original §2 inventory — aggregate/DCB command-handler lineage)**: ✅ shipped in commit `8f4aadaf5`, **cold-cutover deploy successful** on `alpha`. Build clean, 967 tests green. One item deliberately deferred (Step 6, UI Lambdas — Resolver collision).
- **Phase 2 (analysis §8 follow-up families — Task buckets, ExtensionPoint, Scheduler, Cloner)**: ✅ code done (P2-1 Task buckets/SideEffectHandler, P2-2 ExtensionPoint `CmdHandler`); P2-3 Scheduler / P2-4 Cloner intentionally left as-is; P2-5 Heartbeat/Counter verified clean. Build clean, 967 tests green (TaskTest assertion updated), AWS hybrid example builds. **Cold-cutover deploy pending** (user-initiated). See Phase 2 section.

## Decisions (resolved from analysis §7 — override before starting if wrong)

1. **Casing:** `QueryDB` → `QueryDb`. camelCase everywhere; no uppercase abbreviations.
2. **Single-strategy Lambda:** Single bundles *all* aggregates platform-wide into one Lambda (verified: `AggregateRuntime_Builder_Single.res` reduces over every registered aggregate — no plugin scope), so `<Plugin>CmdHandler` was wrong. Target: `AllAggregatesCmdHandler` (keep the honest platform-wide stem, append the canonical `CmdHandler` kind). Async variant: `AllAggregatesAsyncCmdHandler`. The scan policy `AllAggregatesPluginRmScan` → `AllAggregatesCmdHandlerPluginRmScan`.
3. **Future sliced-DCB form:** reserve `<Plugin><SliceStem>CmdHandler` (not built now; documented so it doesn't drift later).
4. **EventLogSub family:** Lambda becomes `EventLogSubscriber`; the SQS queue / IAM role / policy / ESM keep `EventLogSub` as the *family prefix* (`EventLogSubQueue`, `EventLogSubRole`, `EventLogSubPolicy`, `EventLogSubEventSourceMapping`).
5. **Migration:** **cold-cutover** on `alpha` — wipe stacks, redeploy with new names. Aligned with the `alpha-wipe-over-migration` memory and analysis §6 option 1. No `pulumi state mv`, no aliases (those are for production, which alpha is not).

## Canonical kind vocabulary (the target)

Root terms: `Aggr`, `Cmd`, `Event` (never `Evt`), `Slice` (never `Slc`). Established compounds kept: `CmdGen`, `EventColl`. Everything else spelled out.

| AWS resource | Current (mixed) | Target `<Kind>` |
|---|---|---|
| DynamoDB event log (aggregate) | `EventLog` | `EventLog` ✓ |
| DynamoDB event log (DCB) | `DcbEventLog` | `EventLog` (`Dcb` lives in the Stem) |
| DynamoDB query store | `QueryDB` | `QueryDb` |
| SQS command queue | `CmdTopic` | `CmdTopic` ✓ |
| SQS event collector | `EventColl` | `EventColl` ✓ |
| SQS subscription buffer | `EventLogSubQueue` | `EventLogSubQueue` ✓ |
| SNS event topic | `EventTopic` | `EventTopic` ✓ |
| Lambda — command handler | `CmdTopic` / `StateChangesCmdTopic` / `AllAggregates` / `<Agg>Aggr` | `CmdHandler` |
| Lambda — command generator | `CmdGen` | `CmdGen` ✓ |
| Lambda — event mapper | `EvtMapper` / `EventMapper` | `EventMapper` |
| Lambda — event subscription | `EventLogSubLambda` | `EventLogSubscriber` |
| Lambda — state topic | `StateTopicLambda` | `StateTopicPublisher` |
| Lambda — UI definitions/fragments | `…Lambda` | `…Resolver` |
| `*Slice` family | `StateChgSlc` / `AutoSlice` / `InTransSlice` / `OutTransSlice` | full `…Slice` |
| IAM role | varies | `Role` |
| IAM policy | varies | `Policy` |
| Lambda ESM | `EventLogSubESM` | `EventLogSubEventSourceMapping` |

## Guiding principle

The unlock is to make `ComponentType.toName` the **single source of every suffix** and delete the hand-rolled strings in analysis §2.4 / §2.5. After that, the rename is a search-and-replace driven by the table above. Do the work bottom-up (vocabulary first, then emitters, then the strategy builders, then fixtures), building after each layer to keep warnings at zero per [.claude/rules/conventions.md](../../.claude/rules/conventions.md).

---

## Step 1 — Fix the vocabulary in `ComponentType.toName`

File: `reventless/reventless-core/src/ComponentType.res:93-122`

Change the dead/inconsistent suffixes so the table is the truth:

- `QueryDb => "QueryDB"` → `"QueryDb"`
- `StateChangeSlice => "StateChgSlc"` → `"StateChangeSlice"`
- `AutomationSlice => "AutoSlice"` → `"AutomationSlice"`
- `OutboundTranslationSlice => "OutTransSlice"` → `"OutboundTranslationSlice"`
- `InboundTranslationSlice => "InTransSlice"` → `"InboundTranslationSlice"`

Leave `Aggr`, `CmdGen`, `CmdTopic`, `EventColl`, `EventLog`, `EventMapper`, `EventTopic`, `DcbEventLog` as-is (already canonical).

⚠️ **`toName` also feeds runtime tag values / `meta.service` dispatch.** Before changing any `toName` entry, confirm it is *not* read by the in-memory projection-routing contract (analysis §5.5: tags stay as today; `ComponentType.toString` ≠ `toName`). `toString` is the tag source, `toName` is the resource-name source. Verify the split holds for `QueryDb` and the `*Slice` entries — grep for `toName`/`toString` consumers — so renaming `toName` does not silently break `meta.service` routing (see `meta-service-doubles-as-projection-dispatch` memory).

## Step 2 — Aggregate-side emitters (already mostly canonical — verify only)

These already route through `ComponentType.name`, so Step 1 propagates automatically. Build and confirm the emitted names; no literal edits expected:

- `EventLog_Builder.res` → `<Entity>AggrEventLog` ✓
- `EventTopic_Builder.res` → `<Entity>AggrEventTopic` ✓
- `CommandTopic_Builder.res` / `CommandTopicChannel_SQS*.res` → `<Entity>AggrCmdTopic` ✓
- `EventCollectorChannel_SQS*.res` → `<Entity>AggrEventColl` ✓
- `ReadModel`/`QueryDbStorage_DynamoDb.res` → now `<View>ReadModelQueryDb` (changes via Step 1)

## Step 3 — DCB CommandTopic: drop the synthetic `StateChanges` stem

File: `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res:179, 202`

- `~name=`${name}StateChanges`` → `~name=`${name}Dcb`` → final `<Plugin>DcbCmdTopic`
- `~name=`${name}StateChangesAsync`` → `~name=`${name}DcbAsync`` → final `<Plugin>DcbAsyncCmdTopic`

**As shipped (variant-before-kind):** `CommandTopic_Builder.res:75` always appends the `CmdTopic` kind *last*, so the async queue is `<Plugin>DcbAsyncCmdTopic`, not the `…CmdTopicAsync` the §5.3 example drafted. Putting the variant after the kind would require restructuring `CommandTopic_Builder` and would ripple into every aggregate queue name — out of scope. Stem `Dcb`/`DcbAsync`, kind `CmdTopic` greppable.

This flows through `PluginRuntime_Builder.forDcbCommandTopic`, which reads `commandTopicResource.name` (the bare `<Plugin>Dcb`/`<Plugin>DcbAsync`). **As shipped:** async dispatch is detected via `baseName->String.endsWith("Async")` *before* the kind is appended, then the DCB Lambda is named `baseName ++ "CmdHandler"` → `<Plugin>DcbCmdHandler` / `<Plugin>DcbAsyncCmdHandler`.

## Step 4 — AggregateRuntime strategy builders (the strategy-leakage fix)

Replace strategy-encoded Lambda names with the uniform `CmdHandler`/`CmdGen`/`EventMapper` kinds:

**As shipped — the strategy builders live in *two* packages (core + aws), with sync and async variants each:**

- **Single** — `AggregateRuntime_Builder_Single.res` (both `reventless-core` and `reventless-aws` copies): `~name="AllAggregates"` → `"AllAggregatesCmdHandler"` (decision 2 — Single is platform-wide, no plugin scope). The `aggregateHandler("AllAggregates")` log label moves too; the EventCollector `connect(~name="AllAggregates")` keeps the bare stem (→ `…EventColl`). The aws copy also renames the scan IAM policy `AllAggregatesPluginRmScan`/`…Policy` → `AllAggregatesCmdHandler…`.
- **Single async** — `AggregateRuntime_Builder_Single_Async.res` (aws): `"AllAggregatesAsync"` → `"AllAggregatesAsyncCmdHandler"`.
- **Micro** `AggregateRuntime_Builder_Micro.res` + **Micro async** `_Micro_Async.res` (aws):
  - `baseName ++ "CmdTopic"` → `baseName ++ "CmdHandler"` (CT Lambda)
  - `baseName ++ "CmdGen"` → unchanged ✓
  - `baseName ++ "EvtMapper"` → `baseName ++ "EventMapper"` (kill the fabricated `Evt`)
- **PerAggregate** `AggregateRuntime_Builder_PerAggregate.res`: one Lambda does both CommandTopic + EventCollector and reused `name` for both. Split: keep `name` (= `<Entity>Aggr`) for the EventCollector connect (→ `…AggrEventColl`), add `lambdaName = name ++ "CmdHandler"` for the Lambda → `<Entity>AggrCmdHandler`.

After this step `grep CmdHandler` finds every command-handler Lambda in both lineages (analysis §4). Note Micro CT `<Entity>AggrCmdHandler` deliberately matches PerAggregate's Lambda name so switching strategies doesn't rename the shared CT.

## Step 5 — AppSync subscription / state-topic Lambdas, roles, policies, ESM

These are the worst suffix-on-suffix offenders. Rename the hand-rolled literals:

File: `reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res` (`:104, 125, 155, 163, 178, 234, 244, 261`)
- `++ "EventLogSubLambda"` → `++ "EventLogSubscriber"`
- `++ "EventLogSubQueue"` → unchanged ✓ (family prefix)
- `++ "EventLogSubRole"` / `"EventLogSubPolicy"` / `"EventLogSubQueuePolicy"` → unchanged (family prefix)
- `++ "EventLogSubESM"` → `++ "EventLogSubEventSourceMapping"`

File: `reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res` (`:282, 296, 369`)
- `++ "StateTopicLambda"` → `++ "StateTopicPublisher"`
- `++ "StateTopicRole"` / `"StateTopicPolicy"` → unchanged (family prefix)

Note the incoming `name` is already component-suffixed (`OrderAggr…`), so verify no *double* component word results (e.g. avoid `OrderAggrEventLogSubscriberLambda`).

## Step 6 — Platform UI Lambdas — DEFERRED (collision found)

**Not done.** Renaming the backing Lambda's `"Lambda"` suffix → `"Resolver"` collides with the existing AppSync `Resolver` resource in the same file (`Platform_UIDefinitions_Lambda.res:205` and `Platform_UIFragments_Lambda.res`), both already named `Platform…Resolver`. The analysis §5.2 hedged this entry ("or split per role") and §7 never resolved UI naming, so there is no agreed target. The bare `"Lambda"` suffix is self-describing and is *not* a suffix-on-suffix or strategy-leakage offender, so leaving it is consistent with the spirit of the harmonization. `UI`→`Ui` stem casing also left alone: `name = "PlatformUIDefinitions"` feeds the `DataSource`/`Resolver`/role/policy family in lockstep and changing it is pure churn with replace risk and no kind-vocabulary benefit.

If a future pass wants these harmonized, the non-colliding options are `ResolverLambda` (keeps the Lambda/Resolver distinction explicit) or splitting the file's `name` so the Lambda and AppSync resolver derive from different stems. Decide before touching.

## Step 7 — busKeys and stack exports

These encode names as string keys and must move in lockstep or the runtime lookups break:

- `Platform_Admin.res:261` — `"Aggr" ++ "EventLog"` busKey. Confirm it still composes from `ComponentType.name` (no literal drift after Step 1).
- `Plugin_Builder.res:245` — same busKey pattern.
- `Platform.res:833-840, 1720` — the `pluginAggrCmdTopicUrl` stack export. The export **key** literally encodes `Aggr` + `CmdTopic`. Per analysis §5.3 the `Aggr` segment is intentionally retained (operator muscle-memory, existing exports), so the export key stays `pluginAggrCmdTopicUrl`. Only confirm the *value* (the resource name it points at) still resolves after Steps 3–4. Do **not** rename the export key.

## Step 8 — Test fixtures hardcoding emitted names

- `reventless/reventless-local/tests/components/aggregate/AggregateFixtures.res:54, 57` — `"TestItemAggrEventTopic"`. After Step 1 the aggregate side is unchanged, so this likely stays. Re-derive and confirm; update only if the emitted name actually moved.
- Grep the whole repo for any other hardcoded emitted names that moved: `StateChanges`, `AllAggregates`, `EvtMapper`, `QueryDB`, `StateChgSlc`, `AutoSlice`, `InTransSlice`, `OutTransSlice`, `EventLogSubLambda`, `StateTopicLambda`, `EventLogSubESM`. Fix every test/string match.

## Step 9 — In-memory channel names (decision required, analysis §5.5)

In-memory channel names like `"TestItemAggrEventTopic"` are a separate formula. Analysis §5.5 leaves open whether to update them. **Default: leave unchanged** — the aggregate side did not move in Step 1, so they already match. Only revisit if a DCB-side in-memory channel name embedded `StateChanges`. Grep `reventless-local` and `reventless-interop` for embedded suffixes; reconcile.

## Step 10 — Build, zero-warning gate, cold-cutover

**Status:** ✅ Done. Root `pnpm run build` clean (only pre-existing `EventTapTest.res` `sliceToEnd`/`getExn` deprecations remain, unrelated). Tests green: reventless-core 407, reventless-aws 114, reventless-local 446 (967 total). Example builds verified incl. `online-shop-hybrid/platform-aws` (only AWS-backed example — exercises every renamed `reventless-aws` builder). **Cold-cutover deploy performed and successful** on `alpha`.


1. Bottom-up build per package; after each, run the warning gate:
   ```bash
   pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"
   ```
   Fix all before proceeding (zero-warnings rule).
2. Run `pnpm test` across affected packages (`reventless-core`, `reventless-aws`, `reventless-local`, examples).
3. Cold-cutover deploy (decision 5): wipe the alpha stacks, redeploy with new names. Confirm CloudWatch log-group names read the new scheme and `grep CmdTopic` / `grep CmdHandler` resolve across both lineages.

## Acceptance criteria

- `ComponentType.toName` is the only producer of component suffixes; no hand-rolled suffix strings remain in §2.4 / §2.5 sites.
- `grep -r "EvtMapper\|StateChgSlc\|AllAggregates\|StateChanges\|AutoSlice\|InTransSlice\|OutTransSlice\|QueryDB" reventless/ examples/` returns nothing (except intentional `pluginAggrCmdTopicUrl` export key and any deliberately-retained tag strings).
- Both lineages compose names via `<Scope><Stem><Kind>[<Variant>]`; DCB CommandTopic is `<Plugin>DcbCmdTopic` / `<Plugin>DcbAsyncCmdTopic` (variant-before-kind, as shipped).
- Zero compiler warnings; all tests green; alpha stack redeployed clean.

## Out of scope (analysis §5.5)

- Runtime tag values (`ComponentType.toString` / `meta.service`) — unchanged; changing them breaks projection dispatch.
- Production-grade migration (`pulumi state mv`, aliases) — alpha is cold-cuttable.

## Open items to confirm before merge

- Single-strategy plugin-name availability at `AggregateRuntime_Builder_Single.res:271` (Step 4).
- That `toName` and `toString` are genuinely disjoint consumers (Step 1 ⚠️).
- Whether any in-memory channel name actually moved (Step 9).

---

# Phase 2 — §8 follow-up families (not started)

Implements analysis **§8** (the resource families the original §2 inventory skipped). These were never in Phase 1 scope, so they still carry pre-harmonization names. Same scheme, same non-goals (tags/`meta.service` unchanged), same `alpha` cold-cutover migration. Each step builds + runs the zero-warning gate before the next.

### Phase 2 decisions (RESOLVED)

1. **Task bucket resource name** → **`<Task><PascalBucket><Kind>`** (collision-safe; a Task can declare multiple buckets). Bucket `<Task><PascalBucket>Bucket`, Lambda `<Task><PascalBucket>SideEffectHandler`. `bucketName` stays the runtime lookup key; only the resource-name derivation changed (PascalCase-sanitised via a `pascalCase` helper, empty stem for the default unnamed bucket so it stays `<Task>Bucket`). E.g. `ImportProductsProductImportsBucket` / `…SideEffectHandler`; bucket `inbound` → `ImportProductsInboundBucket`. Destructive (S3 physical name derives from logical name) — covered by the cold-cutover.
2. **`ExtPoint`** → **kept** as an established short form (parallels `Aggr`/`CmdGen`/`EventColl`). Only the EP command-handler Lambda gained the unified `CmdHandler` kind.
3. **Scheduler** → **kept bare** `Scheduler` (benign globally-unique singleton; no extra destructive rename).

### Step P2-1 — Task buckets + SideEffectHandler Lambdas 🔴 (the reported `ImportProductsproduct-imports`)

Files: `Task_Builder.res:140`, `TaskBucket_S3.res:12, 13, 38, 54, 71, 89`, `TaskRuntime_Builder_PerBucket.res:20, 73, 91`.

- `Task_Builder.res:140` `let name = taskName ++ bucketName` → derive a clean camelCase resource name (PascalCase the bucket segment per decision 1); keep `bucketName` as the returned Dict key at `:165`.
- The notification handlers (`name ++ "Created"`/`"Deleted"`), IAM policy ids (`name ++ "WriteS3"`/`"ReadS3"`/`"SendSQS"`/`"LambdaPolicy"`), and the SideEffectHandler Lambda (`TaskRuntime_Builder_PerBucket.res:20` `fullName = resource.name ++ name`, used at `:73`) all inherit the base name — they move automatically once the base is fixed. Give the Lambda the `SideEffectHandler` kind if decision 1 splits it out.
- Verify the runtime lookup (`ResourceQueryRuntime`) still resolves by the unchanged `bucketName` key.

### Step P2-2 — ExtensionPoint command-handler Lambda 🟡

Files: `ExtensionPoint_Builder.res:43, 46, 98`, `ExtensionPointRuntime_Builder_PerExtensionPoint.res:71`.

- The EP command-handler Lambda inherits the EP CommandTopic's bare name (`<EP>ExtPoint`) — append the unified `CmdHandler` kind (mirror the DCB fix in `PluginRuntime_Builder`) so `grep CmdHandler` finds EP handlers too: `<EP>ExtPointCmdHandler`.
- Apply the `ExtPoint`-vs-expanded decision (decision 2) to `childName` if expanding.

### Step P2-3 — Scheduler 🟡

File: `Scheduler_Builder.res:15` `~name=Scheduler.componentType->ComponentType.toName` (bare `Scheduler`). If decision 3 chooses a scope prefix, emit `PlatformScheduler`; otherwise leave (benign singleton).

### Step P2-4 — Cloner IAM role 🟡

File: `ClonerRunner_Fargate.res:83` — hand-rolled constant `"ClonerTaskExecutionSecretsManagerAccess"`. Bring under the scheme (`Cloner<Role>`) only if this family is revisited; low priority, single platform resource.

### Step P2-5 — Heartbeat + Counter 🟢 (verify only)

- `Heartbeat` (`Plugin_Builder.res:735`, `PluginRuntime_Builder_Single.res:54` / `_Micro.res:54`) and `Counter` (`Counter_Builder.res:128`) are already on the full-word scheme. No edits — only confirm `childName` (`<Plugin>Plugin`) doesn't yield a `PluginPluginHeartbeat` double-word.

### Phase 2 acceptance

- No malformed concatenations remain: `grep -rn 'taskName ++ bucketName'` gone; Task bucket/Lambda/policy names read as clean camelCase with explicit `Bucket`/`SideEffectHandler` kinds.
- EP command-handler Lambda carries `CmdHandler`; `grep CmdHandler` now finds aggregate, DCB, **and** ExtensionPoint command handlers.
- Zero compiler warnings; all tests green; example builds incl. `online-shop-hybrid/platform-aws` (it has a Task + ExtensionPoints); alpha cold-cutover redeploy clean.
- Heartbeat/Counter confirmed double-word-free.
