---
title: Heartbeat
---

For a short summary of a Heartbeat, see [Reventless Components Overview.](../component-overview.md#heartbeat)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`Heartbeat.res`](../../reventless/src/components/Heartbeat/Heartbeat.res)), builder logic ([`Heartbeat_Builder.res`](../../reventless/src/components/Heartbeat/Heartbeat_Builder.res)), adapter interface ([`Heartbeat_Adapter.res`](../../reventless/src/components/Heartbeat/Heartbeat_Adapter.res)), and callback handlers ([`Heartbeat_Callback.res`](../../reventless/src/components/Heartbeat/Heartbeat_Callback.res)).
:::

## Overview

The Heartbeat component provides periodic health check signals and keepalive mechanisms, specifically designed to integrate with the Core Plugin's ExtensionPoint system. It enables health monitoring, periodic extension invocations, and watchdog timer functionality.

```d2
CloudWatch: CloudWatch Events { class: aws-service }
Lambda: Lambda Function { class: aws-service }
CoreSQS: Core Plugin SQS { class: plugin }
ExtensionPoint: Extension Point { class: extension-point }
Extensions: Extensions { class: extension }

CloudWatch -> Lambda: triggers
Lambda -> CoreSQS: heartbeat message
CoreSQS -> ExtensionPoint: processes
ExtensionPoint -> Extensions: invokes
```

## Purpose and Responsibilities

- **Responsibility:** Generate periodic heartbeat signals for health monitoring and extension triggering
- **In:** Timeout configuration and Core Plugin connection details
- **Out:** Periodic heartbeat messages sent to Core Plugin ExtensionPoint

## Component Configuration

The Heartbeat component requires minimal configuration, focusing on timing and Core Plugin integration:

### Basic Setup

```rescript
// Create a heartbeat component
let heartbeat = Reventless.Heartbeat.make(~name="system-heartbeat")

// Connect to Core Plugin with timeout configuration
let connectHeartbeat = (~coreCommandTopic, ~runtime) => {
  heartbeat->Reventless.Heartbeat.connect(
    ~runtime,
    ~remoteChannel=coreCommandTopic.outputs,
    ~timeout=5, // Send heartbeat every 5 minutes
  )
}
```

### Handler Creation

```rescript
// Create a heartbeat handler for runtime use
let heartbeatHandler = Reventless.Heartbeat.makeHandler(
  ~id="health-monitor",
  ~timeout=10, // 10 minute timeout
  ~publishToCorePluginExtensionPoint=corePublisher,
)
```

## Runtime Behavior

The Heartbeat component operates through a simple, automated flow:

### Heartbeat Generation Flow

```d2
shape: sequence_diagram

CW: CloudWatch Events { class: aws-service }
Lambda: Heartbeat Lambda { class: aws-service }
SQS: Core Plugin SQS { class: aws-service }
EP: Extension Point { class: extension-point }
Ext: Extensions { class: extension }

CW -> Lambda: "Invoke heartbeat function (timer fires every N minutes)"
Lambda -> Lambda: Generate heartbeat message
Lambda -> SQS: Send heartbeat command
SQS -> EP: Deliver message
EP -> Ext: Invoke registered extensions
Ext --> EP: Process heartbeat
```

### Message Structure

The heartbeat generates standardized messages for the Core Plugin:

```rescript
// Generated heartbeat message structure
{
  Message.id: "health-monitor", // Configured ID
  meta: {
    service: "CorePluginExtensionPoint",
    time: "2024-01-26T10:30:00.000Z", // Current timestamp
    ip: "",
    user: "Heartbeat",
    msgId: "uuid-generated",
    correlationId: "uuid-generated",
  },
  commandJson: "Heartbeat(10)", // Timeout value encoded
}
```

## Integration Points

The Heartbeat component is specifically designed to integrate with the Core Plugin architecture:

### Core Plugin Integration

```d2
Heartbeat: Heartbeat Component { class: heartbeat }

CorePlugin: Core Plugin { 
  class: plugin-area
  ExtensionPoint: Plugin Extension Point { class: extension-point }
  HealthExt: Health Check Extension { class: extension }
  CleanupExt: Cleanup Extension { class: extension }
  MonitorExt: Monitor Extension { class: extension }

  ExtensionPoint -> HealthExt: invokes
  ExtensionPoint -> CleanupExt: invokes
  ExtensionPoint -> MonitorExt: invokes
}

Heartbeat -> CorePlugin.ExtensionPoint: periodic signals
```

### Extension Response Patterns

Extensions can respond to heartbeat signals in various ways:

```rescript
// Health check extension responding to heartbeat
let healthCheckExtension = (heartbeatCommand) => {
  switch heartbeatCommand {
  | Heartbeat(timeout) => 
    // Perform health checks
    checkDatabaseConnection()
    ->Promise.then(dbStatus => 
      checkExternalAPIs()
      ->Promise.then(apiStatus => {
        // Publish health status events
        publishHealthStatus(dbStatus, apiStatus)
      })
    )
  }
}
```

## Common Patterns

### Health Monitoring Pattern

```rescript
// Set up heartbeat for health monitoring
let healthMonitorHeartbeat = Reventless.Heartbeat.make(~name="health-monitor")

// Connect with appropriate timeout for health checks
healthMonitorHeartbeat->Reventless.Heartbeat.connect(
  ~runtime,
  ~remoteChannel=coreCommandTopic.outputs,
  ~timeout=5, // Check health every 5 minutes
)
```

### Cleanup Pattern

```rescript
// Heartbeat for periodic cleanup tasks
let cleanupHeartbeat = Reventless.Heartbeat.make(~name="cleanup-scheduler")

cleanupHeartbeat->Reventless.Heartbeat.connect(
  ~runtime,
  ~remoteChannel=coreCommandTopic.outputs,
  ~timeout=60, // Run cleanup every hour
)
```

### Watchdog Pattern

```rescript
// Short-interval heartbeat for watchdog functionality
let watchdogHeartbeat = Reventless.Heartbeat.make(~name="watchdog")

watchdogHeartbeat->Reventless.Heartbeat.connect(
  ~runtime,
  ~remoteChannel=coreCommandTopic.outputs,
  ~timeout=1, // Check every minute for quick response
)
```

### Multi-Purpose Monitoring

```rescript
// Single heartbeat triggering multiple monitoring extensions
let systemHeartbeat = Reventless.Heartbeat.make(~name="system-monitor")

// Extensions can differentiate based on heartbeat ID
let multiHandler = Reventless.Heartbeat.makeHandler(
  ~id="system-monitor",
  ~timeout=15,
  ~publishToCorePluginExtensionPoint=corePublisher,
)
```

## Comparison with Scheduler

The Heartbeat component serves a specific purpose compared to the general-purpose Scheduler:

| Feature | Heartbeat | Scheduler |
|---------|-----------|-----------|
| **Target** | Core Plugin ExtensionPoint only | Any component/service |
| **Purpose** | Health monitoring, keepalive | General scheduled workflows |
| **Configuration** | Fixed at deploy-time | Dynamic at runtime |
| **Operations** | None (automatic) | `createSchedule`, `deleteSchedule` |
| **Message Format** | Standardized heartbeat | Custom payload |
| **Integration** | Tightly coupled to Core Plugin | Loosely coupled |

### When to Use Heartbeat

**Choose Heartbeat for:**
- Health monitoring and system checks
- Periodic extension invocations via Core Plugin
- Simple, fixed-interval triggers
- Framework-level monitoring needs
- Keepalive mechanisms

**Choose Scheduler for:**
- Application-specific scheduled workflows
- Dynamic schedule management
- Custom payload delivery
- Flexible target configuration
- User-configurable timing

## Pulumi

The Heartbeat component is deployed as infrastructure that creates CloudWatch Event Rules, Lambda permissions, and IAM policies. All execution happens automatically once deployed.

```rescript
// Deployment creates all necessary infrastructure
let heartbeat = Reventless.Heartbeat.make(~name="system-heartbeat", ~opts=pulumiOpts)

// Connection configures the runtime integration
heartbeat->Reventless.Heartbeat.connect(~runtime, ~remoteChannel, ~timeout=10)
```

## AWS Implementation

For detailed AWS-specific implementation including CloudWatch Events integration, Lambda permissions, IAM policies, and Core Plugin SQS integration, see [Heartbeat → EventBridge Rule + Lambda](/aws/adapters/heartbeat).