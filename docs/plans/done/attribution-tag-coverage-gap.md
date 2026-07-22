# Plan: close the attribution-tag coverage gap on taggable resources

**Status**: Done (2026-07-22) — every taggable creator now passes `~tags`; the untaggable set is
documented in `AWS_Tags.res`. **The audit table below was substantially wrong; see "Corrected audit"
at the end for what was actually found and done.**
**Nature**: mechanical follow-up to the attribution tag schema
(`docs/plans/done/resource-attribution-tag-schema.md`), which fixed the tag *contents* and tagged
several previously-untagged creators. This closes the remaining creators that AWS allows to be
tagged and the framework still leaves bare.
**Touches**: `reventless/aws/src/util/` creators and their call sites. Additive — a resource gaining
tags is an in-place update, not a replacement.

## Motivation

Attribution tags are the only mechanism by which a deployed resource says which model element owns
it. Where the framework creates a resource without them, that resource is unattributable
downstream — every consumer sees infrastructure it cannot place.

The tag-schema plan fixed what the tags *say*. It did not finish saying it everywhere: several
creators still call the provider without `~tags` even though the underlying AWS type accepts them.

**Audit of `reventless/aws/src/util/` (2026-07-22):**

| Creator | Tags today | Provider accepts tags |
|---|---|---|
| `Util_SQS`, `Util_SQS_FIFO` | yes | yes |
| `Util_SNS`, `Util_SNS_FIFO` | yes | yes |
| `Util_EventSourceMapping` | **no** | **yes** |
| `Util_Cloudwatch` (metric alarms) | **no** | **yes** |
| `Util_S3` / bucket creators (`Plugin_Stack`, `TaskBucket_S3`) | **no** | **yes** |
| `Util_AppSync` | **no** | partly — see below |

## The boundary this plan must respect

**Not every AWS type can be tagged, and no amount of coverage work changes that.** Verified against
the provider type definitions: `aws:iam/rolePolicy`, `aws:sqs/queuePolicy`, `aws:lambda/permission`
and `aws:appsync/dataSource` expose **no `tags` property at all**. Those resources can never be
attributed by tag, so this plan must not pretend otherwise, and any downstream consumer that treats
"has attribution tags" as universal will still be wrong afterwards.

That is the reason this plan is worth doing but is not sufficient on its own: it raises coverage
over the taggable set, and leaves a permanent untaggable remainder that has to be attributed
structurally (by URN ancestry) rather than by tag. Sequencing the two matters — a consumer that
derives attribution structurally will handle both sets, so this plan makes its job smaller rather
than replacing it.

## Items

### T1 — `Util_EventSourceMapping`

`EventSourceMapping.make` is called with no `~tags`. The mapping's owner is unambiguous at the call
site — it already receives `~targetName` and `~sourceName` — so the tags follow the same
`AWS_Tags.make` shape as the queue and topic creators, with the role naming the piece the mapping
belongs to.

### T2 — CloudWatch metric alarms

Alarms created for monitoring carry no tags. They are per-component by construction (an alarm exists
*for* something), so the owning component is available where they are created. Tag them with the
same schema; without it, monitoring resources are invisible to attribution while being exactly the
resources an operator most wants to trace back to an element.

### T3 — S3 buckets

Both bucket creators (`Plugin_Stack`, `TaskBucket_S3`) omit tags. The task bucket is component-owned;
the plugin/platform bucket is substrate and should carry the scope that says so, not be left bare —
an untagged resource and a resource tagged `scope=platform` are different facts, and only the second
is a statement.

### T4 — AppSync

`Util_AppSync` creates several resource kinds; the GraphQL API itself was tagged by the tag-schema
plan. Audit the rest and tag those the provider supports, leaving `dataSource` (untaggable)
documented as such rather than silently skipped.

### T5 — record the untaggable set

Document, next to `AWS_Tags`, which framework-created types cannot carry tags. This is the list a
future coverage audit needs in order to distinguish "not tagged yet" from "cannot be tagged", and
without it every future audit re-derives it from provider schemas.

## Verification

For each item: deploy a stack exercising that creator and confirm the resource carries the full
`reventless:*` set. A count-based check ("N% of resources are tagged") is not meaningful while the
untaggable remainder exists — verification is per-creator, not per-estate.

## Risks

- **Tagging is an in-place update for every type here**, so no replacement and no data loss. Worth
  confirming per type in the plan's execution, since a type that made tags part of its identity
  would be a different story.
- **Coverage work invites the wrong conclusion** — that attribution is now complete. T5 exists to
  prevent that: the untaggable set is permanent, and consumers must not assume tags are universal.

## Done when

- Every creator in the audit table either passes `~tags` or is listed as untaggable in T5.
- The untaggable list is documented beside `AWS_Tags` rather than living in a plan.

