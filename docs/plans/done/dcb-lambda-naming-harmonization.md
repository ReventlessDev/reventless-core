# DCB Lambda naming harmonization (Option A, no aliases)

Renames the per-plugin DCB command-handler Lambdas to follow the same
`<scope><noun><Async?>` rule as the Aggregate-side Lambdas. Accepts
destroy/recreate on `pulumi up` — **no Pulumi `aliases` transition**.

Companion analysis: [docs/analysis/done/command-handler-lambda-naming-harmonization.md](../../analysis/done/command-handler-lambda-naming-harmonization.md).

## Goal

| Current | New |
|---|---|
| `<Plugin>Plugin-dcb-command-topicCommandTopic` | `<Plugin>StateChanges` |
| `<Plugin>Plugin-dcb-async-command-topicCommandTopic` | `<Plugin>StateChangesAsync` |

Concrete example, Catalog plugin:
- `CatalogPlugin-dcb-command-topicCommandTopic` → `CatalogStateChanges`
- `CatalogPlugin-dcb-async-command-topicCommandTopic` → `CatalogStateChangesAsync`

The Aggregate-side names (`AllAggregates`, `AllAggregatesAsync`, `<Name>Aggregate`,
`<Name>AggregateCmdTopic`/`CmdGen`) are unchanged.

## Out of scope

