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

@schema type externalInput = {paymentId: string, orderId: string, status: string}
@schema type command = ConfirmPayment({orderId: @s.matches(DcbTag.string) string, paymentId: string})

let translate = input => switch input.status {
  | "completed" => Ok([(input.orderId, ConfirmPayment({orderId: input.orderId, paymentId: input.paymentId}))])
  | _ => Error("Unknown payment status: " ++ input.status)
}
```
*/
module type Spec = {
  /** Logical name of this inbound translation slice (used as a component prefix). */
  let name: string
  let moduleUrl: string

  /** The external input type received from the outside world. Must carry `@schema`. */
  @schema
  type externalInput

  /** The command type produced by the anti-corruption layer. Must carry `@schema`. */
  @schema
  type command

  /**
  Translate: convert external input into domain commands.
  Returns:
  - `Ok([(targetId, cmd), ...])` to publish one or more commands
  - `Ok([])` for idempotent no-ops (nothing to publish)
  - `Error(msg)` to reject the input
  */
  let translate: externalInput => result<array<(string, command)>, string>

  /** Name of the aggregate or StateChangeSlice that receives the produced command. */
  let targetName: string
}
