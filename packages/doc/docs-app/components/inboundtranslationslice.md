---
title: InboundTranslationSlice
---

For a short summary of InboundTranslationSlice, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`InboundTranslationSlice.res`), builder logic (`InboundTranslationSlice_Builder.res`), and callback/handler logic (`InboundTranslationSlice_Callback.res`).
:::

## Overview

```d2
External: External System { class: external-system }
InboundSlice: InboundTranslationSlice { class: automation-slice }
AuditQueryDb: Audit Log QueryDb { class: query-db }
CommandTopic: Command Topic { class: command-topic }
StateChangeSlice: StateChangeSlice { class: state-change-slice }
DcbEventLog: DcbEventLog { class: dcb-event-log }

External -> InboundSlice: "external input (GraphQL mutation)" { class: command-flow }
InboundSlice -> AuditQueryDb: audit log { class: projection-flow }
InboundSlice -> CommandTopic: commands { class: command-flow }
CommandTopic -> StateChangeSlice: commands { class: command-flow }
StateChangeSlice -> DcbEventLog: append { class: event-flow }
```

The **InboundTranslationSlice** implements the Event Modeling **Translation** pattern for inbound external communication. It receives external input in the sender's vocabulary, validates and transforms it through an anti-corruption layer, and publishes domain commands. The framework gives it a [generated GraphQL mutation](#integration-the-generated-mutation) as its door, and, when its spec asks for one, a [webhook URL](#a-webhook-url) beside it.

## Event Modeling: The Inbound Translation Pattern

In Event Modeling, an **Inbound Translation** handles communication from external services into the system:

```
External Input --> Anti-Corruption Layer (translate) --> Command --> Event(s)
```

The anti-corruption layer protects the domain from external data formats and validates input before it enters the system.

## Purpose and Responsibilities

- **Responsibility**: Receive external input; validate against a schema; translate to domain commands via an anti-corruption layer; publish commands to the shared CommandTopic; maintain an audit log of all translation attempts
- **In**: External JSON input (via `operations.receive`)
- **Out**: Commands to CommandTopic (via `publishJsons`); audit records to QueryDb
- **Key Feature**: Unlike other slices, InboundTranslationSlice is triggered externally via `operations.receive` rather than by subscribing to domain events

## Comparison with Task

| Aspect | Task | InboundTranslationSlice |
|--------|------|--------------------------|
| **Trigger** | S3 object / schedule | A call to the slice's generated GraphQL mutation |
| **Input validation** | None -- raw JSON | Anti-corruption layer with schema validation |
| **Translation** | Ad-hoc | Structured `translate` function with typed input/output |
| **Error handling** | Lambda error | Structured error response to caller |
| **Observability** | CloudWatch only | QueryDb audit log of all translations |

**Choose Task** when you need S3 triggers, scheduled jobs, or provider-specific integrations.

**Choose InboundTranslationSlice** when you need validated, audited external input processing with a clean anti-corruption layer.

## Component Spec

An InboundTranslationSlice is **split into two files**:

- `<Name>.res` — the **spec** (`@@reventless.spec`): the `externalInput` and
  `command` `@schema` types, plus `targetName` (the aggregate or StateChangeSlice
  that receives the produced command).
- `<Name>_Translation.res` — the **translation** (`@@reventless.translation`): the
  synchronous `translate` function (the anti-corruption layer).

The spec module type the framework expects:

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  @schema type externalInput
  @schema type command

  let targetName: string
  type role
  let authorizationOf: string => Authorization.rule<role>
  let endpoint: option<endpointConfig<role>>
}
```

`translate` lives on the `Translation` module.
There is no `DcbEventLogSpec` reference. `@@reventless.spec` injects `name`,
`moduleUrl`, a default `authorizationOf` (`AllowAuthenticated`), `let endpoint = None`
when the spec declares no [webhook URL](#a-webhook-url), and `type role`, the plugin's `Roles.t` when it declares one (see
[Authorization](../authorization.md#roles-and-groups)).

### Spec Fields Explained

| Field | Type | Description |
|-------|------|-------------|
| `externalInput` | `@schema type` | The external data format received from the outside world |
| `command` | `@schema type` | The domain command produced by the anti-corruption layer |
| `targetName` | `string` | Name of the aggregate or StateChangeSlice that receives the produced command |
| `endpoint` | `option<endpointConfig<role>>` | The slice's [webhook URL](#a-webhook-url), if it has one |

### The translate Function

The `translate` function lives in the `_Translation.res` file and is the
**anti-corruption layer** -- it protects the domain from external data formats. It
returns `result<array<(string, command)>, string>`:

- **`Ok([(targetId, command), ...])`** -- Input is valid; publish one or more commands to the target entities
- **`Ok([])`** -- Idempotent no-op; nothing to publish
- **`Error(msg)`** -- Input is invalid or cannot be translated; return error to caller

The function is **synchronous** (no external calls needed) since all the external interaction already happened when the input was received.

## Usage Pattern

### Example 1: Payment Webhook

The **spec file**. `@@reventless.spec` injects `name`, `module Id`, and
`moduleUrl` from the filename; inside a slice folder it auto-applies DCB tags
to `*Id` fields — never write `@s.matches(...)` by hand:

```rescript title="Payment/InboundTranslation/PaymentWebhook.res" showLineNumbers
@@reventless.spec

