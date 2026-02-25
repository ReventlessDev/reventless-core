---
title: SideEffectHandler
date: 2026-01-26
draft: false
---

For a short summary of SideEffectHandler, see [Reventless Components Overview.](../component-overview.md#sideeffecthandler)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`SideEffectHandler.res`](../../reventless/src/components/SideEffectHandler/SideEffectHandler.res)), builder logic ([`SideEffectHandler_Builder.res`](../../reventless/src/components/SideEffectHandler/SideEffectHandler_Builder.res)), and runtime callbacks ([`SideEffectHandler_Callback.res`](../../reventless/src/components/SideEffectHandler/SideEffectHandler_Callback.res)).
:::

## Overview

```d2
Aggregate: Aggregate { class: aggregate }
EventTopic: Event Topic { class: event-topic }
SideEffectHandler: Side Effect Handler { class: side-effect }
ExternalSystem: External System { class: external-system }
Email: Email Service { class: external-system }
Webhook: Webhook { class: external-system }

Aggregate -> EventTopic: events { class: event-flow }
EventTopic -> SideEffectHandler: events { class: event-flow }
SideEffectHandler -> ExternalSystem: API calls
SideEffectHandler -> Email: notifications
SideEffectHandler -> Webhook: webhooks
```

The **SideEffectHandler** enables event-driven integration with external systems by executing side effects in response to domain events. Unlike EventMapper (which generates commands), SideEffectHandler performs actions that don't affect aggregate state—such as sending emails, calling external APIs, or triggering webhooks.

## Purpose and Responsibilities

- **Responsibility**: Listen to events from source aggregates; execute side effects (external API calls, notifications, etc.); provide scheduling capabilities for delayed/recurring side effects; integrate with external systems without affecting domain state
- **In**: Events from source EventTopics (via EventCollector)
- **Out**: External API calls, notifications, webhooks, scheduled tasks

## SideEffect Spec

Each side effect is defined by implementing the `SideEffect.T` module type:

```rescript
module type Source = {
  let name: string
  module Id: Id.T
  @schema
  type event
}

module type T = {
  module Source: Source
  let execute: (
    Source.Id.t,                    // Source aggregate ID
    Message.meta,                   // Event metadata
    Source.event,                   // The event
    QueryEngine.operations,         // Query operations
  ) => promise<unit>
}
```

## Usage Pattern

### Defining a SideEffect

```rescript title="Customer_EmailNotification.res"
module Source = Customer

let execute = async (customerId, meta, event, queryEngine) =>
  switch event {
  | Customer.Created({name, email}) => {
      // Send welcome email
      await EmailService.send({
        to: email,
        subject: "Welcome!",
        body: `Hello ${name}, welcome to our service!`,
      })
      Js.log(`Sent welcome email to ${email}`)
    }
  | Customer.AddressChanged(newAddress) => {
      // Query customer data for email
      let customer = await queryEngine.get(
        ~table="CustomerReadModel",
        ~id=customerId->Customer.Id.toString,
      )
      switch customer {
      | Some({email}) =>
        await EmailService.send({
          to: email,
          subject: "Address Updated",
          body: `Your address has been updated to: ${newAddress}`,
        })
      | None => ()
      }
    }
  | Customer.Deleted => {
      // Send goodbye email
      let customer = await queryEngine.get(
        ~table="CustomerReadModel",
        ~id=customerId->Customer.Id.toString,
      )
      switch customer {
      | Some({email}) =>
        await EmailService.send({
          to: email,
          subject: "Account Deleted",
          body: "Your account has been deleted. We're sorry to see you go!",
        })
      | None => ()
      }
    }
  | _ => ()
  }
```

### Registering SideEffects

```rescript title="SideEffects.res"
// Collect all side effects for the application
let sideEffects: SideEffectHandler.sideEffects = [
  module(Customer_EmailNotification),
  module(Order_WebhookNotification),
  module(Invoice_PDFGenerator),
]
```

### Creating the SideEffectHandler

```rescript title="Plugin.res"
let sideEffectHandler = SideEffectHandler.make(
  ~name="NotificationHandler",
  ~sideEffects=SideEffects.sideEffects,
  ~allEventTopics,
  ~allCommandTopics,
  ~queryEngine,
  ~scheduler,
  ~opts=pulumiOptions,
)
```

## Runtime Behavior

### Event Processing Sequence

```d2
shape: sequence_diagram

Aggregate: Aggregate { class: aggregate }
EventTopic: Event Topic { class: event-topic }
EventCollector: Event Collector { class: event-collector }
SideEffectHandler: Side Effect Handler
SideEffect: Side Effect { class: side-effect }
External: External System { class: external-system }

Aggregate -> EventTopic: publish event
EventTopic -> EventCollector: deliver event
EventCollector -> SideEffectHandler: "eventsHandler(events)"
SideEffectHandler -> SideEffectHandler: Find matching SideEffect
SideEffectHandler -> SideEffectHandler: Decode event
SideEffectHandler -> SideEffect: "execute(id, meta, event, queryEngine)"
SideEffect -> External: API call / notification
External --> SideEffect: response
SideEffect --> SideEffectHandler: Ok
```

### Event Matching

The SideEffectHandler matches events to side effects based on the source aggregate name:

```rescript
// For each incoming event:
// 1. Extract event metadata
let eventMeta = event.meta

// 2. Find matching side effect by source name
let sideEffect = sideEffects->Array.find(
  (module(SideEffect)) => SideEffect.Source.name == eventMeta.service
)

// 3. Execute if found
switch sideEffect {
| Some(sideEffect) => 
    await SideEffect.execute(id, meta, event, queryEngine)
| None => () // No matching side effect
}
```

## Integration Points

### With EventCollector

The SideEffectHandler uses an EventCollector to subscribe to source EventTopics:

```d2
EventTopic1: Customer Events { class: event-topic }
EventTopic2: Order Events { class: event-topic }

SideEffectHandlerComponent: SideEffectHandler Component {
  class: side-effects-area
  EventCollector: Event Collector { class: event-collector }
  SideEffects: Side Effects { class: side-effect }
}

External1: Email Service { class: external-system }
External2: Webhook { class: external-system }
External3: PDF Generator { class: external-system }

EventTopic1 -> SideEffectHandlerComponent.EventCollector
EventTopic2 -> SideEffectHandlerComponent.EventCollector
SideEffectHandlerComponent.EventCollector -> SideEffectHandlerComponent.SideEffects
SideEffectHandlerComponent.SideEffects -> External1
SideEffectHandlerComponent.SideEffects -> External2
SideEffectHandlerComponent.SideEffects -> External3
```

### With Scheduler

The SideEffectHandler provides scheduling operations for delayed or recurring side effects:

```rescript
type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  createSchedule: Schedule.create,
  deleteSchedule: Schedule.delete,
}
```

#### Schedule Types

```rescript
type rate =
  | Single(year, month, day, hour, minute)  // One-time execution
  | Minutes(int)                             // Every N minutes
  | Hours(int)                               // Every N hours
  | Days(int)                                // Every N days
  | Daily(hour, minute)                      // Daily at specific time
  | Weekdays(hour, minute)                   // Weekdays at specific time
  | WeekdaysAndSaturday(hour, minute)        // Weekdays + Saturday
```

#### Creating Schedules

```rescript
// Schedule a daily report
await sideEffectHandler.operations.createSchedule({
  name: "daily-report",
  rate: Daily(9, 0),  // 9:00 AM daily
  payload: "generate-daily-report",
})

// Schedule a one-time reminder
await sideEffectHandler.operations.createSchedule({
  name: "reminder-123",
  rate: Single(2026, 1, 30, 14, 0),  // Jan 30, 2026 at 2:00 PM
  payload: "send-reminder-123",
})

// Delete a schedule
await sideEffectHandler.operations.deleteSchedule("reminder-123")
```

## Common Patterns

### Email Notifications

```rescript title="Order_EmailNotification.res"
module Source = Order

let execute = async (orderId, meta, event, queryEngine) =>
  switch event {
  | Order.Created({customerId, items}) => {
      let customer = await queryEngine.get(
        ~table="CustomerReadModel",
        ~id=customerId,
      )
      switch customer {
      | Some({email, name}) =>
        await EmailService.send({
          to: email,
          subject: "Order Confirmation",
          body: `Hi ${name}, your order #${orderId} has been received!`,
        })
      | None => ()
      }
    }
  | Order.Shipped({trackingNumber}) => {
      let order = await queryEngine.get(
        ~table="OrderReadModel",
        ~id=orderId->Order.Id.toString,
      )
      switch order {
      | Some({customerEmail}) =>
        await EmailService.send({
          to: customerEmail,
          subject: "Order Shipped",
          body: `Your order has shipped! Tracking: ${trackingNumber}`,
        })
      | None => ()
      }
    }
  | _ => ()
  }