---

## Corrected audit (2026-07-22, on execution)

The plan's audit table did not survive contact with the code. It was re-derived mechanically: every
`X.Y.make` call site in `reventless/aws/src` matched against whether the `@pulumi/aws` 7.19.0 type
for that resource exposes `tags`, with the call's full balanced-paren argument text checked for a
tag argument (the earlier line-window heuristic produced false negatives wherever `tags` was bound
to a `let` above the call).

### Where the plan was wrong

| Plan's claim | Reality |
|---|---|
| T2 — "CloudWatch metric alarms carry no tags" | **The framework creates no metric alarms.** A `Cloudwatch_MetricAlarm` binding exists, but nothing in `reventless/aws/src` or `examples/` constructs one. `Util_Cloudwatch` is a resource *converter* — it creates nothing. T2 had no subject. |
| T3 — "Both bucket creators omit tags" | **Both already tag.** `TaskBucket_S3` and `Plugin_Stack`'s bundle bucket were done by the tag-schema plan's phase 3. `Util_S3`, like `Util_Cloudwatch`, creates nothing. |
| T4 — "audit the rest of `Util_AppSync`" | Both `AppSync.GraphQLApi` sites are tagged. Every *other* AppSync type the framework creates — `dataSource`, `resolver` (incl. aws-native), `function`, `sourceApiAssociation` — is untaggable. T4 collapses into T5. |
| T1 — `Util_EventSourceMapping` | **Correct**, and worth noting *why* the earlier sweep skipped it: the tag-schema plan recorded EventSourceMappings as having no tag support, which was true then. AWS added it, and `@pulumi/aws` 7.19.0 exposes `EventSourceMappingArgs.tags`. The ReScript binding had no `tags` field, so this needed a binding change first. |

### Gaps the plan missed

Six real bare-resource sites the audit table did not list:

- **4 SQS queues** — the two shared dead-letter queues (`Util_DeadLetterQueue`), the EventLogSubscription
  buffer queue, and the Postgres projection feed queue. The table's "`Util_SQS`, `Util_SQS_FIFO`: yes"
  row is true but misleading: those are converters, and these four are direct `SQS.Queue.make` calls.
- **1 Lambda execution role** — `RuntimeEnvironment_Lambda`'s legacy path called
  `IAM.Role.makeWithDefaultPolicy` without `~tags` while tagging the Lambda beside it.
- **1 ECS task definition** — the Fargate cloner's, taggable and bare.

### What was implemented

- **Bindings** (`rescript/pulumi-aws`): `tags` added to `EventSourceMapping.args` and
  `ECS_TaskDefinition.args`.
- **`Util_EventSourceMapping`**: `~tags` is **required**, not optional, on both `subscribe` and
  `subscribeSqs`. An optional argument is precisely how these were left bare last time; making the
  caller name the owning piece is the compile-time regression guard — the same reasoning the
  tag-schema plan used for `makeFromCodeAsset`'s required `~componentKind`. All 7 call sites updated
  (EventCollector ×2, CommandTopic, Counter, EventLogSubscription, PgProjectionFeed, DLQ ×2), plus
  the one direct `EventSourceMapping.make` in `StateTopic_AppSync`.
- **Role choice**: mappings carry `role = EventSourceMapping`, the vocabulary's existing "transport
  wiring between a source and a runtime" — not the role of the piece they serve, as T1 suggested. A
  resource's `role` is the piece *it* implements; which component it belongs to is what `kind` /
  `component` / `scope` already say.
- **The six missed sites** tagged with the schema their siblings use.
- **T5** (`AWS_Tags.res`): the untaggable set, verified against `@pulumi/aws` 7.19.0, with the note
  that AWS does add tag support over time — EventSourceMapping being the proof — so the list is
  re-verified on a major provider bump rather than trusted forever.

### One deliberate exclusion

`aws:s3/bucketObject` is taggable and stays untagged. Static-bundle assets are bucket *contents*,
not infrastructure: they are fully attributed by the bucket that holds them, and S3 bills object
tags per object per month, so tagging a few hundred bundle files would cost money to restate a fact
the parent already carries. Recorded in `AWS_Tags.res` as *taggable, deliberately untagged* — a
different fact from *cannot be tagged*, and the distinction is the point of T5.

### Verification

Monorepo builds clean with zero warnings; the full suite is green (191 suites / 1403 tests).

**The plan's own verification step — deploy a stack per creator and confirm the `reventless:*` set
on the live resource — has NOT been run.** That needs a real deploy, which is user-initiated here.
Two things are worth checking on the next alpha deploy: that each newly-tagged resource shows an
in-place update rather than a replacement (the plan's first Risk), and that the EventSourceMapping
tags actually land — that one depends on AWS-side tag support the provider only recently gained.