@schema
type externalInput = {
  paymentId: string,
  orderId: string,
  status: string,
  amount: float,
}

@schema
type command = ConfirmPayment({
  orderId: string,
  paymentId: string,
  amount: float,
})

let targetName = "ConfirmPayment"
```

The **translation file** (`@@reventless.translation`) holds the synchronous
`translate`, returning an array of `(targetId, command)` pairs:

```rescript title="Payment/InboundTranslation/PaymentWebhook_Translation.res" showLineNumbers
@@reventless.translation

let translate = (input: externalInput) =>
  switch input.status {
  | "completed" =>
    Ok([
      (
        input.orderId,
        ConfirmPayment({
          orderId: input.orderId,
          paymentId: input.paymentId,
          amount: input.amount,
        }),
      ),
    ])
  | "refunded" =>
    // Could map to a different command variant
    Error("Refund handling not yet implemented")
  | status => Error("Unknown payment status: " ++ status)
  }
```

### Example 2: Shipping Update Webhook

```rescript title="Shipping/InboundTranslation/ShippingUpdate.res" showLineNumbers
@@reventless.spec

@schema
type externalInput = {
  trackingId: string,
  orderId: string,
  event: string,
  timestamp: string,
}

@schema
type command = UpdateShipmentStatus({
  orderId: string,
  trackingId: string,
  status: string,
})

let targetName = "UpdateShipmentStatus"
```

```rescript title="Shipping/InboundTranslation/ShippingUpdate_Translation.res" showLineNumbers
@@reventless.translation

let translate = (input: externalInput) =>
  switch input.event {
  | "picked_up" | "in_transit" | "delivered" =>
    Ok([
      (
        input.orderId,
        UpdateShipmentStatus({
          orderId: input.orderId,
          trackingId: input.trackingId,
          status: input.event,
        }),
      ),
    ])
  | event => Error("Unrecognized shipping event: " ++ event)
  }
```

### Plugin Wiring

You never register or wire InboundTranslationSlices by hand. The plugin generator
scans the `InboundTranslation/` folder and emits the wiring into the
**generated** `Plugin.res` using the two-arg factory
`Platform.InboundTranslationSlice.Make(Spec, Translation)`:

```rescript title="src/Plugin.res (generated — do not edit)"
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // InboundTranslationSlices
  module PaymentWebhookSlice = Platform.InboundTranslationSlice.Make(PaymentWebhook, PaymentWebhook_Translation)
  module ShippingUpdateSlice = Platform.InboundTranslationSlice.Make(ShippingUpdate, ShippingUpdate_Translation)

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~inboundTranslationSlices=[module(PaymentWebhookSlice), module(ShippingUpdateSlice)],
      // ... other components
    )
}
```

## Runtime Behavior

### Receive Flow

Unlike other slices, InboundTranslationSlice is triggered externally via `operations.receive`:

```d2
shape: sequence_diagram

External: External System { class: external-system }
Endpoint: "GraphQL mutation (Plugin_Slice)" { class: api }
InboundSlice: InboundTranslationSlice { class: automation-slice }
AuditLog: Audit Log { class: query-db }
CommandTopic: Command Topic { class: command-topic }

External -> Endpoint: "call with externalInput fields"
Endpoint -> InboundSlice: "receive(inputJson)"
InboundSlice -> InboundSlice: "Parse with externalInputSchema"
InboundSlice -> InboundSlice: "Translation.translate(input)"
InboundSlice -> CommandTopic: "publishJsons(command)" { class: command-flow }
InboundSlice -> AuditLog: "record success" { class: projection-flow }
InboundSlice -> Endpoint: "Ok(acceptedResult)"
Endpoint -> External: "CommandResult"
```

**Receive processing steps:**

```
receive(inputJson):
  1. Parse inputJson against Spec.externalInputSchema
     -> Error: record audit failure, return Error(msg)

  2. Call Translation.translate(input) -- anti-corruption layer
     -> Error(msg): record audit failure, return Error(msg)

  3. Encode command via Spec.commandSchema
     -> Error: record audit failure, return Error(msg)

  4. Publish command via publishJsons
     -> Error: record audit failure, return Error(msg)

  5. Record audit success, return Ok(acceptedResult)
