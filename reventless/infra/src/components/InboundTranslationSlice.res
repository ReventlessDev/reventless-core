/**
Deploy-time outputs produced when an `InboundTranslationSlice` is provisioned.

- `resources` -- the underlying infrastructure
- `queryDb` -- the DynamoDB table for the audit log
*/
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
}

/**
A translation that ran to completion.

- `requestId` -- the key the audit row is stored under
- `targetIds` -- the entities the produced commands address; empty when the
  translation legitimately produced no command
- `commandCount` -- how many commands were published
*/
type acceptedResult = {
  requestId: string,
  targetIds: array<string>,
  commandCount: int,
}

/**
A translation that was rejected -- by input parsing, by `translate`, by an
authorization check, by command encoding or by the publish itself.

- `requestId` -- the key the audit row is stored under
- `error` -- the rejection message
- `errorCode` -- `"Forbidden"` for a refused caller; absent for a failed translation
*/
type rejectedResult = {
  requestId: string,
  error: string,
  errorCode?: string,
}

/**
Outcome of `receive`. Both arms carry `requestId` so a caller can correlate the
response with the slice's audit row, and so the GraphQL resolver can report a
`msgId` on either arm.
*/
type receiveResult = result<acceptedResult, rejectedResult>

/**
Runtime operations exposed by an `InboundTranslationSlice` component.

- `receive` -- accept external input, translate it, and publish its commands.
  `caller` is who sent it; absent means the platform itself.
*/
type operations = {
  receive: (JSON.t, ~caller: Reventless.Identity.t=?) => promise<receiveResult>,
}

/**
Module type produced by `Platform.InboundTranslationSlice.Make(Spec)`.

@example
```rescript
module PaymentWebhookSlice = Platform.InboundTranslationSlice.Make(PaymentWebhook)
let slice = PaymentWebhookSlice.make(~publishJsons=publishJsonsOutput)
```
*/
type t

module type T = {
  module Spec: Reventless.InboundTranslationSlice.Spec
  module Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string
  let make: (
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~runtime: RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
