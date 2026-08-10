# Plan: Switching a plugin's slices to the stream builder deletes the shared projection ESM

**Status:** Done (2026-08-10) — root cause found, fixed, regression-tested headlessly.
One verification step needs a live stack and is called out below.

**Found while:** implementing
[change-descriptors-for-non-read-model-tables.md](change-descriptors-for-non-read-model-tables.md).
Unrelated to that plan's seam.

---

## Symptom

Switching a plugin's `StateViewSlice` declarations to the stream builder
(`StateViewSliceStream`) produced a deploy preview that **deletes the shared
projection Lambda's EventSourceMapping** (event log → `AllStateViewSlices`) and
its role policy, recreating neither — while the runtime side still registered
every slice through `StateViewSliceRuntime_Builder_Single`.

## Root cause

**Both resources were created inside one `Pulumi.Output.apply` over three
unrelated input sets, and one of the three went unknown.**

[EventCollectorChannel_Helpers.res](../../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_Helpers.res)'s
`connectLambda` combined its inputs into a single `Pulumi.Output.all3`:

```
(eventTopics->toResources, queueArns, resources->resourcesToResolvedOutput)
->Pulumi.Output.all3
->applyAttributed(...)   // created the role policy AND every EventSourceMapping
```

Pulumi does not run an apply whose inputs are unknown, and a resource the program
never registers reads as a **delete**. So an unknown in *any* of the three removed
*all* of them.

The third input is what went unknown. `QueryDbStorage_DynamoDbStream` returns
**two** resources per view table where the non-stream storage returns one — the
extra one is a `Util_DynamoDbStream.toResource`, whose `id`, `urn` and
`resourceInfo` all derive from the table's **computed** `streamArn`. In the
preview that first enables a stream, that value cannot be known. It flows through
`resourceToResolvedOutput` (which `all6`s `resourceInfo` in) into the shared
`all3`, and the whole callback is skipped.

Neither casualty reads a view table: the EventSourceMappings are built purely from
`eventTopics` (the plugin's event log), and the role policy's stream-read statement
likewise. They were collateral damage of sharing one apply.

This also explains each of the three things the symptom was observed *not* to be:

| Observation | Why |
|---|---|
| Tables update in place, zero replace markers | Only the *computed* `streamArn` is unknown; the table itself is an ordinary in-place update. |
| An all-stream plugin is healthy today | In steady state there is no diff, so `streamArn` is known, the apply runs, and everything registers. The trigger is the **transition**, not the end state. |
| The runtime still registered every slice | `registerStateViewSlice` is synchronous at build time. Only the apply-gated Pulumi resources disappeared. |

## Fix

Split the single apply so each resource waits on the narrowest input it needs:

- **Role policy** — only the policy *document* needs all three inputs. The
  `RolePolicy` resource is now registered at top level with the document as an
  Output input, so an unknown previews as "update, value unknown" instead of
  vanishing. (Same pattern, and same reasoning, as `createQueuePolicy` directly
  above it in the file.)
- **EventSourceMappings** — now gated on `eventTopics->toResources` alone, so no
  view table can reach them.

Resource names, args, parents and tags are unchanged, so there is no identity
churn on an existing stack. Attribution is unchanged too: `applyAttributed`
captures the ambient context at *call* time, which is the same moment the
top-level policy is now created.

## Verification

- **Headless reproduction and regression test** —
  [EventCollectorConnectLambdaPreviewTest.res](../../../reventless/aws/tests/EventCollectorConnectLambdaPreviewTest.res)
  drives `connectLambda` under Pulumi's mock runtime in preview mode with a
  genuinely unknown view-table resource (built the way the engine builds one:
  resolved but flagged not-known, so `.apply` skips it while it is still accepted
  as a resource input — a never-settling promise would not do, since that stalls
  registration too).
  - Against the **pre-fix** code both assertions fail: no role policy, no
    event-log mapping — the reported symptom, reproduced without AWS.
  - Against the fix both register. Full suite: 52 files / 507 tests green, root
    build clean with zero warnings.
- **Still needs a live stack:** a real `pulumi preview` of a plugin switched
  wholesale to `StateViewSliceStream`, showing no deletion of the projection
  Lambda's EventSourceMapping or role policy, and projections still advancing
  after the apply. Run this before treating the interim guidance as lifted.

## Was applying it actually destructive?

Probably not, though it was never safe to rely on that. An apply is skipped only
while its inputs are unknown, and inputs are unknown only during preview — on the
real update pass the values resolve, the callback runs, and the resources
re-register. So the delete list was most likely a preview artifact rather than a
plan that would have executed.

Two reasons that is not reassuring, and not why the fix matters less:

1. With a **saved plan** (`pulumi up --plan`), the preview's plan is what gets
   enforced — there the deletion is real.
2. A preview you cannot trust is not a safety check. The delete list was the only
   signal standing between this change and a frozen read model.

## Residual risk, not addressed here

`applyAttributed` / `flatMapAttributed` exist precisely because several builders
create resources inside applies, and each is exposed to the same class of bug the
moment one of its inputs can go unknown. Remaining sites:
`Plugin_Helpers.res` (×2), `Plugin_Builder.res` (×2),
`ExtensionPoint_Builder.res`, and the Postgres-only pg-secret / appsync-publish
policies in `StateViewSliceRuntime_Builder_Single.buildLambda`. None is implicated
in this symptom and none is changed here — flagged so the next occurrence is
recognised as a class rather than diagnosed from scratch.

The mappings themselves still cannot be hoisted out of an apply: an ESM's Pulumi
name is derived from the resolved source name, so a **brand-new event log** still
previews without its mappings. That is inherent to naming a dynamic set of
resources from resolved data, is pre-existing, and is no longer reachable from an
unrelated table.