```

### Integration: The Generated Mutation

You do not wire a transport. Declaring the slice declares a GraphQL mutation, and
both platforms create it for you:

| Platform | What is created |
|----------|-----------------|
| AWS | An AppSync DataSource + Resolver per slice, pointing at the shared DCB CommandTopic Lambda. The request template carries `__inboundTranslation: true`, which routes the invocation to the slice's `receive` instead of the regular SQS command path. |
| Local | The mutation field registered on the local GraphQL server. Registration is two-phase, so a caller can invoke `receive` before the deploy-time `Output` resolves — early calls park in a queue and drain once the real `receive` is bound. |

The field is named `<Plugin>_<Slice>`, its arguments come from `@schema type
externalInput` (**not** the internal `command`), and it returns `CommandResult`.
For the `PaymentWebhook` slice above, in a plugin named `Ordering`:

```graphql
Ordering_PaymentWebhook(amount: Float!, orderId: ID!, paymentId: ID!, status: String!): CommandResult!
```

Arguments are emitted alphabetically, and `orderId` / `paymentId` render as `ID!`
because the PPX auto-tags `*Id` fields inside a slice folder. See the
[GraphQL API guide](../graphql-api-guide.md#53-from-an-inboundtranslation)
for the full mapping.

There is no opt-out. Unlike a StateChangeSlice command, an inbound slice honors
no `@noApi` — every declared slice gets its mutation.

The field answers under the slice's `authorizationOf`, which defaults to
`AllowAuthenticated` (see [Authorization](../authorization.md)). A caller that
must reach it without signing in needs `AllowAnonymous` written on the spec.

### A webhook URL

A sender that can only post JSON to an address — a payment provider, a carrier —
does not speak GraphQL and cannot sign in. For it, the spec declares an endpoint,
and the slice gets a URL **beside** its mutation. Both doors lead to the same
`receive`, so the same input produces the same commands whichever way it came.

```rescript title="Product/InboundTranslation/ImportProduct.res"
@@reventless.spec
@@reventless.authorize(AllowRoles([Admin]))

// … externalInput, command, targetName …

