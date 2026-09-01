/**
Module types for a DCB inbound translation slice.

An `InboundTranslationSlice` receives external input (webhooks, API calls) and
translates it into domain commands via an anti-corruption layer.

Unlike outbound slices, inbound slices are triggered externally via
`operations.receive` rather than by subscribing to domain events.

```
External Input -> Anti-Corruption Layer (translate) -> Command
```

Plan 02 splits the merged spec into two module types:

- `Spec` — types, identity, schemas, target name. (No state — translation is
  a pure function of external input.)
- `Translation` — the single `translate` function.

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

/**
The lean Spec for an InboundTranslationSlice — types, identity, schemas.
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

  /** Name of the aggregate or StateChangeSlice that receives the produced command. */
  let targetName: string

  /** Optional display name of the foreign system this anti-corruption slice receives
      from (e.g. `"SupplierFeed"`). Drives the **external box** drawn outside the plugin
      in the Event Graph / Context Map.
      Auto-injected by `@@reventless.spec` defaulting to `None` — set it to name the box. */
  let externalSystem: option<string>

  /** Authorization rule evaluated at the GraphQL resolver entry before any
      external input is translated. Auto-injected by `@@reventless.spec` and
      on structurally-detected inline spec modules — defaults to
      `AllowAuthenticated`. */
  let commandAuthorization: command => Authorization.permission

  /** The lifecycle enum this component's commands move a row through — the
      linked view's own, e.g. `type lifecycleState = Customers.accountStatus`.
      Auto-injected as `unit` alongside the default below; a host that declares
      `commandTransition` declares this too, and the pair is what makes every
      edge name one lifecycle. */
  type lifecycleState

  /** The lifecycle edge each command owns, read while the plugin structure is
      assembled. Auto-injected as `_ => Unrestricted` by `@@reventless.spec`,
      so a component whose commands guard nothing needs no line; a host that
      writes the switch by hand gets an exhaustive one over typed states.
      See `Transition`. */
  let commandTransition: command => Transition.t<lifecycleState>
}

/**
The Translation — the synchronous translate function.
*/
module type Translation = {
  module Spec: Spec

  /**
  Translate: convert external input into domain commands.
  Returns:
  - `Ok([(targetId, cmd), ...])` to publish one or more commands
  - `Ok([])` for idempotent no-ops (nothing to publish)
  - `Error(msg)` to reject the input
  */
  let translate: Spec.externalInput => result<array<(string, Spec.command)>, string>

  /** File URL of this Translation module (`import.meta.url`). */
  let moduleUrl: string
}