```

### Webhook Integration

```rescript title="Order_WebhookNotification.res"
module Source = Order

let execute = async (orderId, meta, event, _queryEngine) =>
  switch event {
  | Order.Created(orderData) =>
    await Webhook.post(
      ~url="https://partner.example.com/orders",
      ~payload={
        "event": "order.created",
        "orderId": orderId->Order.Id.toString,
        "data": orderData,
        "timestamp": meta.time,
      },
    )
  | Order.Completed(completionData) =>
    await Webhook.post(
      ~url="https://partner.example.com/orders",
      ~payload={
        "event": "order.completed",
        "orderId": orderId->Order.Id.toString,
        "data": completionData,
        "timestamp": meta.time,
      },
    )
  | _ => ()
  }
```

### External API Integration

```rescript title="Payment_StripeIntegration.res"
module Source = Payment

let execute = async (paymentId, meta, event, queryEngine) =>
  switch event {
  | Payment.Authorized({amount, customerId}) => {
      let customer = await queryEngine.get(
        ~table="CustomerReadModel",
        ~id=customerId,
      )
      switch customer {
      | Some({stripeCustomerId}) =>
        let _ = await Stripe.charges.create({
          amount: amount,
          currency: "usd",
          customer: stripeCustomerId,
          description: `Payment ${paymentId->Payment.Id.toString}`,
        })
      | None => 
        Js.log(`No Stripe customer for ${customerId}`)
      }
    }
  | Payment.Refunded({amount, reason}) => {
      let payment = await queryEngine.get(
        ~table="PaymentReadModel",
        ~id=paymentId->Payment.Id.toString,
      )
      switch payment {
      | Some({stripeChargeId}) =>
        let _ = await Stripe.refunds.create({
          charge: stripeChargeId,
          amount: amount,
          reason: reason,
        })
      | None => ()
      }
    }
  | _ => ()
  }