let endpoint = Some({
  Reventless.InboundTranslationSlice.path: "supplier-feed",
  auth: SignedBody({
    header: "X-Signature-256",
    prefix: "sha256=",
    timestampHeader: "X-Signature-Timestamp",
    secret: "supplierFeed",
  }),
  role: Roles.Admin,
})
```

| Field | Meaning |
|-------|---------|
| `path` | The slice's segment under the plugin's webhook base URL |
| `method` | `Post` (the default) or `Put` |
| `auth` | Who may call: `SignedBody(signature)` or `Open` — required, so the choice is always written down |
| `role` | The role a request that passes `auth` acts as; none when absent |
| `transport` | `FunctionUrl`, the default and, for now, the only one |

#### Signed requests

`SignedBody` is what webhook providers do: the sender computes an HMAC-SHA256 of
the raw body with a secret you share, hex-encodes it and sends it in `header`,
after `prefix` if there is one. With `timestampHeader` the signed text is
`<timestamp>.<body>`, the timestamp in seconds, and a request more than
`toleranceSeconds` (default 300) from now is refused, so a captured request cannot
be replayed later. The check runs on the bytes as sent, before the body is parsed.

`secret` names the secret; its value never appears in source. The platform reads it
from `REVENTLESS_WEBHOOK_SECRET_<SECRET>` — the name upper-cased, other characters
as `_`. That variable may list several, comma-separated: while you rotate, put the
new and the old one there, and either passes.

- **AWS:** set it in the plugin stack's config, `pulumi config set --secret
  webhook:supplierFeed <value>`. The deploy (and `pulumi preview`) fails while it
  is missing.
- **Locally:** export `REVENTLESS_WEBHOOK_SECRET_SUPPLIERFEED` before you start.

A request the platform has no secret for is answered `500` and logged; it is never
treated as open.

#### Who the request acts as

A signed request acts as a signed-in caller holding the endpoint's `role`. Each
command its input translates into is then checked against that command's own rule,
exactly as on the mutation, and one refused refuses the whole input. An `Open` URL
identifies nobody: it acts as an anonymous caller, so only commands written
`AllowAnonymous` get through it. Every request to an open URL still runs the
handler and writes an audit row, so an open URL costs you for every stranger's
request.

**The signature protects the URL, not the mutation.** If the commands keep the
default `AllowAuthenticated`, any signed-in user can send a forged input through
the mutation. Give the commands a rule that admits only the sender's role, as the
example does with `Admin`, so the mutation becomes an operator's replay door. Or
withhold the mutation altogether.

#### A webhook-only slice

`@noApi` on `externalInput` withholds the mutation, which leaves the URL as the
slice's only door:

```rescript
@noApi @schema
type externalInput = {paymentId: string, status: string}
```

| | no `endpoint` | `endpoint` declared |
|---|---|---|
| **default** | mutation only | mutation and URL |
| **`@noApi`** | refused at build — nothing could reach it | URL only |

#### Where the URL is

**On AWS** the plugin's command handler gets one public Lambda Function URL, and
each slice's endpoint is its `path` under it. Read it in the plugin's deploy
program after `deployPlugin`, to export it and register it with the sender:

```rescript
let webhookUrl = Platform.webhookUrl() // "" when no slice declares an endpoint
```

**Locally** there is no HTTP server. The routes live in `LocalWebhookRegistry`, and
a test posts the raw body through the same signature check and dispatch:

```rescript
let response = await LocalWebhookRegistry.post(~path="supplier-feed", ~headers, body)
```

#### Responses

The status tells a sender whether to try again: `2xx` done, `5xx` try again, any
other `4xx` do not.

| Status | When |
|--------|------|
| `200` | Translated and published, `{requestId, commandCount}` |
| `400` | The body is not JSON |
| `401` | The signature is missing, wrong, or outside the time window |
| `403` | The endpoint's role may not send a command the input translates into |
| `404` / `405` | No slice at that path / the wrong method |
| `422` | The input was refused: by its schema or by `translate` |
| `500` | The secret is not configured |
| `503` | The commands could not be published |

Every answer from `400` to `422`, and `503`, writes an audit row first; `404`, `405`
and `500` do not, because no slice was reached or no secret was there to check with.

## Audit Log

All translation attempts are recorded in a QueryDb for observability:

```rescript
type auditStatus = Success | Failure
type door = Mutation | Webhook

type auditRow = {
  input: string,
  status: auditStatus,
  targetIds?: array<string>,
  commandCount?: int,
  error?: string,
  receivedAt: string,
  door?: door,
}
```

The audit log records every input, whether successful or not, providing a complete
history of all external input processed by the slice. `door` says which way it
came in, so the log can answer "did the provider actually call us?"; it is absent
on rows written before the slice had a second door. A webhook request refused
before it could be read keeps its raw body as `input`.

## Error Handling

**Input Parsing Errors:**
- Invalid JSON or schema mismatch returns `Error` to the caller
- Audit log records the failure with the raw input

**Translation Errors:**
- `translate` returning `Error(msg)` is the normal rejection path (e.g., unknown status code)
- Audit log records the failure with the parsed input

**Publishing Errors:**
- Command encoding failures return `Error` to the caller
- `publishJsons` failures return `Error` to the caller
- Audit log records the failure

**All errors** are returned to the caller as `Error(msg)`, allowing the external system to retry or handle the failure.

## Pulumi Outputs

```rescript
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
}

type operations = {
  receive: (JSON.t, ~caller: Identity.t=?, ~door: door=?) => promise<receiveResult>,
  refuse: (~body: string, ~errorCode: string, string) => promise<receiveResult>,
}
```

**Resource Naming:**
- Component type: `reventless:InboundTranslationSlice`
- Audit log QueryDb: `{name}Audit`

**Dependencies:**
- CommandTopic (via `publishJsons` for command publishing)
- QueryDb (for audit log persistence)

## Related Components

- **[OutboundTranslationSlice](./outboundtranslationslice.md)** -- Complementary component for calling external services
- **[StateChangeSlice](./statechangeslice.md)** -- Processes the commands InboundTranslationSlice produces
- **[DcbEventLog](/framework/runtime-components/dcbeventlog)** -- Shared event log that receives events from processed commands
- **[CommandTopic](/framework/runtime-components/commandtopic)** -- Receives commands from the translator
- **[QueryDb](/framework/runtime-components/querydb)** -- Stores the audit log
- **[Task](./task.md)** -- Alternative for S3/schedule-triggered external processing
- **[Plugin](./plugin.md)** -- Hosts InboundTranslationSlice via DcbSpec
