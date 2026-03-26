/**
Module type for a DCB outbound translation slice specification.

An `OutboundTranslationSlice` listens to the shared `DcbEventLog` event topic,
collects outbound items (TODO list), and calls an external service for each one.
The translate function may optionally return a command to publish back into the
system, closing the loop.

Replaces fire-and-forget `SideEffectHandler` with tracked, retryable external calls.

```
Event(s) -> TODO List (read model) -> Translator -> External Service
                                                  -> Command (optional)
```

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

  /** The outbound item state -- what data is accumulated for each pending external call. Must carry `@schema`. */
  @schema
  type outboundItem

  /** The command type optionally produced after a successful translate call. Must carry `@schema`. */
  @schema
  type inboundCommand

  /**
  Collect: map an incoming event to zero or more new outbound items.
  Each item has an `id` (deduplication key) and the `outboundItem` payload.
  Returns empty array if this event is not relevant.
  */
  let collect: consumedEvent => array<(string, outboundItem)>

  /**
  Translate: call the external service for a single outbound item.
  Returns:
  - `Ok(Some((targetId, cmd)))` to publish a command back into the system
  - `Ok(None)` for fire-and-forget (no command back)
  - `Error(msg)` on failure (item will be retried up to maxRetries)
  */
  let translate: (string, outboundItem) => promise<result<option<(string, inboundCommand)>, string>>

  /** Maximum number of retries for a failed translate attempt. */
  let maxRetries: int

  /** Heartbeat interval in seconds for sweeping pending/failed items. */
  let heartbeatInterval: int
}
