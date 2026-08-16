---
title: "Heartbeat → EventBridge Rule + Lambda"
date: 2026-01-15
draft: false
---


:::note EventBridge, formerly CloudWatch Events
AWS renamed CloudWatch Events to **EventBridge**; the Pulumi resource is still
called `aws.cloudwatch.EventRule`. This page says EventBridge throughout and
names the Pulumi resource where it matters.
:::

## Heartbeat → EventBridge

The Heartbeat adapter provides periodic heartbeat signals using EventBridge, enabling health monitoring, keepalive mechanisms, and periodic extension point invocations within the platform admin.

## EventBridge rule Configuration

The Heartbeat adapter creates a EventBridge rule with a schedule expression based on the configured timeout:

```rescript
let cloudwatchEventRule = {
  open PulumiAws.Cloudwatch
  EventRule.make(
    ~name=Pulumi.Pulumi.getStackName() ++ ("-" ++ name),
    ~args={
      description: "Send a heartbeat to the admin Plugin ExtensionPoint"->Pulumi.Input.make,
      scheduleExpression: EventRule.ScheduleExpression.every(timeout->Minutes),
    },
    ~opts,
  )
}
```

**Configuration details:**

- **Rule name** - Combines stack name with heartbeat name for uniqueness across deployments
- **Description** - Documents the rule's purpose for CloudWatch console visibility
- **Schedule expression** - `rate(N minutes)` format based on timeout parameter
  - `timeout->Minutes` converts timeout value to CloudWatch rate expression
  - Example: `timeout=5` → `rate(5 minutes)`
- **Stack-scoped** - Uses `Pulumi.getStackName()` to isolate rules per deployment environment

**Key features:**

- **Fixed interval** - Heartbeat runs at consistent intervals regardless of execution duration
- **Automatic triggering** - EventBridge invokes Lambda on schedule without manual intervention
- **Environment isolation** - Stack name prefix prevents conflicts between dev/staging/prod

## Lambda Integration and IAM Policies

The Heartbeat adapter integrates with Lambda and configures comprehensive IAM policies:

```rescript
let _attachPoliciesAndSetEventTarget =
  (
    lambda->Pulumi.Output.flatMap(lambda => lambda.arn),
    lambda->Pulumi.Output.flatMap(lambda => lambda.name),
    lambdaRole.id,
  )
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((lambdaArn, lambdaName, heartbeatRoleId)) => {
    // 1. Grant EventBridge permission to invoke Lambda
    let _addHeartbeatLambdaPermission = PulumiAws.Lambda.Permission.make(
      ~name,
      ~args={
        action: "lambda:InvokeFunction",
        function: lambdaName->Pulumi.Input.make,
        principal: AWS.CloudwatchEventRule.principal,
      },
      ~opts,
    )

    // 2. Create policy for Lambda to send messages to admin SQS queue
    let heartbeatLambdaSendMessagePolicyDocument = {
      PulumiAws.PolicyDocument.make(
        ~statements=[
          {
            sid: "AllowLambdaToSendSQS",
            effect: Allow,
            actions: Action("sqs:SendMessage"),
            resources: Resource(platformSqsQueue.urn),
          },
        ],
      )
    }

    // 3. Attach merged policy to Lambda role
    let _attachHeartbeatLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
      ~name=name ++ "RolePolicy",
      ~args={
        policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
          name ++ "Policy",
          [
            PulumiAws.Lambda.defaultLoggingPolicyDocument,
            heartbeatLambdaSendMessagePolicyDocument,
          ],
        )->Pulumi.Output.asInput,
        role: heartbeatRoleId->Pulumi.Input.make,
      },
    )

    // 4. Add Lambda as CloudWatch Event target
    let _cloudwatchEventTarget = {
      open PulumiAws.Cloudwatch
      EventTarget.make(
        ~name,
        ~args={
          rule: EventTarget.Rule.ofEventRule(cloudwatchEventRule),
          arn: lambdaArn->Pulumi.Input.make,
        },
        ~opts,
      )
    }
  })
```

**Integration flow:**

1. **Lambda Permission** - Grants EventBridge service permission to invoke the Lambda function
   - **Action**: `lambda:InvokeFunction`
   - **Principal**: `events.amazonaws.com`
   - **Resource**: Specific Lambda function
   - **Effect**: Allows EventBridge to trigger Lambda on schedule

2. **SQS Send Policy** - Grants Lambda permission to send heartbeat messages to the admin Plugin ExtensionPoint's SQS queue
   - **Action**: `sqs:SendMessage`
   - **Resource**: Admin CommandTopic SQS queue URN
   - **Purpose**: Enables Lambda to publish heartbeat events to the admin ExtensionPoint

3. **Policy Merging** - Combines logging and SQS policies into a single IAM role policy
   - **Logging policy**: Standard CloudWatch Logs permissions (`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`)
   - **SQS policy**: SendMessage permission for admin queue
   - **Attachment**: Attached to Lambda execution role

4. **Event Target** - Configures Lambda as the target for the EventBridge rule
   - **Rule**: References the EventBridge rule created earlier
   - **ARN**: Lambda function ARN
   - **Effect**: EventBridge invokes this Lambda when the rule fires

**Key features:**

- **Least privilege** - Lambda only has permission to send to the specific admin queue
- **Resource binding** - Uses `Pulumi.Output.all3` to coordinate resource dependencies
- **Automatic wiring** - All permissions and targets are configured automatically at deploy-time
- **CloudWatch Logs** - Includes standard logging permissions for debugging and monitoring

## Admin Plugin ExtensionPoint Integration

The Heartbeat adapter is specifically designed to integrate with the admin Plugin ExtensionPoint mechanism:

