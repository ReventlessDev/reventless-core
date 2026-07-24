# Backlog: InboundTranslationSlice mutations are not routed on AWS

**Status:** Not started
**Origin:** [inbound-translation-mutation-result-type.md](../done/inbound-translation-mutation-result-type.md) —
its "AWS parity" step asked whether these mutations are routed at all on AWS.
They are not, and that is a defect of its own rather than part of the result-type fix.

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

## Sketch

Add a third route to `DcbCommandTopicEntryPoint.mjs`, ahead of the two existing
ones, keyed on `event.__inboundTranslation`: look the field up in a
receive-function registry built by `buildHandlersForConfig`, run it, and encode
the outcome with the same `commandOutcomeToJson` the AppSync direct-invocation
route already uses. The result-type fix put the encoder in reach —
`InboundTranslationSlice.receiveResultToOutcome` maps a `receive` outcome onto a
`CommandTopic.commandOutcome`, so both surfaces stay byte-compatible.

The open question is how the entry point gets the per-field `receive` functions.
`HANDLER_CONFIG` currently describes command handlers; inbound slices would need
their spec + translation modules listed so `buildHandlersForConfig` can build
`InboundTranslationSlice_Callback.Make(Spec, Translation).receive` per field —
and the audit QueryDb writes need a runtime-pure storage path (see
`DcbCommandTopicEntryPoint_Ops`, which exists because deploy-time Pulumi in the
runtime graph broke cold start once already).

## Acceptance

- An InboundTranslationSlice mutation against a deployed stack publishes its
  commands, writes its audit row, and returns a payload that resolves as
  `CommandAccepted` / `CommandRejected`.
- A test asserts the entry point routes an `__inboundTranslation` payload —
  the gap that let this ship is that the flag is only ever asserted on the
  sending side.
