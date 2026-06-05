# AWS Resource Naming Harmonization

## Purpose

Catalogue how Reventless currently names the AWS resources it provisions (Lambda functions, DynamoDB tables, SQS queues, SNS topics, IAM roles), document the inconsistencies between the **aggregate/read-model** lineage and the **DCB (Dynamic Consistency Boundary)** lineage, and propose a harmonized scheme that one can apply across both architectural styles without breaking existing identifiers more than necessary.

Scope: the *logical* resource names Reventless feeds to Pulumi (`~name` parameters). The physical AWS names that Pulumi derives from these (with stack suffixes and random IDs) inherit every inconsistency surveyed here.

## TL;DR

Three patterns coexist today and contradict each other:

1. **Component-type suffix** via `ComponentType.toName` — uses abbreviations (`"Aggr"`, `"CmdTopic"`, `"CmdGen"`, `"EventColl"`, `"EvtMapper"` — actually inconsistent with the table, see below).
2. **Plain English suffix** hand-rolled at the call site — `"StateChanges"`, `"StateChangesAsync"`, `"Lambda"`, `"EventLogSubLambda"`, `"StateTopicLambda"`, `"EventLogSubQueue"`.
3. **Strategy override** in the AggregateRuntime builders — `"AllAggregates"` (Single), bare component name (PerAggregate), or fresh abbreviations like `"EvtMapper"` (Micro) that don't match any other layer.

The proposal in §5 collapses these to one scheme: `<Scope><Stem><Kind>` with one canonical `<Kind>` suffix per AWS resource type, plus a small, alphabetised vocabulary.

---

## 1. The current vocabulary

`ComponentType.toName` (`reventless/reventless-core/src/ComponentType.res:93-122`) is the only programmatic source of truth for suffixes. It returns:

| Component type | `toName` suffix | Used as Lambda name? | Used as queue/table name? |
|---|---|---|---|
| Aggregate | `Aggr` | yes (PerAggregate runtime) | as nested-resource prefix (`FooAggrEventLog`) |
| CommandTopic | `CmdTopic` | yes (Micro runtime) | yes (`FooAggrCmdTopic` SQS queue) |
| CommandGenerator | `CmdGen` | yes (Micro runtime) | n/a (no AWS resource of its own) |
| EventCollector | `EventColl` | indirectly | indirectly |
| EventLog | `EventLog` | n/a | yes (`FooAggrEventLog` DynamoDB) |
| EventMapper | `EventMapper` | **no** — Micro runtime uses `"EvtMapper"` instead | n/a |
| EventTopic | `EventTopic` | n/a | yes (`FooAggrEventTopic` SNS) |
| ExtensionPoint | `ExtPoint` | n/a | n/a (logical only) |
| QueryDb | `QueryDB` | n/a | yes (DynamoDB) |
| ReadModel | `ReadModel` | n/a | n/a (logical only) |
| DcbEventLog | `DcbEventLog` | n/a | yes (DynamoDB) |
| StateChangeSlice | `StateChgSlc` | **no** — Dcb_Builder uses `"StateChanges"` instead | n/a |
| StateViewSlice | `StateViewSlice` | n/a | n/a |
| AutomationSlice | `AutoSlice` | n/a | n/a |
| OutboundTranslationSlice | `OutTransSlice` | n/a | n/a |
| InboundTranslationSlice | `InTransSlice` | n/a | n/a |

Two of the entries (`EventMapper → EventMapper`, `StateChangeSlice → StateChgSlc`) are dead code — their actual emitters bypass `toName` and write a different string by hand.

---

## 2. Resource-by-resource inventory

### 2.1 DynamoDB tables

| Resource | Naming code | Emitted name |
|---|---|---|
| Aggregate EventLog | `EventLog_Builder.res:19` via `Storage.make(~name=name->ComponentType.name(EventLog.componentType))` | `<Entity>AggrEventLog` |
| Aggregate EventLog (stream variant) | same | `<Entity>AggrEventLog` |
| DCB EventLog | `DcbEventLog_Builder.res:20` via `~name=name->ComponentType.name(DcbEventLog.componentType)` | `<Plugin>DcbEventLog` |
| ReadModel QueryDb | `QueryDbStorage_DynamoDb.res` via passed `~name` | `<View>ReadModelQueryDB` |

