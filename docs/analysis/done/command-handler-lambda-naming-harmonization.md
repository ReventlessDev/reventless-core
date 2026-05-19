# Command-handler Lambda naming harmonization

## Problem

Aggregate-side and DCB-side command-handler Lambdas follow different naming
conventions. The DCB names are also internally inconsistent (kebab-case spliced
with CamelCase, doubled `Plugin` and `CommandTopic` nouns) and don't read as
parallel siblings of the Aggregate names.

### Current naming (Pulumi resource names, what `pulumi up` writes)

| Strategy / mode | Lambda Pulumi name |
|---|---|
| Aggregate `Single` (sync) | `AllAggregates` |
| Aggregate `Single_Async` | `AllAggregatesAsync` |
| Aggregate `PerAggregate` | `<Name>Aggregate` (e.g. `ProductAggregate`) |
| Aggregate `Micro` (cmdTopic + cmdGen) | `<Name>AggregateCmdTopic` + `<Name>AggregateCmdGen` |
| DCB sync (per plugin) | `<Plugin>Plugin-dcb-command-topicCommandTopic` (e.g. `CatalogPlugin-dcb-command-topicCommandTopic`) |
| DCB async (per plugin) | `<Plugin>Plugin-dcb-async-command-topicCommandTopic` |

### Three independent inconsistencies in the DCB names

1. **Casing.** Aggregate Lambdas are CamelCase; DCB uses kebab-case
   (`dcb-command-topic`) spliced with a trailing CamelCase `CommandTopic`
   suffix added by [`ComponentType.nameOpt`](reventless/reventless-core/src/ComponentType.res).
2. **Doubled noun.** `dcb-command-topic` is followed by `CommandTopic`,
   producing the literal `…-command-topicCommandTopic` substring.
3. **Doubled `Plugin`.** The naming uses `childName = name->ComponentType.name(Plugin)`,
   which expands to `<Plugin>Plugin` (e.g. `CatalogPlugin`). The DCB names then
   prefix that with the `-dcb-…` segment, so the final resource carries
   `<Plugin>Plugin-…` even though the user only ever sees the plugin name.

The Aggregate-side names sidestep these by passing literal CamelCase strings
(`"AllAggregates"`) directly to `RuntimeEnvironment_Lambda.makeFromCodeAsset`
rather than routing through the CommandTopic resource's own name.

## Proposal

DCB Lambdas should follow the same rule as Aggregate Lambdas:

> **`<scope><noun><AsyncSuffix?>`**, where `noun` is `Aggregates` or
> `StateChanges`, `scope` is `All` for platform-wide bundles or `<Plugin>` for
> plugin-scoped bundles or `<Name>` for per-component, and `Async` is appended
> when the channel is FIFO.

| Strategy / mode | Current | Proposed |
|---|---|---|
| Aggregate `Single` sync | `AllAggregates` | `AllAggregates` *(unchanged)* |
| Aggregate `Single_Async` | `AllAggregatesAsync` | `AllAggregatesAsync` *(unchanged)* |
| Aggregate `PerAggregate` | `<Name>Aggregate` | `<Name>Aggregate` *(unchanged)* |
| Aggregate `Micro` cmdTopic | `<Name>AggregateCmdTopic` | `<Name>AggregateInbox` *(or keep)* |
| Aggregate `Micro` cmdGen | `<Name>AggregateCmdGen` | `<Name>AggregateResolver` *(or keep)* |
| **DCB sync** | `<Plugin>Plugin-dcb-command-topicCommandTopic` | **`<Plugin>StateChanges`** |
| **DCB async** | `<Plugin>Plugin-dcb-async-command-topicCommandTopic` | **`<Plugin>StateChangesAsync`** |

For the Catalog plugin, that gives the four sibling names:

- `AllAggregates` — every (sync) aggregate across all plugins
- `AllAggregatesAsync` — every async aggregate across all plugins
- `CatalogStateChanges` — every (sync) state-change slice in Catalog
- `CatalogStateChangesAsync` — every async state-change slice in Catalog

## Implementation sketch

### `Dcb_Builder.res`

