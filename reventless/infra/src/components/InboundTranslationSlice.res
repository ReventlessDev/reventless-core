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
  receive: JSON.t => promise<result<array<string>, string>>,
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