Observations:
- The DCB table omits the `Aggr` shape entirely and reuses the *component type* word — the parent scope (plugin name) instead of an entity name. There is no plugin-aware variant for the aggregate side.
- `QueryDB` is the only suffix with uppercase abbreviation (`DB`); everything else is camelCase.

### 2.2 SQS queues

| Resource | Naming code | Emitted name |
|---|---|---|
| Aggregate CommandTopic (sync) | `CommandTopic_Builder.res:75-77` + `CommandTopicChannel_SQS.res:48` | `<Entity>AggrCmdTopic` |
| Aggregate CommandTopic (FIFO/async) | `CommandTopicChannel_SQS_Async.res` / `_FIFO.res` | `<Entity>AggrCmdTopic` (same name, FIFO flag flipped) |
| DCB CommandTopic (sync) | `Dcb_Builder.res:178` `DcbCommandTopic.make(~name=`${name}StateChanges`)` | `<Plugin>StateChangesCmdTopic` |
| DCB CommandTopic (async) | `Dcb_Builder.res:202` `~name=`${name}StateChangesAsync`` | `<Plugin>StateChangesAsyncCmdTopic` |
| Aggregate EventCollector | `EventCollectorChannel_SQS.res` | `<Entity>AggrEventColl` |
| Aggregate EventCollector (FIFO) | `EventCollectorChannel_SQS_FIFO.res` | `<Entity>AggrEventColl` |
| EventLogSubscription buffer | `EventLogSubscription_AppSync.res:104` `~name=name ++ "EventLogSubQueue"` | `<X>EventLogSubQueue` |

Observations:
- DCB takes the parent `name` (the plugin name) and *adds a synthetic stem* `"StateChanges"` / `"StateChangesAsync"`, then `CommandTopic_Builder` re-adds its own `"CmdTopic"` suffix on top. End result has *two* component words: `…StateChangesCmdTopic`.
- `EventLogSubQueue` is the only queue that hand-rolls a `"Queue"` suffix into the name. Every other queue relies on the resource type to identify itself.

### 2.3 SNS topics

| Resource | Naming code | Emitted name |
|---|---|---|
| EventTopic (sync) | `EventTopic_Builder.res:19` via `ComponentType.name(EventTopic.componentType)` | `<Entity>AggrEventTopic` |
| EventTopic (FIFO) | `EventTopicPublisher_SNS_FIFO.res` | `<Entity>AggrEventTopic` |

Consistent — EventTopic is the cleanest leaf in the tree.

### 2.4 Lambda functions

This is where the divergence is most visible.

| Source | Code | Emitted name pattern | Example |
|---|---|---|---|
| `AggregateRuntime_Builder_Single` | `:271` `~name="AllAggregates"` | constant | `AllAggregates` |
| `AggregateRuntime_Builder_Micro` (CT) | `:219` `baseName ++ "CmdTopic"` | `<Agg>CmdTopic` | `OrderCmdTopic` |
| `AggregateRuntime_Builder_Micro` (CG) | `:248` `baseName ++ "CmdGen"` | `<Agg>CmdGen` | `OrderCmdGen` |
| `AggregateRuntime_Builder_Micro` (EM) | `:292` `baseName ++ "EvtMapper"` | `<Agg>EvtMapper` | `OrderEvtMapper` |
| `AggregateRuntime_Builder_PerAggregate` | `:211` `~name` (= `<Entity>Aggr`) | `<Agg>Aggr` | `OrderAggr` |
| `PluginRuntime_Builder.forDcbCommandTopic` | `:763` `commandTopicResource.name` | `<Plugin>StateChangesCmdTopic` | `CatalogStateChangesCmdTopic` |
| `PluginRuntime_Builder` async DCB | same as sync, with `StateChangesAsync` stem | `<Plugin>StateChangesAsyncCmdTopic` | `CatalogStateChangesAsyncCmdTopic` |
| `Platform_UIDefinitions_Lambda.res:77` | `~name = name ++ "Lambda"` | `<X>Lambda` | `PlatformUIDefinitionsLambda` |
| `Platform_UIFragments_Lambda.res:73` | `~name = name ++ "Lambda"` | `<X>Lambda` | `PlatformUIFragmentsLambda` |
| `EventLogSubscription_AppSync.res:234` | `~name = name ++ "EventLogSubLambda"` | `<X>EventLogSubLambda` | `OrderAggrEventLogSubLambda` |
| `StateTopic_AppSync.res:369` | `~name = name ++ "StateTopicLambda"` | `<X>StateTopicLambda` | `…StateTopicLambda` |

