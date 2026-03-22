/**
Module type for a DCB inbound translation slice specification.

An `InboundTranslationSlice` receives external input (webhooks, API calls) and
translates it into domain commands via an anti-corruption layer.

Unlike outbound slices, inbound slices are triggered externally via
`operations.receive` rather than by subscribing to domain events.

```
External Input -> Anti-Corruption Layer (translate) -> Command
```

@example
```rescript
// PaymentWebhook.res
let name = "PaymentWebhook"
module DcbEventLogSpec = OrderingEventLog

@schema type externalInput = {paymentId: string, orderId: string, status: string}
@schema type command = ConfirmPayment({orderId: @s.matches(DcbTag.string) string, paymentId: string})

let translate = input => switch input.status {
  | "completed" => Ok((input.orderId, ConfirmPayment({orderId: input.orderId, paymentId: input.paymentId})))
  | _ => Error("Unknown payment status: " ++ input.status)
}
```
*/
module type Spec = {
  /** Logical name of this inbound translation slice (used as a component prefix). */
  let name: string
  let moduleUrl: string

  /** The DCB event log spec this slice publishes commands to. */
  module DcbEventLogSpec: DcbEventLog.Spec

  /** The external input type received from the outside world. Must carry `@schema`. */
  @schema
  type externalInput

  /** The command type produced by the anti-corruption layer. Must carry `@schema`. */
  @schema
  type command

  /**
  Translate: convert external input into a domain command.
  Returns:
  - `Ok((targetId, cmd))` to publish the command
  - `Error(msg)` to reject the input
  */
  let translate: externalInput => result<(string, command), string>
}
