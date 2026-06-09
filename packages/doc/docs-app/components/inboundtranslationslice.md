---
title: InboundTranslationSlice
date: 2026-03-03
draft: false
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

External -> InboundSlice: "external input (webhook/API)" { class: command-flow }
InboundSlice -> AuditQueryDb: audit log { class: projection-flow }
InboundSlice -> CommandTopic: commands { class: command-flow }
CommandTopic -> StateChangeSlice: commands { class: command-flow }
StateChangeSlice -> DcbEventLog: append { class: event-flow }
```

The **InboundTranslationSlice** implements the Event Modeling **Translation** pattern for inbound external communication. It receives external input (webhooks, API calls, message queue messages), validates and transforms it through an anti-corruption layer, and publishes domain commands.

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
| **Trigger** | S3 object / schedule | HTTP webhook / API / message queue |
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
  let name: string
  let moduleUrl: string

  @schema type externalInput
  @schema type command

  let targetName: string
  let commandAuthorization: command => Authorization.permission
}
```

`translate` lives on the `Translation` module.
There is no `DcbEventLogSpec` reference. `@@reventless.spec` injects `name`,
`moduleUrl`, and a default `commandAuthorization` (`AllowAuthenticated`).

### Spec Fields Explained

| Field | Type | Description |
|-------|------|-------------|
| `externalInput` | `@schema type` | The external data format received from the outside world |
| `command` | `@schema type` | The domain command produced by the anti-corruption layer |
| `targetName` | `string` | Name of the aggregate or StateChangeSlice that receives the produced command |

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
`moduleUrl` from the filename; inside a `*Slice/` folder it auto-applies DCB tags
to `*Id` fields — never write `@s.matches(...)` by hand:

```rescript title="Payment/InboundTranslationSlice/PaymentWebhook.res" showLineNumbers
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

```rescript title="Payment/InboundTranslationSlice/PaymentWebhook_Translation.res" showLineNumbers
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

```rescript title="Shipping/InboundTranslationSlice/ShippingUpdate.res" showLineNumbers
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

```rescript title="Shipping/InboundTranslationSlice/ShippingUpdate_Translation.res" showLineNumbers
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
scans the `InboundTranslationSlice/` folder and emits the wiring into the
**generated** `Plugin.res` using the two-arg factory
`Platform.InboundTranslationSlice.Make(Spec, Translation)`:

```rescript title="src/Plugin.res (generated — do not edit)"
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // InboundTranslationSlices
  module PaymentWebhookSlice = Platform.InboundTranslationSlice.Make(PaymentWebhook, PaymentWebhook_Translation)
  module ShippingUpdateSlice = Platform.InboundTranslationSlice.Make(ShippingUpdate, ShippingUpdate_Translation)

  let make = (~uiBundleUrl=?) =>
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
Endpoint: API Endpoint { class: api }
InboundSlice: InboundTranslationSlice { class: automation-slice }
AuditLog: Audit Log { class: query-db }
CommandTopic: Command Topic { class: command-topic }

External -> Endpoint: "POST webhook payload"
Endpoint -> InboundSlice: "receive(inputJson)"
InboundSlice -> InboundSlice: "Parse with externalInputSchema"
InboundSlice -> InboundSlice: "Spec.translate(input)"
InboundSlice -> CommandTopic: "publishJsons(command)" { class: command-flow }
InboundSlice -> AuditLog: "record success" { class: projection-flow }
InboundSlice -> Endpoint: "Ok(targetId)"
Endpoint -> External: "200 OK"
```

**Receive processing steps:**

```
receive(inputJson):
  1. Parse inputJson against Spec.externalInputSchema
     -> Error: record audit failure, return Error(msg)

  2. Call Spec.translate(input) -- anti-corruption layer
     -> Error(msg): record audit failure, return Error(msg)

  3. Encode command via Spec.commandSchema
     -> Error: record audit failure, return Error(msg)

  4. Publish command via publishJsons
     -> Error: record audit failure, return Error(msg)

  5. Record audit success, return Ok(targetId)
```

### Integration: Exposing the Endpoint

The InboundTranslationSlice exposes `operations.receive` which accepts `JSON.t` and returns `promise<result<string, string>>`. You need to wire this to an HTTP endpoint:

**Option A -- GraphQL Mutation** (consistent with existing Api component):

```rescript
// Register a GraphQL mutation resolver that calls operations.receive
let resolver = async (inputJson) => {
  switch await inboundSliceOps.receive(inputJson) {
  | Ok(targetId) => {success: true, targetId}
  | Error(msg) => {success: false, error: msg}
  }
}
```

**Option B -- Lambda Function URL / API Gateway** (for external webhooks):

```rescript
// Lambda handler that accepts webhook POST body
let handler = async (event) => {
  let body = event.body->JSON.parseExn
  switch await inboundSliceOps.receive(body) {
  | Ok(_) => {statusCode: 200, body: "OK"}
  | Error(msg) => {statusCode: 400, body: msg}
  }
}
```

Both options can coexist -- the component exposes `operations.receive` and the transport layer is up to you.

## Audit Log

All translation attempts are recorded in a QueryDb for observability:

```rescript
type auditStatus = Success | Failure

type auditRow = {
  input: JSON.t,
  status: auditStatus,
  targetId?: string,
  error?: string,
  receivedAt: string,
}
```

The audit log records every call to `receive`, whether successful or not, providing a complete history of all external input processed by the slice.

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
  receive: JSON.t => promise<result<string, string>>,
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
- **[DcbEventLog](./dcbeventlog.md)** -- Shared event log that receives events from processed commands
- **[CommandTopic](./commandtopic.md)** -- Receives commands from the translator
- **[QueryDb](./querydb.md)** -- Stores the audit log
- **[Task](./task.md)** -- Alternative for S3/schedule-triggered external processing
- **[Plugin](./plugin.md)** -- Hosts InboundTranslationSlice via DcbSpec
