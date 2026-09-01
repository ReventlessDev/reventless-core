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

// `~capabilities` is ignored here: this slice calls a service the framework
// does not broker. A geocoding slice would use `capabilities.geocode`.
let translate = async (_id, item, ~capabilities as _) => {
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

  /**
  Event sources this slice subscribes to, by topic key.

  `[]` — the default and the historical behaviour — means this plugin's own DCB
  event log. Naming sources explicitly subscribes to them instead: an Aggregate's
  `Spec.name`, or a DCB source name (conventionally `"<pluginName>DcbEventLog"`),
  matching the keys `AutomationSlice` mappings already use.

  This exists because an outbound slice is the framework's one component for
  *calling an external service and feeding the answer back*, and that job is not
  specific to DCB-modelled entities. An Aggregate whose events should trigger an
  outbound call had no route to one while this list was hard-wired.

  Unlike `AutomationSlice`, the sources are a flat list rather than per-source
  `Mapping` modules. An automation needs a `resolve` per source (a different
  event completes the item depending on where it came from); an outbound item is
  resolved by its own `translate` succeeding, so the only thing that varies per
  source is the decode — and the one `consumedEvent` union already covers that.
  The cost of the flat form is that two sources sharing an event-type name are
  indistinguishable; declare only the sources whose events you mean.
  */
  let sourceNames: array<string>

  /** Optional display name of the foreign system this anti-corruption slice publishes
      to (e.g. `"EmailService"`). Drives the **external box** drawn outside the plugin
      in the Event Graph / Context Map.
      Auto-injected by `@@reventless.spec` defaulting to `None` — set it to name the box. */
  let externalSystem: option<string>

  /**
  The platform capabilities this slice's `translate` reaches for.

  `[]` — the common case — means `translate` calls a service the framework does
  not broker, and the deployment provisions nothing on its behalf. Naming a
  capability makes the need a checked fact: it reaches `capabilities.json`, the
  platform's generated capability list, and the deploy-time gate, which refuses a
  plugin whose platform provisions none of it.

  Declared rather than inferred because what `translate` reads off
  `Capabilities.t` is only visible in its body, and provisioning infrastructure
  from a guess at a function body is not a service. A trait exports the value for
  its host to name, so grafting one cannot leave the need unstated.
  */
  let capabilityNeeds: array<CapabilityNeed.t>

  /** The domain traits grafted into this component, as values the trait packages
      export — `[TraitAttachments.Attachments.declaration]`. Auto-injected as `[]`
      by `@@reventless.spec`, so a component that is nobody's graft says so without
      a line. A graft names its trait here and the structure records it, which is
      the only way a deployed plugin can answer "where did this come from". See
      `Trait`. */
  let traits: array<Trait.t>
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

  `~sourceId` is the id of the entity the event was published for — the envelope's
  `id`, not part of the event payload. A DCB event usually names its own subject
  in the payload (`OrderPlaced({orderId, …})`) and can ignore this; an Aggregate's
  event generally does not, because the aggregate id is what addressed it in the
  first place. Without this the outbound item for `Registered({email, address})`
  would have no way to say *which customer* it is for.
  */
  let collect: (Spec.consumedEvent, ~sourceId: string) => array<(string, Spec.outboundItem)>

  /**
  Translate: call the external service for a single outbound item.
  Returns:
  - `Ok(Some((targetId, cmd)))` to publish a command back into the system
  - `Ok(None)` for fire-and-forget (no command back)
  - `Error(msg)` on failure (item will be retried up to maxRetries)

  `~capabilities` carries what the platform provisioned — a geocoder today. It is
  how a provider-agnostic plugin reaches a provider-specific service without
  naming one: the deployment decides what is behind `capabilities.geocode`, and
  the call site does not change when that answer does. A slice calling a service
  the framework knows nothing about still reaches it directly and simply ignores
  this argument.
  */
  let translate: (string, Spec.outboundItem, ~capabilities: Capabilities.t) => promise<
    result<option<(string, Spec.inboundCommand)>, string>,
  >

  /**
  The retry budget is spent: this item will never be attempted again.

  Return `Some((targetId, cmd))` to tell the domain, or `None` to say nothing.
  `~lastError` is the failure that ended it.

  Abandonment is an outcome, not the absence of one, and the framework cannot
  publish it on a slice's behalf: the event would need a home in some aggregate's
  log, and which aggregate is exactly what this module knows and the framework
  does not. So the choice is declared here even when the answer is `None` —
  a slice that stays silent says so on purpose.

  The row is marked `Abandoned` either way; this decides only whether anything
  downstream hears about it.
  */
  let onExhausted: (string, Spec.outboundItem, ~lastError: option<string>) => option<
    (string, Spec.inboundCommand),
  >

  /** File URL of this Translation module (`import.meta.url`). */
  let moduleUrl: string
}