Six different conventions across one project. In particular:

- **The Micro runtime fabricates `"EvtMapper"`** even though `ComponentType.toName(EventMapper)` returns `"EventMapper"` — a silent contradiction of the central vocabulary.
- **Suffix-on-suffix** in EventLogSubscription/StateTopic Lambdas: they receive a name like `OrderAggr…` (already component-suffixed) and add another `EventLogSubLambda` on top.
- The constant **`"AllAggregates"`** is the only place where the runtime strategy itself is encoded in the Lambda name. PerAggregate doesn't say "PerAggregate" anywhere; Micro doesn't say "Micro".

### 2.5 IAM roles and policies

`EventLogSubscription_AppSync.res` and `StateTopic_AppSync.res` are the only places that mint roles/policies with hand-rolled suffixes:

| Naming code | Suffix | Resource |
|---|---|---|
| `~name = name ++ "EventLogSubRole"` | `EventLogSubRole` | IAM Role |
| `~name = name ++ "EventLogSubPolicy"` | `EventLogSubPolicy` | IAM Policy |
| `~name = name ++ "EventLogSubQueuePolicy"` | `EventLogSubQueuePolicy` | SQS Queue Policy |
| `~name = name ++ "EventLogSubESM"` | `EventLogSubESM` | Lambda Event Source Mapping |
| `~name = name ++ "StateTopicRole"` | `StateTopicRole` | IAM Role |
| `~name = name ++ "StateTopicPolicy"` | `StateTopicPolicy` | IAM Policy |

All other components let Pulumi default the role/policy names (which then inherit the parent component name with Pulumi-generated suffixes). The result is that within one stack, half the IAM roles read `<Stem>EventLogSubRole-<hash>` and the other half read `<Stem>-role-<hash>`.

---

## 3. The four axes of inconsistency

1. **Vocabulary** — `Aggr` vs `Aggregate`, `Cmd` vs `Command`, `Evt` vs `Event`, `Slc` vs `Slice`. The codebase has at least two abbreviations for every term.
2. **Word order** — `<Entity><ComponentType>` (`OrderAggrEventLog`) vs `<Scope><FunctionalStem>` (`CatalogStateChanges`) vs `<Stem><ResourceKind>` (`PlatformUIDefinitionsLambda`).
3. **Component-type repetition** — DCB names like `CatalogStateChangesCmdTopic` carry two component words because the parent stem already names a function and the child builder appends its own type.
4. **Strategy leakage** — `AllAggregates` and `EvtMapper` encode runtime-strategy choices into resource names; PerAggregate and DCB hide them. Switching strategies therefore renames resources, which is destructive in Pulumi (delete + create).

---

## 4. What the names need to support

Constraints any harmonized scheme must respect:

- **Pulumi-stable**: renaming a logical name triggers replace. The scheme must let us rename in *one* migration, not piecewise.
- **AWS-length-safe**: DynamoDB table names ≤ 255 chars; Lambda names ≤ 64 chars; SQS queue names ≤ 80 chars (75 if FIFO, since `.fifo` is auto-appended). Stack suffixes added by Pulumi consume ~16 chars. So our logical names should stay under ~45 chars to leave headroom.
- **Greppable**: `grep CmdTopic` in CloudWatch should find all command-topic Lambdas across both lineages.
- **Visible architecture**: a developer reading a CloudWatch log group name should be able to tell whether they are looking at an aggregate or a DCB slice without consulting source.

---

## 5. Proposal: one scheme, two lineages

### 5.1 Naming formula

```
<Scope><Stem><Kind>[<Variant>]
```

- **Scope** — `Plugin`, `Platform`, or omitted when the stem is globally unique.
- **Stem** — the user-facing entity or feature name (`Order`, `Catalog`, `ProductDemand`).
- **Kind** — exactly one canonical word per AWS resource type (see §5.2).
- **Variant** — optional; only `Async`, `Fifo`, `Stream`, `Dlq`. Never combine more than one variant.

