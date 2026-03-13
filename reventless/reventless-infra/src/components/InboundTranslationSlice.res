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
Runtime operations exposed by an `InboundTranslationSlice` component.

- `receive` -- accept external input, translate it, and publish a command
*/
type operations = {
  receive: JSON.t => promise<result<string, string>>,
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
  /** The DCB event type this slice operates on (fixed by `Spec.DcbEventLogSpec.event`). */
  type dcbEvent
  module Spec: Reventless.InboundTranslationSlice.Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string
  let make: (
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
