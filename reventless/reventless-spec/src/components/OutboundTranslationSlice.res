/**
Module types for a DCB outbound translation slice.

An `OutboundTranslationSlice` listens to the shared `DcbEventLog` event topic,
collects outbound items (TODO list), and calls an external service for each one.
The translate function may optionally return a command to publish back into the
system, closing the loop.

Replaces fire-and-forget `SideEffectHandler` with tracked, retryable external calls.

```
Event(s) -> TODO List (read model) -> Translator -> External Service
                                                  -> Command (optional)
```

Plan 02 splits the merged spec into two module types:

- `Spec` — types, identity, schemas, sweep config. Per D2, `outboundItem`
  lives here (persisted TODO state with schema).
- `Translation` — `collect` (sync, observable in tests) and `translate`
  (async, mocked in tests via `whenTranslateMocked`).

@example
```rescript
// SendTrackingEmail.res
let name = "SendTrackingEmail"

@schema type outboundItem = {orderId: string, email: string}
@schema type inboundCommand = unit

let collect = event => switch event {
  | OrderShipped({orderId, email}) => [(orderId, {orderId, email})]
  | _ => []
}

let translate = async (_id, item) => {
  await EmailService.send(item.email, ~orderId=item.orderId)
  Ok(None) // fire-and-forget: no command back
}

let maxRetries = 3
let heartbeatInterval = 60
```
*/

/**
The lean Spec for an OutboundTranslationSlice — types, identity, schemas, sweep config.
*/
module type Spec = {
  /** Logical name of this outbound translation slice (used as a component prefix). */
  let name: string
  let moduleUrl: string

  /**
  Events this outbound translation slice consumes for collect.
  Only needs the fields required — no tag annotations needed.
  Must carry `@schema`.
  */
  @schema
  type consumedEvent

  /** The outbound item state — what data is accumulated for each pending external call. Must carry `@schema`. */
  @schema
  type outboundItem

  /** The command type optionally produced after a successful translate call. Must carry `@schema`. */
  @schema
  type inboundCommand

  /** Maximum number of retries for a failed translate attempt. */
  let maxRetries: int

  /** Heartbeat interval in seconds for sweeping pending/failed items. */
  let heartbeatInterval: int

  /** Name of the aggregate or StateChangeSlice that receives the inbound command, or None for fire-and-forget. */
  let targetName: option<string>
}

/**
The Translation — `collect` and async `translate`. Both functions are
distinguished from the Inbound shape (which has only a sync `translate`).
*/
module type Translation = {
  module Spec: Spec

  /**
  Collect: map an incoming event to zero or more new outbound items.
  Each item has an `id` (deduplication key) and the `outboundItem` payload.
  Returns empty array if this event is not relevant.
  */
  let collect: Spec.consumedEvent => array<(string, Spec.outboundItem)>

  /**
  Translate: call the external service for a single outbound item.
  Returns:
  - `Ok(Some((targetId, cmd)))` to publish a command back into the system
  - `Ok(None)` for fire-and-forget (no command back)
  - `Error(msg)` on failure (item will be retried up to maxRetries)
  */
  let translate: (string, Spec.outboundItem) => promise<
    result<option<(string, Spec.inboundCommand)>, string>,
  >

  /** File URL of this Translation module (`import.meta.url`). */
  let moduleUrl: string
}