### 5.2 Canonical kind vocabulary

Drop the abbreviations. Use the full word that already appears in framework documentation and the component-type enum.

| AWS resource | Today (mixed) | Proposed `<Kind>` |
|---|---|---|
| DynamoDB event log (aggregate) | `EventLog` | `EventLog` ✓ |
| DynamoDB event log (DCB) | `DcbEventLog` | `EventLog` (with `Dcb` Stem when applicable) |
| DynamoDB query store | `QueryDB` | `QueryDb` (camelCase) |
| SQS command queue | `CmdTopic` | `CommandTopic` |
| SQS event collector | `EventColl` | `EventCollector` |
| SQS subscription buffer | `EventLogSubQueue` | `EventSubscriptionQueue` |
| SNS event topic | `EventTopic` | `EventTopic` ✓ |
| Lambda — command handler | `CmdTopic`, `StateChangesCmdTopic`, `AllAggregates`, `<Agg>Aggr` | `CommandHandler` |
| Lambda — command generator | `CmdGen` | `CommandGenerator` |
| Lambda — event mapper | `EvtMapper`, `EventMapper` | `EventMapper` |
| Lambda — event subscription | `EventLogSubLambda` | `EventSubscriber` |
| Lambda — state topic | `StateTopicLambda` | `StateTopicPublisher` |
| Lambda — UI definitions | `Lambda` (after PlatformUIDefinitions) | `UiResolver` (or split per role) |
| IAM role | varies | `Role` |
| IAM policy | varies | `Policy` |
| Lambda ESM | `EventLogSubESM` | `EventSourceMapping` |

### 5.3 Lineage stems

| Architecture | Stem composition | Example (`Catalog` plugin, `Order` aggregate, `ProductDemand` DCB slice) |
|---|---|---|
| Aggregate | `<Entity>` | `OrderEventLog`, `OrderCommandTopic`, `OrderEventTopic`, `OrderCommandHandler`, `OrderCommandGenerator`, `OrderEventMapper` |
| ReadModel | `<View>` | `OrdersQueryDb` (plural per convention), `OrdersEventSubscriber` |
| DCB | `<Plugin>Dcb` for the shared infra; `<Plugin><SliceStem>` for per-slice resources | `CatalogDcbEventLog`, `CatalogDcbCommandTopic`, `CatalogDcbCommandHandler`, `CatalogProductDemandSlice` (logical only) |
| Async DCB | … `Async` variant | `CatalogDcbCommandTopicAsync`, `CatalogDcbCommandHandlerAsync` |
| Platform | `Platform<Feature>` | `PlatformUiDefinitionsResolver`, `PlatformPluginAggregateCommandTopic` |

### 5.4 Why this resolves the four axes

1. **Vocabulary** — every abbreviation gets one full-word replacement; the `ComponentType.toName` table becomes a 1:1 echo of `toString`, removing the silent contradictions (`EventMapper` vs `EvtMapper`, `StateChangeSlice` vs `StateChanges`).
2. **Word order** — universal `<Scope><Stem><Kind>`. The DCB CommandTopic loses its synthetic `StateChanges` stem (which never matched a component type) in favour of `<Plugin>DcbCommandTopic`, which mirrors how the aggregate side composes naturally.
3. **Component-type repetition** — `CatalogStateChangesCmdTopic` becomes `CatalogDcbCommandTopic`: one stem, one kind.
4. **Strategy leakage** — `AllAggregates` becomes `<Plugin>CommandHandler` (Single), `<Aggregate>CommandHandler` (PerAggregate), or `<Aggregate><Sub>Handler` (Micro). Switching Single↔PerAggregate still requires replacement (the *number* of Lambdas changes), but switching PerAggregate↔Micro of a single aggregate stops renaming the shared CT/EM/CG names.

### 5.5 Non-goals

- This proposal does **not** change tag values (`ReventlessCore.<X>.componentType`). Those are inspected at runtime and changing them would break the in-memory dispatch contract (`meta.service` ↔ projection routing). Tags stay as today.
- It does **not** change in-memory channel names like `"TestItemAggrEventTopic"` — those are documented (`AggregateFixtures.res:54`) and used in tests. A separate decision is whether the in-memory channel-name formula should be updated to match.