- Aliases/in-place rename. **All renamed Pulumi resources will be destroyed
  and recreated** on the first `pulumi up` after this lands. See
  [Deployment impact](#deployment-impact) below.
- Aggregate `Micro` naming polish (Option B).
- Per-plugin Aggregate variant (Option C).

## Steps

### Step 1 — Rename the DCB CommandTopic resources

[reventless/reventless-core/src/components/Dcb/Dcb_Builder.res:178](../../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res#L178):

```rescript
// before
let dcbCommandTopic = DcbCommandTopic.make(~name=`${childName}-dcb-command-topic`, ~opts)
```
```rescript
// after — `name` is in scope on `construct` and is the bare plugin name
// (no `Plugin` suffix), so `${name}StateChanges` reads as expected.
let dcbCommandTopic = DcbCommandTopic.make(~name=`${name}StateChanges`, ~opts)
```

[reventless/reventless-core/src/components/Dcb/Dcb_Builder.res:202](../../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res#L202):

```rescript
// before
let t = DcbAsyncCommandTopic.make(~name=`${childName}-dcb-async-command-topic`, ~opts)
```
```rescript
// after
let t = DcbAsyncCommandTopic.make(~name=`${name}StateChangesAsync`, ~opts)
```

### Step 2 — Drop the doubled `CommandTopic` suffix on the Lambda name

[reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res:546-548](../../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res#L546-L548):

```rescript
// before
let commandTopicResource = dcbCommandTopic->ReventlessCore.Component.toPulumiResource
let name = commandTopicResource.name->ReventlessCore.ComponentType.nameOpt(
  ReventlessCore.CommandTopic.componentType,
)
```
```rescript
// after — the CommandTopic resource is already named `<Plugin>StateChanges[Async]`,
// so we don't need (and shouldn't add) the `CommandTopic` suffix on the Lambda.
let commandTopicResource = dcbCommandTopic->ReventlessCore.Component.toPulumiResource
let name = commandTopicResource.name->Option.getOr("UnnamedDcb")
```

### Step 3 — Tighten the async detection

[reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res:562-571](../../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res#L562-L571).
Currently we substring-match the kebab-case marker; with the new convention the
`Async` suffix is the unambiguous signal:

```rescript
// before — substring match against the kebab-case naming convention
let isAsync = commandTopicResource.name
  ->Option.map(n => n->String.includes("-dcb-async-command-topic"))
  ->Option.getOr(false)
```
```rescript
// after — direct suffix check on the canonical name. Robust because the
// `Async` suffix is now guaranteed only on async-mode DCB CommandTopics.
let isAsync = name->String.endsWith("Async")
```

Update the surrounding comment to match.

### Step 4 — Build, verify, fix any consequent breakage

```bash
pnpm run build
pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"   # must be empty
pnpm -r --filter='./reventless/*' test
pnpm -r --filter='./examples/**/platform-in-memory' test
```

Failing tests to watch for:

- In-memory DCB tests that hardcode the topic resource name in
  assertions or mock setup — search for `dcb-command-topic` in
  `reventless/reventless-in-memory/tests/` and `examples/*/platform-in-memory/tests/`
  and update string literals to `StateChanges` / `StateChangesAsync`.
- `reventless-codegen` golden fixtures under
  `reventless/reventless-codegen/tests/golden/` that include resource names
  in their expected output — diff with `ForwardGoldenTest.res` will surface
  these.

### Step 5 — Update docs

Find-and-replace targets (verify each is the literal old name before replacing):

| File | Occurrences |
|---|---|
| [.claude/rules/app-developer.md:54](../../../.claude/rules/app-developer.md) | `<plugin>-dcb-async-command-topic*` → `<Plugin>StateChangesAsync` |
| [docs/guides/dcb-usage.md:477,490](../../guides/dcb-usage.md) | code-block reference to `${childName}-dcb-command-topic` |
| [docs/guides/lambda-deployment.md:233](../../guides/lambda-deployment.md) | table row naming the DCB Lambda |
| [docs/guides/platform-and-plugin-guide.md:975](../../guides/platform-and-plugin-guide.md) | `<plugin>-dcb-async-command-topic*` mention |
| [packages/doc/docs-app/components/commandtopic.md:93](../../../packages/doc/docs-app/components/commandtopic.md) | inline references to both names |
| [packages/doc/docs-app/dcb-slices.md:231](../../../packages/doc/docs-app/dcb-slices.md) | `<plugin>-dcb-async-command-topic*` mention |
| [packages/doc/docs-framework/architecture/dcb.md:297](../../../packages/doc/docs-framework/architecture/dcb.md) | `${childName}-dcb-command-topic` code-block reference |

Leave the analysis file
([docs/analysis/done/command-handler-lambda-naming-harmonization.md](../../analysis/done/command-handler-lambda-naming-harmonization.md))
alone — it's the historical record of the rename and refers to the old names
intentionally. Same for `docs/plans/done/*` and `docs/analysis/done/*`.

### Step 6 — Move plan to `done/`

Use `git mv` to preserve history:

```bash
git mv docs/plans/dcb-lambda-naming-harmonization.md docs/plans/done/
```

Then commit the move as part of the final commit (per the project's plan-completion
convention).

## Deployment impact

`pulumi up` after this lands will, **for every plugin that has any
StateChangeSlice**, destroy and recreate the following:

- The DCB CommandTopic `Pulumi.ComponentResource` (parent)
- The underlying SQS queue (Standard, and FIFO if any async slices exist)
- The Lambda function + IAM role + role policies
- The SQS → Lambda event-source mapping
- The AppSync `DataSource` for DCB mutations + its IAM role policy
- Every AppSync `Resolver` for a DCB mutation field (they reference the
  data-source ARN)

### Observable consequences during cutover

1. **In-flight FIFO messages are lost.** The FIFO queue is recreated empty.
   For async StateChangeSlices, any commands sitting in the queue at the
   moment of cutover are dropped on the floor.
2. **Standard-queue messages are similarly lost** but sync StateChangeSlices
   typically have an empty queue at steady state (Route 1 dispatches inline;
   Route 2 only sees overflow from explicit `publishJsons` callers).
3. **Brief AppSync gap.** Between the old DataSource being destroyed and the
   new resolvers being attached, DCB mutations on this plugin will fail with
   "no matching resolver." Pulumi orders the replacement to minimize the gap
   (typically sub-second) but it is not zero.
4. **Different CloudWatch log group.** The new Lambda gets a fresh log group;
   historical logs stay accessible under the old name but new log entries
   accumulate under the new name. Dashboards filtering by log-group name
   need updating.

### Pre-deploy checklist

Before merging and running `pulumi up` against any non-throwaway stack:

- [ ] Confirm no business-critical async StateChangeSlice is taking sustained
      traffic at the deploy window (FIFO queue should be drained).
- [ ] Identify CloudWatch dashboards / alarms / log-based metrics filtering
      on `*-dcb-command-topic*` or `*-dcb-async-command-topic*` log-group
      names. Note for follow-up.
- [ ] Identify any external monitoring (Datadog, etc.) that pins on the
      Lambda function name. Note for follow-up.
- [ ] Plan a maintenance window if either of the above is non-empty.

### Stacks affected

For the `alpha` branch this currently affects the deployed alpha stack
identified by `.github/layer-arn-alpha.txt`. Any downstream stacks that pin
the alpha branch will see the same destroy/recreate on their next deploy.

## Verification

After deploy:

1. Confirm new Lambdas exist:
   ```
   aws lambda list-functions --query 'Functions[?contains(FunctionName, `StateChanges`)].FunctionName'
   ```
   Expect one entry per plugin with StateChangeSlices, plus an `Async` sibling
   per plugin that has at least one `@@reventless.async` slice.
2. Confirm old Lambdas are gone:
   ```
   aws lambda list-functions --query 'Functions[?contains(FunctionName, `dcb-command-topic`)].FunctionName'
   ```
   Expect empty result.
3. Invoke a DCB mutation via AppSync and verify it returns
   `CommandAccepted` (sync slice) or `CommandPending` (async slice).
4. Check the new Lambda's CloudWatch logs for the routing log line
   `----- dcbCommandTopicHandler: AppSync direct invocation (sync|async)`
   and confirm the mode matches expectation.
5. For async slices: verify the SQS event source dispatches the command —
   second log line `----- dcbCommandTopicHandler: processing N record(s)`
   should appear shortly after the AppSync invocation.

## Commit shape

Single commit, conventional-commits prefix `refactor!:` (breaking — the
exclamation triggers the major-version bump that signals the destroy/recreate).

```
refactor(aws)!: rename DCB Lambdas to <Plugin>StateChanges[Async]

Harmonizes DCB command-handler Lambda names with the Aggregate side
(`AllAggregates` / `AllAggregatesAsync` / `<Name>Aggregate`):

- `<Plugin>Plugin-dcb-command-topicCommandTopic` → `<Plugin>StateChanges`
- `<Plugin>Plugin-dcb-async-command-topicCommandTopic` → `<Plugin>StateChangesAsync`

Drops the doubled `Plugin` and `CommandTopic` nouns and the kebab-case
spliced with CamelCase. The async-detection in PluginRuntime_Builder
becomes a clean `endsWith("Async")` suffix check rather than a
substring match on the old kebab-case marker.

BREAKING CHANGE: this is a Pulumi resource rename without `aliases`,
so `pulumi up` will destroy and recreate the DCB Lambda, its SQS
queue(s), the AppSync DataSource and resolvers, and associated IAM.
In-flight FIFO messages on async StateChangeSlices are lost. Plan a
maintenance window for stacks with sustained async DCB traffic.
```