**Heartbeat flow:**

1. **CloudWatch Event fires** - Rule triggers Lambda based on schedule expression
2. **Lambda executes** - Heartbeat Lambda function is invoked
3. **Message published** - Lambda sends heartbeat message to admin Plugin ExtensionPoint's SQS queue
4. **Admin processes** - Plugin ExtensionPoint receives and processes heartbeat
5. **Extension invocation** - Registered extensions respond to heartbeat signal

**`remoteChannel` parameter:**

```rescript
let platformSqsQueue = remoteChannel.resources->Util_SQS.findResolvedResource
```

The `remoteChannel` parameter provides access to the admin Plugin ExtensionPoint's CommandTopic SQS queue:
- **Type**: `Reventless.CommandTopic.outputs` from the admin Plugin ExtensionPoint
- **Purpose**: Enables Heartbeat to send messages to the admin ExtensionPoint
- **Resolution**: `findResolvedResource` extracts the SQS queue resource from the channel outputs

**Why SQS instead of direct invocation?**

- **Decoupling** - Heartbeat doesn't need to know about the admin Lambda implementation
- **Reliability** - SQS provides message durability and retry logic
- **Consistency** - Uses the same CommandTopic pattern as other components
- **Extensibility** - Multiple heartbeat sources can send to the same queue

## Deploy-time to Runtime Flow

The Heartbeat adapter follows the standard deploy-time/runtime pattern:

```rescript
let make: Reventless.Heartbeat_Adapter.runnerMaker<runtimeParts> = (
  ~name,
  ~remoteChannel,
  ~timeout,
  ~runtime,
  ~opts,
) => {
  // 1. Deploy-time: Create EventBridge rule
  let cloudwatchEventRule = EventRule.make(~name, ~args={
    scheduleExpression: EventRule.ScheduleExpression.every(timeout->Minutes),
  }, ~opts)

  // 2. Deploy-time: Extract Lambda and SQS resources
  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole
  let platformSqsQueue = remoteChannel.resources->Util_SQS.findResolvedResource

  // 3. Deploy-time: Configure Lambda permissions, IAM policies, and event target
  let _attachPoliciesAndSetEventTarget = /* ... */

  {
    resources: [
      lambda->Pulumi.Output.apply(lambda => lambda->Util_Lambda.toResource)->Reventless.Adapter.outputToResource,
      cloudwatchEventRule->Util_Cloudwatch.EventRule.toResource,
    ],
  }
}
```

**Flow steps:**

1. **Create Event Rule** - Pulumi provisions EventBridge rule with schedule expression
2. **Extract resources** - Gets Lambda function, Lambda role, and admin SQS queue from parameters
3. **Configure permissions** - Sets up Lambda permissions, IAM policies, and event target
4. **Return resources** - Returns Lambda and Event Rule resources for dependency tracking

**Key features:**

- **No runtime operations** - Heartbeat has no runtime operations; everything is configured at deploy-time
- **Pure infrastructure** - All logic is in EventBridge rule and Lambda permissions
- **Dependency tracking** - Returns resources for Pulumi dependency graph
- **Automatic execution** - Once deployed, heartbeat runs automatically on schedule

## When to Use Heartbeat

**Use Heartbeat for:**

- **Health monitoring** - Verify services are running and responsive
  - Periodic health checks to external APIs
  - Database connection validation
  - Service availability verification
- **Keepalive mechanisms** - Maintain long-lived connections or sessions
  - WebSocket connection keepalives
  - Session renewal
  - Connection pool maintenance
- **Extension Point triggers** - Invoke admin extensions periodically
  - Scheduled cleanup tasks via extensions
  - Periodic data synchronization
  - Metric collection and reporting
- **Watchdog timers** - Detect and respond to stalled processes
  - Timeout detection for long-running tasks
  - Deadlock detection
  - Process restart triggers

**Common patterns:**

- **Health Check Pattern** - Heartbeat → Admin ExtensionPoint → Health Check Extension
  - Heartbeat triggers admin Plugin ExtensionPoint
  - Extension performs health checks
  - Extension publishes events or commands based on health status
- **Cleanup Pattern** - Heartbeat → Admin ExtensionPoint → Cleanup Extension
  - Heartbeat triggers admin Plugin ExtensionPoint
  - Extension queries for expired/stale data
  - Extension publishes delete commands
- **Sync Pattern** - Heartbeat → Admin ExtensionPoint → Sync Extension
  - Heartbeat triggers admin Plugin ExtensionPoint
  - Extension checks for data to synchronize
  - Extension publishes commands to update aggregates

**Comparison with ScheduledPublisher:**

| Feature | Heartbeat | ScheduledPublisher |
|---------|-----------|-------------------|
| **Purpose** | Admin Plugin ExtensionPoint trigger | General scheduled event publishing |
| **Target** | Fixed (admin Plugin ExtensionPoint SQS queue) | Dynamic (any target) |
| **Runtime operations** | None (pure deploy-time) | `createSchedule`, `deleteSchedule` |
| **Use case** | Framework-level health/monitoring | Application-level scheduled workflows |
| **Flexibility** | Fixed schedule at deploy-time | Dynamic schedules at runtime |
| **Integration** | Tightly coupled to admin Plugin ExtensionPoint | Loosely coupled to any component |

**When to choose Heartbeat:**
- Need to integrate with admin Plugin ExtensionPoint mechanism
- Want simple, fixed-interval triggers
- Don't need dynamic schedule management
- Focused on health monitoring and periodic checks

**When to choose ScheduledPublisher:**
- Need dynamic schedule creation/deletion
- Want flexible target configuration
- Require user-configurable schedules
- Building application-specific scheduled workflows
