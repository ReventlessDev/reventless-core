# Plan: Lambda IAM grant coverage tests

## Motivation

A deployed `InboundTranslationSlice` mutation silently failed to persist its audit
rows: the shared DCB command Lambda is the Route 0 target that writes those rows,
but its IAM role was never granted `PutItem` on the audit table, so every write
returned `AccessDenied`. The write site swallows errors (so the mutation still
returns `CommandAccepted`), and the only observable symptom was a permanently
empty `<Plugin>_ImportProductAudits` view — surfaced downstream as a seed
cross-check failing with `0/0` audit rows.

Root cause (fixed): in `reventless/core/src/components/Dcb/Dcb_Builder.res`, the
command Lambda's granted resource set (`dcbResources`) was collected from each
`InboundTranslationSlice.outputs.resources` — which is always `[]`. The audit
DynamoDB table lives one level down, in `outputs.queryDb.resources`. The grant
therefore never included the audit table.

The fix was a one-line collection change plus un-swallowing the write error. What
is missing is a **regression test**, and — because this is a *class* of bug, not a
one-off — a broader guard over the other Lambda IAM grants that could have the same
oversight.

## The bug class

The grant-collection code walks a component's `outputs.resources` to build the IAM
policy for the Lambda that touches those resources. Several component `outputs`
types **nest** their resources under a sub-record, so any collector that reads only
the top-level `.resources` silently under-grants:

| Component (`reventless/infra/src/components/*.res`) | Nested resource field |
|---|---|
| `InboundTranslationSlice.outputs` | `queryDb: QueryDb.outputs` ← the fixed bug |
| `OutboundTranslationSlice.outputs` | `queryDb: QueryDb.outputs` |
| `StateViewSlice.outputs` | `queryDb: QueryDb.outputs` |
| `AutomationSlice.outputs` | `queryDb: QueryDb.outputs` |
| `ReadModel.outputs` | `queryDb: QueryDb.outputs` |
| `EventLog.outputs` | `eventTopic: EventTopic.outputs` |
| `DcbEventLog.outputs` | `eventTopic: EventTopic.outputs` |
| `ExtensionPoint.outputs` | `eventTopic: Pulumi.Output.t<EventTopic.outputs>` |

The general invariant to protect: **for every Lambda that reads or writes a
resource at runtime, its deploy-time IAM grant must include that resource** — and
in particular the *transitive* resources reachable through nested output records,
not just the top-level `.resources` array.

## Grant sites to audit

The concrete places that collect a Lambda's granted resources (starting points —
confirm the full set during implementation):

- `reventless/core/src/components/Dcb/Dcb_Builder.res` — `dcbResources` /
  `asyncDcbResources` for the sync and async DCB command Lambdas. Route 0 audit
  tables come in via inbound slices' `queryDb.resources` (now fixed); confirm the
  async Lambda's grant is correct if inbound slices are ever routed there.
- `reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_Helpers.res` —
  `createLambdaPolicy` → `dynamoDbResources` / `sqsResources` filters over the
  passed `resources`. Shared by DCB and aggregate command Lambdas.
- `reventless/aws/src/adapter/Task/TaskBucket_S3.res` — `createLambdaPolicy` (S3
  grants for Task Lambdas).
- `reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res` — the
  EventCollector / ExtensionPoint / ReadModel / StateViewSlice runtime wiring;
  each Lambda is granted the tables/queues/topics it accesses.

For each: does the collected set include the *nested* resources of every component
the Lambda touches?

## Test strategy

Two complementary levels. Do at least Level 1; add Level 2 if the Pulumi-mock
harness proves cheap enough.

### Level 1 — pure resource-collection unit test (primary regression guard)

Pin the exact projection that broke. The faithful assertion is: given an
`InboundTranslationSlice.outputs` whose top-level `resources` is `[]` and whose
`queryDb.resources` holds the audit table, the collected command-Lambda resource
set **includes the audit table**. This requires constructing real (unresolved,
deploy-time) `Adapter.resource` and `QueryDb.outputs` values, whose fields are
`Pulumi.Output.t<_>`.

Open question to resolve first: **does `Pulumi.Output.make` (`pulumi.output(x)`)
run under Jest?** No existing core/infra test constructs unresolved outputs — they
all use the *resolved* types (plain strings) — which suggests deploy-time output
construction under Jest is untested and may not work. Resolve this before
committing to the approach:

- If `Pulumi.Output.make` works under Jest: extract a named, pure helper in
  `Dcb_Builder.res`, e.g.
  `collectDcbCommandLambdaResources(~stateChangeSlicesOutputs, ~inboundTranslationSlicesOutputs)`,
  call it at the existing site, and unit-test it with constructed outputs. Do NOT
  parameterise the helper over the resource element type — a polymorphic helper
  would not exercise the `.queryDb.resources` projection, which is where the defect
  lived; the test must read that field on the concrete `outputs` record.
- If it does not work under Jest: bind a tiny `.mjs` fixture that returns
  pre-built output stubs (per the repo's "untyped reflection goes in a companion
  `.mjs`" convention — no `%raw`/`Obj.magic` in `.res`), or fall through to
  Level 2.

Suggested location: `reventless/core/tests/dcb/DcbLambdaResourceGrantTest.res`.

### Level 2 — rendered-policy assertion across Lambda types (breadth)

A higher-level guard that stands up each Lambda's grant through a Pulumi
mock/preview and asserts the rendered IAM `PolicyDocument` statements list the URNs
of every resource the Lambda accesses — extended to cover the nested-resource
components in the table above (StateViewSlice/ReadModel/AutomationSlice `queryDb`,
EventLog/DcbEventLog `eventTopic`, ExtensionPoint `eventTopic`). Model it on the
existing IAM-policy tests (`reventless/aws/tests/CommandTopicQueuePolicyTest.res`)
and the routing guard (`reventless/aws/tests/DcbInboundTranslationRoutingTest.res`,
which drives `buildHandlersForConfig` with a stub loader). This is the guard that
would catch a *new* nested-resource component being added to a grant path without
its sub-record resources.

## Acceptance criteria

- A test fails if an `InboundTranslationSlice` audit table is dropped from the DCB
  command Lambda's granted resources (reverting the fix turns the suite red).
- The nested-resource bug class is guarded for at least the DCB command Lambda; the
  other grant sites in "Grant sites to audit" are either covered or explicitly
  triaged as out of scope with a note on why.
- Runs in CI with no Docker/AWS dependency.

## Related

- Fix: `Dcb_Builder.res` grant change + `DcbCommandTopicEntryPoint_Ops.res`
  audit-write error is now logged instead of swallowed.
- Route 0 receiving-end guard already exists: `DcbInboundTranslationRoutingTest.res`
  (pins that `__inboundTranslation` payloads reach the slice's `receive`; it does
  **not** cover the IAM grant, which is why this plan exists).