```

### PDF Generation

```rescript title="Invoice_PDFGenerator.res"
module Source = Invoice

let execute = async (invoiceId, meta, event, queryEngine) =>
  switch event {
  | Invoice.Generated({items, total, customerId}) => {
      let customer = await queryEngine.get(
        ~table="CustomerReadModel",
        ~id=customerId,
      )
      switch customer {
      | Some({name, address, email}) => {
          // Generate PDF
          let pdf = await PDFService.generate({
            template: "invoice",
            data: {
              invoiceId: invoiceId->Invoice.Id.toString,
              customerName: name,
              customerAddress: address,
              items: items,
              total: total,
              date: meta.time,
            },
          })
          
          // Store PDF
          await S3.putObject({
            bucket: "invoices",
            key: `${invoiceId->Invoice.Id.toString}.pdf`,
            body: pdf,
          })
          
          // Send email with PDF
          await EmailService.sendWithAttachment({
            to: email,
            subject: `Invoice #${invoiceId->Invoice.Id.toString}`,
            body: "Please find your invoice attached.",
            attachment: pdf,
          })
        }
      | None => ()
      }
    }
  | _ => ()
  }
```

### Scheduled Side Effects

```rescript title="Reminder_Scheduler.res"
module Source = Appointment

let execute = async (appointmentId, meta, event, queryEngine) =>
  switch event {
  | Appointment.Scheduled({date, customerId}) => {
      // Schedule reminder 24 hours before
      let reminderDate = date->Date.addDays(-1)
      
      await scheduler.createSchedule({
        name: `reminder-${appointmentId->Appointment.Id.toString}`,
        rate: Single(
          reminderDate->Date.getFullYear,
          reminderDate->Date.getMonth,
          reminderDate->Date.getDate,
          9, 0  // 9:00 AM
        ),
        payload: Js.Json.stringify({
          "type": "appointment-reminder",
          "appointmentId": appointmentId->Appointment.Id.toString,
          "customerId": customerId,
        }),
      })
    }
  | Appointment.Cancelled => {
      // Delete the scheduled reminder
      await scheduler.deleteSchedule(
        `reminder-${appointmentId->Appointment.Id.toString}`
      )
    }
  | _ => ()
  }