Replace the two `make` call sites
([line 178](reventless/reventless-core/src/components/Dcb/Dcb_Builder.res#L178)
and [line 202](reventless/reventless-core/src/components/Dcb/Dcb_Builder.res#L202)).

The plugin name is already in scope as `~name` on `construct`; it doesn't carry
the `Plugin` suffix that `childName` adds. Use it directly:

```rescript
let dcbCommandTopic = DcbCommandTopic.make(
  ~name=`${name}StateChanges`,
  ~opts,
)
let t = DcbAsyncCommandTopic.make(
  ~name=`${name}StateChangesAsync`,
  ~opts,
)
```

### `PluginRuntime_Builder.res` (reventless-aws)

Drop the `nameOpt(CommandTopic.componentType)` suffix at
[line 546-548](reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res#L546-L548)
so the Lambda name matches the CommandTopic resource name rather than gaining
a doubled `CommandTopic` tail:

```rescript
let commandTopicResource = dcbCommandTopic->ReventlessCore.Component.toPulumiResource
let name = commandTopicResource.name->Option.getOr("UnnamedDcb")
```

The async-detection introduced for `DISPATCH_MODE` becomes a clean
suffix-match rather than the brittle substring scan it is today:

```rescript
let isAsync = name->String.endsWith("Async")
```

This is robust because the new convention guarantees the `Async` suffix only
appears on async-mode Lambdas; the old convention had a `-dcb-async-` substring
that had to be matched literally.

## Trade-offs

### Pros

- Reads parallel to the Aggregate side; the four bundle names line up.
- Removes both doubled nouns (`Plugin-Plugin`, `command-topic-CommandTopic`).
- Cleans the async-detection path in `PluginRuntime_Builder` from substring
  match to suffix match.
- Makes CloudWatch log groups and IAM role names noticeably shorter and
  easier to scan in the AWS console.

### Cons (significant)

This is a **breaking Pulumi resource rename**. On `pulumi up`, every renamed
resource is treated as a destroy-then-create unless aliased. For each affected
plugin, that destroys and recreates:

- The DCB CommandTopic ComponentResource (parent)
- The underlying SQS queue (FIFO and/or Standard)
- The Lambda function + Lambda role + Lambda role-policy
- The SQS → Lambda event-source mapping
- The AppSync DataSource for DCB mutations + its IAM role-policy
- The AppSync Resolvers for every DCB mutation field (they reference the
  data-source ARN)

The replacement is observable: in-flight FIFO messages are lost (the queue is
recreated empty) and AppSync briefly has no resolvers wired for DCB mutations
during the cutover window. For idempotent producers retrying via standard
retry policies this is recoverable; for one-shot producers it's a maintenance
window.

### Mitigation: Pulumi aliases

The destructive rename is avoidable by passing
[`aliases`](https://www.pulumi.com/docs/iac/concerns/options/aliases/)
on each renamed resource for one release cycle:

```rescript
let dcbCommandTopic = DcbCommandTopic.make(
  ~name=`${name}StateChanges`,
  ~opts={
    ...opts,
    aliases: [{name: `${name}Plugin-dcb-command-topic`}],
  },
)
```

Pulumi then treats the rename as an in-place rename, not a destroy/create,
preserving the underlying AWS resource (and its message backlog) under a
new logical name. After every stack has redeployed at least once, the
aliases can be removed.

This requires the framework's component builders (`CommandTopic_Builder.make`,
the AWS `RuntimeEnvironment_Lambda.makeFromCodeAsset`, the affected AppSync
helpers) to accept an optional `~aliases` arg and thread it through to the
Pulumi resource constructors. That plumbing already exists in some places
via `Pulumi.ComponentResource.options` but isn't uniformly available; the
transitional release would need to surface it where missing.

## Scope options

Three levels of harmonization to choose from.

### Option A — DCB-only (recommended)

Just rename the DCB Lambdas. Two lines in `Dcb_Builder.res`, ~three lines in
`PluginRuntime_Builder.res`, plus Pulumi aliases for one transitional release.
The Aggregate side already follows the proposed rule; no changes there.

This is the minimum that closes the readability gap and was the original
motivation for the question.

### Option B — Also rename Aggregate `Micro` Lambdas

`<Name>AggregateCmdTopic` / `<Name>AggregateCmdGen` →
`<Name>AggregateInbox` / `<Name>AggregateResolver` (or any other pair the
team prefers). The current names are functional but the abbreviations
(`Cmd*`) don't match the longer-form naming used elsewhere.

This is bikeshed-territory; the existing names aren't *wrong*, they're
just shorter than the rest. Skip unless there's a separate reason.

### Option C — Introduce `<Plugin>Aggregates` per-plugin variant

The current Aggregate `Single` strategy bundles aggregates *across all
plugins* into one `AllAggregates` Lambda. The DCB side bundles *per plugin*
into `<Plugin>StateChanges`. The naming proposed here makes that asymmetry
explicit and visible (`All` vs `<Plugin>`), but doesn't fix it.

A separate proposal could add a per-plugin Aggregate builder
(`AggregateRuntime_Builder_PerPlugin`?) that produces `<Plugin>Aggregates`
and `<Plugin>AggregatesAsync` Lambdas — symmetric with the DCB side. That's
a behavioral change (cost profile, cold-start pool, deploy churn) and
warrants its own design.

## Recommendation

Take **Option A**. It's the smallest change that addresses the
readability/parallelism complaint, and the aliases mitigation makes it
non-disruptive to existing stacks for one release.

Option B is optional polish and shouldn't gate A. Option C is a separate
architectural conversation about Lambda bundling strategy, not naming.