---

## 6. Migration sketch

This is a destructive Pulumi rename across nearly every resource the framework creates. Three options, in increasing safety:

1. **Cold-cutover** (suitable while everything is still on the `alpha` branch). Wipe stacks, deploy the new names. Aligned with the `feedback_alpha_wipe_over_migration` note in memory.
2. **`pulumi state mv` script** per stack — generate the rename map from the table in §5.3 and apply per-resource. Preserves history.
3. **Aliases** — declare `aliases: [{name: <old>}]` on each new component for one release cycle, then drop. This is the option to use once anything is in production.

Whichever path is chosen, the **single change** that unlocks the rename is to make `ComponentType.toName` the only place that produces a suffix, and to delete every hand-rolled string in §2.4 / §2.5. Once that's done the migration is a search-and-replace over the table.

---

## 7. Open questions

1. **`QueryDB` vs `QueryDb` casing** — sury and Pulumi don't care, but consistency suggests camelCase. The `ComponentType.toString` value is already `"QueryDB"` (uppercase suffix), which is exported in resource tags. Decide before renaming.
2. **`Aggr` is short and ubiquitous in operator muscle-memory.** Switching to `Aggregate` lengthens every aggregate-side name by 5 chars. With a 64-char Lambda budget and `~16` char Pulumi stack suffix, `<Entity>AggregateCommandHandler` fits comfortably (~40 chars for a 14-char entity). Acceptable.
3. **Per-aggregate vs Single strategy in Lambda names** — keeping the runtime-strategy information out of the name (option B: `<Aggregate>CommandHandler` even for Single) means a Single deployment has a single Lambda named after… nothing canonical. Two reasonable resolutions: `<Plugin>CommandHandler` (Single, plugin-scoped) or revive `AllAggregates` *only* for Single mode. Pick before §5.3 stems are finalised.
4. **Sliced DCB** — slices today have no per-resource AWS footprint (all consolidated into `CatalogDcbCommandTopic`). If we ever break a slice out into its own Lambda (per-slice strategy parallel to PerAggregate), the proposed scheme needs a `<Plugin><SliceStem>CommandHandler` form pre-agreed.

---

## Appendix A: Files touched by a full rename

Naming-related sites that would change:

- `reventless/reventless-core/src/ComponentType.res` (vocabulary)
- `reventless/reventless-core/src/components/Aggregate/Aggregate_Builder.res`
- `reventless/reventless-core/src/components/CommandTopic/CommandTopic_Builder.res`
- `reventless/reventless-core/src/components/CommandGenerator/CommandGenerator_Builder.res`
- `reventless/reventless-core/src/components/EventMapper/EventMapper_Builder.res`
- `reventless/reventless-core/src/components/EventLog/EventLog_Builder.res`
- `reventless/reventless-core/src/components/EventTopic/EventTopic_Builder.res`
- `reventless/reventless-core/src/components/EventCollector/EventCollector_Builder.res`
- `reventless/reventless-core/src/components/ReadModel/ReadModel_Builder.res`
- `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res` (lines 178, 202 — the `StateChanges` literal)
- `reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Builder.res`
- `reventless/reventless-core/src/admin/Platform_Admin.res:261` (the `"Aggr" ++ "EventLog"` busKey)
- `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res:245` (same busKey)
- `reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res:271`
- `reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Micro.res:219, 248, 292`
- `reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_PerAggregate.res:211`
- `reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res:763, 852`
- `reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res:104, 125, 155, 163, 178, 234, 244, 261`
- `reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res:282, 296, 369`
- `reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res:77`
- `reventless/reventless-aws/src/adapter/Api/Platform_UIFragments_Lambda.res:73`
- `reventless/reventless-aws/src/Platform.res:833-840, 1720` (the `pluginAggrCmdTopicUrl` stack export — note the export key itself encodes `Aggr` + `CmdTopic`)

Test fixtures that hardcode emitted names:

- `reventless/reventless-in-memory/tests/components/aggregate/AggregateFixtures.res:54, 57` (`"TestItemAggrEventTopic"`)
