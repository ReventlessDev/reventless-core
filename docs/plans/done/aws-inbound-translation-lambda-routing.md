# InboundTranslationSlice mutations are not routed on AWS

**Status:** Done (2026-07-27) — implemented; awaits republish + layer rebuild +
redeploy to land on `alpha`. Confirmed against a live `alpha` seed run.
**Origin:** [inbound-translation-mutation-result-type.md](../done/inbound-translation-mutation-result-type.md) —
its "AWS parity" step asked whether these mutations are routed at all on AWS.
They are not, and that is a defect of its own rather than part of the result-type fix.

## Confirmed reproduction (2026-07-27)

`pnpm run seed` (online-shop-hybrid, sample data set) against `alpha` aborts on the
first `Catalog_ImportProduct` — the only inbound-translation command in the seed.
Every prior operation (product adds, catalog edits) is a StateChangeSlice command
that goes through Route 1 and succeeds; only the supplier-feed import path fails:

```
Catalog_ImportProduct(sku: "SKU-4410", …) failed
  response: [{"errorType":"Lambda:Unhandled",
  "message":"Cannot read properties of undefined (reading 'length')"}]
```

**Correction to the original note below:** the failure is *loud, not silent*. The
inbound payload (no `command`, no `Records`) reaches Route 2, which calls
[`CommandTopicChannel_SQS_Runtime.handleQueueEvent`](../../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res#L1)
with `event.records === undefined`; the first `Array.filterMap` reads `.length` of
undefined and throws before anything else runs. So the mutation does not even return
`""` — it 500s. Net effect for the caller is the same (no command, no audit row), but
the diagnostic is a crash, not an empty result.

## What happens

The AppSync resolver for an InboundTranslationSlice mutation invokes the shared
DCB CommandTopic Lambda with a payload marked `__inboundTranslation`
([`AppSync_Resolver_Functions.invokeInboundTranslation:942-955`](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L942-L955)):

```js
payload: { __inboundTranslation: true, fieldName: '<field>', arguments: ctx.args }
```

The deployed Lambda entry point
([`DcbCommandTopicEntryPoint.mjs:206`](../../../reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs#L206))
has exactly two routes and neither matches:

- **Route 1** — AppSync direct invocation, guarded on `event.command != null && event.arguments != null`.
  The inbound payload carries `arguments` but no `command`, so the guard fails.
- **Route 2** — SQS records, `event.Records || []`. The inbound payload has no
  `Records`, so this processes an empty batch and returns `""`.

So the mutation returns an empty string: no translation runs, no command is
published, no audit row is written, and `""` cannot resolve to `CommandResult`
either. Silent, not loud.

The in-process equivalent — the composite handler in
[`Dcb_Builder.res:707-741`](../../../reventless/core/src/components/Dcb/Dcb_Builder.res#L707-L741) —
*does* check `__inboundTranslation` and dispatch to the slice's `receive`. That
handler is built at deploy time from resolved Pulumi Outputs; the deployed
Lambda runs the hand-written `.mjs` entry point instead, which never sees it.

## Why it went unnoticed

`__inboundTranslation` appears in the file that emits it, in the in-process
composite handler, and in one resolver-template unit test that asserts the
request template sets the flag
([`AppSync_Resolver_FunctionsTest.mjs:602`](../../../rescript/pulumi-aws/tests/AppSync_Resolver_FunctionsTest.mjs#L602)).
Nothing asserts the receiving end reads it.

## Implementation (2026-07-27)

Add a **Route 0** to `DcbCommandTopicEntryPoint.mjs`, ahead of the two existing
ones, keyed on `event.__inboundTranslation`: look `event.fieldName` up in a
receive-function registry built by `buildHandlersForConfig`, run it against
`event.arguments`, and encode the outcome with the same `commandOutcomeToJson`
the AppSync direct-invocation route already uses.
`InboundTranslationSlice.receiveResultToOutcome` maps a `receive` outcome onto a
`CommandTopic.commandOutcome`, so both surfaces stay byte-compatible.

Resolved design questions:

- **Per-field `receive` functions.** `HANDLER_CONFIG` gains an
  `inboundTranslationSliceModules: [{spec, translation, auditTableName}]` array.
  The shell dynamically imports the spec + translation modules (the one untyped
  seam), then the typed `DcbCommandTopicEntryPoint_Ops.buildInboundReceiver`
  wraps the curried `InboundTranslationSlice_Callback.Make(Spec)(Translation)`
  functor call and its `receive` — mirroring `buildSliceHandler`, so a functor
  signature change is a build error, not a runtime shift.
- **The `fieldName` is derived, not threaded.** Both the deploy-time resolver
  (`Api_Naming.sliceMutationField(~plugin=name, ~slice=Spec.name)`) and the
  runtime registry key off `${pluginName}_${specName}`. `Plugin_Builder.make`
  passes the *same* `name` to both `registerPluginName` (→ `HANDLER_CONFIG.pluginName`)
  and `DcbBuilder.construct`, so `config.pluginName ++ "_" ++ specName` reconstructs
  the field name exactly. No new field needs to cross the deploy/runtime boundary.
- **Audit QueryDb writes use a runtime-pure storage path.**
  `QueryDbEntryPoint_Ops.makeDynamoQueryDbOps(~tableName)` already returns
  `QueryDb_Adapter.operations` with `save` — no Pulumi in the import graph. The
  audit table's *resolved physical* name is Pulumi-generated (like the DCB
  EventLog table, read at deploy time via `registerDcbTableName`), so it is
  threaded per slice as `auditTableName`. After `receive`, the shell drains the
  in-memory `Callback.auditLog` into that table (best-effort: absent table name
  → skip, matching the in-process path's inline `syncToQueryDb`).

Deploy-time wiring:

- AWS `InboundTranslationSlice_Builder.Make.Make` registers `(specName, specPath,
  translationPath)` from the Spec/Translation `moduleUrl`s at functor
  instantiation (mirrors `StateChangeSlice_Builder`), and — wrapping `make` —
  registers the constructed component's audit-table-name `Output` by specName.
- `PluginRuntime_Builder` collects these (`registeredInboundSlices`) and
  `forDcbCommandTopic` passes them to `StateChangeSliceRuntime_Builder_Single`,
  which resolves the table-name Outputs and emits the
  `inboundTranslationSliceModules` fragment into `HANDLER_CONFIG`. The inbound
  slices' spec/translation package roots are added to the code archive so the
  Lambda can import them.

## Acceptance

- [x] An InboundTranslationSlice mutation publishes its commands (Route 0 →
  `receive` → `publishJsons` onto the DCB FIFO), writes its audit row (best-effort
  DynamoDB `save` via `makeDynamoQueryDbOps`, threaded `auditTableName`), and
  returns a payload that resolves as `CommandAccepted` / `CommandRejected`
  (`receiveResultToOutcome` → `commandOutcomeToJson`, byte-compatible with Route 1).
- [x] A test asserts the entry point routes an `__inboundTranslation` payload:
  [`DcbInboundTranslationRoutingTest`](../../../reventless/aws/tests/DcbInboundTranslationRoutingTest.res)
  drives the real `buildHandlersForConfig` with an inbound slice module and
  dispatches the payload as `handler`'s Route 0 does. Runs in CI (no Docker — the
  fixture translation rejects, so no SQS/DynamoDB is touched).

## Files touched

- `reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs` — Route 0 +
  receiver registry.
- `reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res` —
  `buildInboundReceiver` (typed functor call + audit persistence).
- `reventless/aws/src/adapter/Runtime/StateChangeSliceRuntime_Builder_Single.res` —
  `inboundTranslationSliceModules` fragment in `HANDLER_CONFIG` + code-archive
  package dirs.
- `reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res` —
  `registerInboundTranslationSliceSpec` / `registerInboundAuditTableName`.
- `reventless/aws/src/components/InboundTranslationSlice_Builder.res` — path +
  audit-table-name registration.

## Follow-ups

- Postgres-backed audit persistence: `makeDynamoQueryDbOps` is DynamoDB-only, so on
  a PG platform the receiver runs without writing the audit row. Wire the PG
  QueryDb runtime path when a PG-backed inbound slice ships.
- The reject-path CI test does not exercise SQS publish or the audit `save`; the
  Docker-gated `DcbCommandTopicEntryPoint_IntegrationTest` is the place to add an
  accept-path case if end-to-end publish coverage is wanted.