```

## Error Handling

The SideEffectHandler includes comprehensive error handling:

**Execution Errors:**
- Side effect execution failures → logged, event processing continues
- External API errors → caught and logged
- Decoding errors → logged with context

**Recovery:**
- Failed events remain in EventCollector queue for retry
- Side effects should be idempotent when possible
- Use event metadata (msgId) for deduplication

```rescript
// Error handling in execute function
let execute = async (id, meta, event, queryEngine) => {
  try {
    await performSideEffect(id, event)
  } catch {
  | err => 
    // Log error but don't throw - allows other events to process
    Js.log2("SideEffect error:", err)
    // Optionally: send to error tracking service
    await ErrorTracking.capture(err, {
      sideEffect: "CustomerEmail",
      eventId: meta.msgId,
      aggregateId: id->Customer.Id.toString,
    })
  }
}
```

## Pulumi

The SideEffectHandler component creates these infrastructure resources:

```rescript
type outputs = {
  name: string,
  eventCollector: EventCollector.outputs,
}

type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  createSchedule: Schedule.create,
  deleteSchedule: Schedule.delete,
}
```

**Resource Naming:**
- Component type: `reventless:SideEffectHandler`
- Resource name pattern: `{name}SideEffectHandler`

**Configuration:**
- `memorySize` - Lambda memory allocation (default: 2048 MB)
- `timeout` - Lambda timeout (default: 180 seconds)
- `targets` - Optional list of CommandTopic targets for permissions

## Best Practices

### Make Side Effects Idempotent

```rescript
// ✅ Good: Check before sending
let execute = async (orderId, meta, event, queryEngine) =>
  switch event {
  | Order.Shipped({trackingNumber}) => {
      // Check if notification already sent
      let notification = await queryEngine.get(
        ~table="NotificationLog",
        ~id=meta.msgId,
      )
      switch notification {
      | Some(_) => 
        Js.log("Notification already sent, skipping")
      | None => {
          await sendNotification(...)
          // Record that notification was sent
          await queryEngine.save(
            ~table="NotificationLog",
            ~id=meta.msgId,
            ~data={sentAt: Date.now()},
          )
        }
      }
    }
  | _ => ()
  }
```

### Handle External Service Failures Gracefully

```rescript
// ✅ Good: Graceful degradation
let execute = async (id, meta, event, queryEngine) =>
  switch event {
  | Order.Created(data) => {
      // Try primary service
      try {
        await PrimaryEmailService.send(...)
      } catch {
      | _ => {
          // Fall back to secondary
          try {
            await SecondaryEmailService.send(...)
          } catch {
          | err => 
            // Log but don't fail the entire handler
            Js.log2("All email services failed:", err)
          }
        }
      }
    }
  | _ => ()
  }
```

### Use QueryEngine for Context

```rescript
// ✅ Good: Enrich side effect with read model data
let execute = async (orderId, meta, event, queryEngine) =>
  switch event {
  | Order.Shipped(_) => {
      // Get full order details from read model
      let order = await queryEngine.get(
        ~table="OrderReadModel",
        ~id=orderId->Order.Id.toString,
      )
      // Get customer details
      let customer = await queryEngine.get(
        ~table="CustomerReadModel",
        ~id=order.customerId,
      )
      // Now have all context for rich notification
      await sendShippingNotification(order, customer)
    }
  | _ => ()
  }
```

### Keep Side Effects Focused

```rescript
// ✅ Good: One responsibility per side effect
module Order_EmailNotification = {
  // Only handles email notifications
}

module Order_WebhookNotification = {
  // Only handles webhooks
}

module Order_AnalyticsTracking = {
  // Only handles analytics
}

// Register all separately
let sideEffects = [
  module(Order_EmailNotification),
  module(Order_WebhookNotification),
  module(Order_AnalyticsTracking),
]
```

## Related Components

- **[EventCollector](./eventcollector.md)** - Subscribes to source EventTopics
- **[EventTopic](./eventtopic.md)** - Source of events for side effects
- **[EventMapper](./eventmapper.md)** - Alternative for generating commands (not side effects)
- **[Scheduler](./scheduler.md)** - Provides scheduling capabilities
- **[QueryDb](./querydb.md)** - Read model access via QueryEngine

## AWS Implementation

For detailed AWS implementation, see SideEffectHandler AWS adapter documentation (TBD).
