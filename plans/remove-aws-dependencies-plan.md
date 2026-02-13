# Remove AWS Dependencies from Reventless Core Package

## Context

The `reventless` package currently has AWS-specific dependencies that violate its provider-agnostic design. According to the architecture documented in CLAUDE.md:

- **reventless** should be a provider-agnostic framework core
- **reventless-aws** should contain all AWS-specific implementations

Currently, `reventless` has:
- 2 AWS package dependencies (`rescript-aws-sdk`, `rescript-pulumi-aws`)
- 8 files with AWS-specific code (VPC infrastructure, SNS/SQS operations, IAM policies)
- Direct AWS SDK runtime calls in plugin connection infrastructure

This makes it impossible to use Reventless with other cloud providers (GCP, Azure, etc.).

## Strategy

**Three-tier approach:**

1. **Create abstraction interfaces** in `reventless-spec` for provider-agnostic operations
2. **Move AWS-specific infrastructure** (VPC, utilities) to `reventless-aws`
3. **Refactor plugin runtime operations** to use dependency injection instead of direct AWS SDK calls

**Key architectural decisions:**

- **Plugin operations abstraction**: Instead of direct AWS SDK calls in core plugin code, pass provider-specific operations as parameters through the builder pattern
- **VPC component**: Move entirely to `reventless-aws` (it's AWS-specific infrastructure)
- **Minimal breaking changes**: Use functor parameters to inject provider-specific operations

## Critical Files

**Files to modify in reventless (5):**
- `/Users/martin/prj/ReventlessDev/reventless-core/packages/reventless/src/components/Plugin/Plugin_Callback.res`
- `/Users/martin/prj/ReventlessDev/reventless-core/packages/reventless/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res`
- `/Users/martin/prj/ReventlessDev/reventless-core/packages/reventless/src/core/Extensions/Connect/PluginConnectExtension_Builder.res`
- `/Users/martin/prj/ReventlessDev/reventless-core/packages/reventless/src/util/Schedule.res`
- `/Users/martin/prj/ReventlessDev/reventless-core/packages/reventless/src/Env.res`

**Files to move from reventless to reventless-aws (4):**
- Vpc.res + Vpc.resi (215 lines)
- Util_Vpc.res (23 lines)
- AWS.res (8 lines) → renamed to Util_ResourceNaming.res

**New files to create in reventless-spec (3):**
- PluginRuntimeOperations.res (abstraction interfaces)
- NetworkInfrastructure.res (VPC abstraction)
- ResourceNaming.res (naming utilities interface)

**New files to create in reventless-aws (7):**
- Util_PluginOperations_Runtime.res (AWS implementation of plugin ops)
- Util_TopicSubscription_Runtime.res (AWS SNS/SQS subscriptions)
- PluginRuntimeOperations.res (export AWS implementations)
- ResourceNaming.res (export AWS naming utilities)
- Plus moved files: Vpc.res, Vpc.resi, Util_Vpc.res, Util_ResourceNaming.res

## Implementation Steps

### Step 1: Create Abstraction Interfaces in reventless-spec

**1.1 Create PluginRuntimeOperations.res**

```rescript
// packages/reventless-spec/src/PluginRuntimeOperations.res

// Provider-agnostic interface for plugin runtime operations
type topicSubscriptionOps = {
  subscribeQueueToTopic: (string, string) => promise<unit>,
  unsubscribeQueueFromTopic: (string, string) => promise<unit>,
}

type messagePublishOps = {
  sendMessageToQueue: (~queueId: string, ~messageBody: string) => promise<unit>,
}

type operations = {
  topicSubscription: topicSubscriptionOps,
  messagePublish: messagePublishOps,
}
```

**1.2 Create ResourceNaming.res**

```rescript
// packages/reventless-spec/src/ResourceNaming.res

type operations = {
  validateName: string => string,
  arnToName: string => string,
}
```

**1.3 Update reventless-spec exports**

Add exports to `reventless-spec` package's main module.

### Step 2: Move AWS Utilities to reventless-aws

**2.1 Move AWS.res → Util_ResourceNaming.res**

```bash
# Move file
mv packages/reventless/src/util/AWS.res \
   packages/reventless-aws/src/util/Util_ResourceNaming.res
```

Keep existing functions:
- `validateName` - sanitizes resource names
- `arn2Name` - extracts name from ARN

**2.2 Create ResourceNaming.res in reventless-aws**

```rescript
// packages/reventless-aws/src/util/ResourceNaming.res

let operations: ReventlessSpec.ResourceNaming.operations = {
  validateName: Util_ResourceNaming.validateName,
  arnToName: Util_ResourceNaming.arn2Name,
}
```

**2.3 Move Env.res AWS parts**

Create `packages/reventless-aws/src/util/Util_Env.res`:

```rescript
@val external awsAccountId: option<string> = "process.env.AWS_ACCOUNT_ID"
@val external awsRegion: option<string> = "process.env.AWS_REGION"
```

Update `packages/reventless/src/Env.res` - remove `awsAccountId` and `awsRegion`, keep only:
- `pulumiOrganization`
- `restoreDateTime`

### Step 3: Move VPC Infrastructure to reventless-aws

**3.1 Move VPC component files**

```bash
mv packages/reventless/src/components/Vpc.res \
   packages/reventless-aws/src/components/Vpc.res

mv packages/reventless/src/components/Vpc.resi \
   packages/reventless-aws/src/components/Vpc.resi

mv packages/reventless/src/util/Util_Vpc.res \
   packages/reventless-aws/src/util/Util_Vpc.res
```

No code changes needed - these are already AWS-specific.

**3.2 Update imports in reventless-aws**

Find any code in `reventless-aws` that imports `Reventless.Vpc` or `Reventless.Util_Vpc` and update to local imports.

Example: `packages/reventless-aws/src/components/ClonerRunner_Fargate.res` likely uses VPC utilities.

### Step 4: Create AWS Plugin Runtime Operations

**4.1 Create Util_TopicSubscription_Runtime.res**

```rescript
// packages/reventless-aws/src/util/Util_TopicSubscription_Runtime.res

let subscribe = async (eventCollector, eventTopic) => {
  switch await AwsSdk.SNS.subscribeQueueToTopic(eventCollector, eventTopic) {
  | _ => ()
  | exception JsExn(e) => {
      Console.error2("Failed to subscribe queue to topic:", e)
      raise(JsExn(e))
    }
  }
}

let unsubscribe = async (eventCollector, eventTopic) => {
  switch await AwsSdk.SNS.unsubscribeQueueFromTopic(eventCollector, eventTopic) {
  | _ => ()
  | exception JsExn(e) => {
      Console.error2("Failed to unsubscribe queue from topic:", e)
      raise(JsExn(e))
    }
  }
}
```

**4.2 Create Util_PluginMessage_Runtime.res**

```rescript
// packages/reventless-aws/src/util/Util_PluginMessage_Runtime.res

let sendMessage = async (~queueId, ~messageBody) => {
  switch await AwsSdk.SQS.sendMessage(~queueId, ~messageBody) {
  | _ => ()
  | exception err => {
      Console.error2("Failed to send message to queue:", err)
      raise(err)
    }
  }
}
```

**4.3 Create PluginRuntimeOperations.res (exports)**

```rescript
// packages/reventless-aws/src/util/PluginRuntimeOperations.res

let operations: ReventlessSpec.PluginRuntimeOperations.operations = {
  topicSubscription: {
    subscribeQueueToTopic: Util_TopicSubscription_Runtime.subscribe,
    unsubscribeQueueFromTopic: Util_TopicSubscription_Runtime.unsubscribe,
  },
  messagePublish: {
    sendMessageToQueue: Util_PluginMessage_Runtime.sendMessage,
  },
}
```

### Step 5: Refactor reventless Core to Use Abstractions

**5.1 Refactor PluginConnectExtension_Builder.res**

Update functor to accept runtime operations:

```rescript
// packages/reventless/src/core/Extensions/Connect/PluginConnectExtension_Builder.res

module type Spec = {
  let pluginDefinition: ReventlessSpec.Plugin.pluginDefinition
  let extensionPointsOutputs: array<ExtensionPoint.unwrappedOutputs>
  let extensionsOutputs: array<Extension.outputs>
  let runtimeOps: ReventlessSpec.PluginRuntimeOperations.operations  // NEW
  let resourceNaming: ReventlessSpec.ResourceNaming.operations        // NEW
}

module Make = (Spec: Spec) => {
  let subscribe = async (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
    let eventTopicName = eventTopic->Spec.resourceNaming.arnToName
    let eventCollectorName = eventCollector->Spec.resourceNaming.arnToName
    let _sid = (extensionPointName ++ ("-" ++ pluginId))->Spec.resourceNaming.validateName

    Console.log(...)
    switch await Spec.runtimeOps.topicSubscription.subscribeQueueToTopic(
      eventCollector,
      eventTopic,
    ) {
    | _ => Console.log(...)
    | exception JsExn(e) => Console.log2(...)
    }
  }

  let unsubscribe = async (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
    // Similar changes using Spec.runtimeOps.topicSubscription.unsubscribeQueueFromTopic
    ...
  }

  // Rest of the module stays the same
  ...
}
```

**Key changes:**
- Add `runtimeOps` and `resourceNaming` to `Spec` module type
- Replace `AWS.arn2Name` with `Spec.resourceNaming.arnToName`
- Replace `AWS.validateName` with `Spec.resourceNaming.validateName`
- Replace `AwsSdk.SNS.*` calls with `Spec.runtimeOps.topicSubscription.*`

**5.2 Refactor PluginExtensionPoint_Plugin.res**

Update to accept runtime operations and environment:

```rescript
// packages/reventless/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res

let forwardCommand = async (
  _id,
  command,
  extensionPointName,
  queryEngine: ReventlessSpec.QueryEngine.operations,
  runtimeOps: ReventlessSpec.PluginRuntimeOperations.operations,  // NEW
) =>
  switch await queryEngine.scan(...) {
  | jsons =>
    switch jsons {
    | [] => Console.log2(...)
    | plugins =>
      let plugin = plugins->Array.getUnsafe(0)
      switch plugin->Message.decode(PluginReadModelSpec.stateSchema) {
      | plugin =>
        let extensionPoint = plugin.extensionPoints->Array.find(...)
        switch extensionPoint {
        | Some(extensionPoint) =>
          switch await runtimeOps.messagePublish.sendMessageToQueue(
            ~queueId=extensionPoint.commandTopic,
            ~messageBody=command,
          ) {
          | _ => Console.log3(...)
          | exception err => Console.log2(...)
          }
        | None => Console.log3(...)
        }
      | exception err => Console.log3(...)
      }
    }
  }

let callHandler = async (
  createSchedule: ReventlessSpec.Schedule.create,
  deleteSchedule: ReventlessSpec.Schedule.delete,
  queryEngine: ReventlessSpec.QueryEngine.operations,
  runtimeOps: ReventlessSpec.PluginRuntimeOperations.operations,  // NEW
  environment: string,                                             // NEW (instead of PulumiAws.Lambda.environment)
  callCommand,
) =>
  switch callCommand {
  | ReventlessSpec.PluginExtensionPointSpec.CreateDisconnectSchedule(id, timeout) =>
    await createSchedule({
      name: environment ++ ("-" ++ id),  // Use passed environment instead
      rate: timeout->Schedule.minutesFromNow,
      payload: {...}
    })
  | DeleteDisconnectSchedule(id) => await deleteSchedule(id)
  | ForwardCommand({id, command, extensionPointName}) =>
    await forwardCommand(id, command, extensionPointName, queryEngine, runtimeOps)
  | _ => ()
  }

// Update Impl module to pass runtimeOps through
```

**5.3 Simplify Plugin_Callback.res**

Remove unused AWS SDK functions:

```rescript
// packages/reventless/src/components/Plugin/Plugin_Callback.res

// DELETE these functions (lines 66-110):
// - addStatement
// - removeStatement
// - _addPermission
// - _removePermission

// These are unused (prefixed with _) and AWS-specific
```

Keep only the provider-agnostic `Make` functor (lines 1-64).

**5.4 Update Schedule.res**

Update to accept resource naming operations:

```rescript
// packages/reventless/src/util/Schedule.res

let forQueue = (name, queueId, resourceNaming: ReventlessSpec.ResourceNaming.operations) =>
  name->resourceNaming.validateName ++ ("-" ++ queueId->String.split("-")->Array.getUnsafe(1))

let create = (
  scheduler: Scheduler.operations,
  queueResources,
  resourceNaming: ReventlessSpec.ResourceNaming.operations,
) =>
  async schedule => {
    let name = schedule.name->resourceNaming.validateName
    let schedule = {...schedule, name}
    ...
  }

let delete = (
  scheduler: Scheduler.operations,
  queueResources,
  resourceNaming: ReventlessSpec.ResourceNaming.operations,
) =>
  async name => {
    let name = name->resourceNaming.validateName
    ...
  }
```

### Step 6: Update reventless-aws Builders

**6.1 Update Plugin builders to pass operations**

Files to update in `packages/reventless-aws/src/core/`:
- `Plugin_Aggregate_Builder.res`
- `Plugin_ReadModel_Builder.res`
- `Plugin_ExtensionPoint_Builder.res`

When instantiating `PluginConnectExtension_Builder.Make()`, pass AWS-specific operations:

```rescript
module ConnectPluginExtension = PluginConnectExtension_Builder.Make({
  let pluginDefinition = pluginDefinition
  let extensionPointsOutputs = extensionPointsOutputs
  let extensionsOutputs = extensionsOutputs
  let runtimeOps = PluginRuntimeOperations.operations      // NEW
  let resourceNaming = ResourceNaming.operations           // NEW
})
```

Similar updates for any code that calls `PluginExtensionPoint_Plugin.callHandler` - pass the AWS runtime operations and Lambda environment.

### Step 7: Update Package Dependencies

**7.1 Update reventless/package.json**

Remove AWS dependencies:

```json
{
  "dependencies": {
    // DELETE: "@reventlessdev/rescript-aws-sdk": "^2.1.3-alpha.2",
    // DELETE: "@reventlessdev/rescript-pulumi-aws": "^2.3.1-alpha.2",
    "@reventlessdev/rescript-fast-csv": "^1.1.3-alpha.2",
    "@reventlessdev/rescript-hash-object": "^1.1.2-alpha.2",
    ...
  }
}
```

**7.2 Update reventless/rescript.json**

Remove AWS dependencies from bs-dependencies:

```json
{
  "bs-dependencies": [
    // DELETE: "@reventlessdev/rescript-aws-sdk",
    // DELETE: "@reventlessdev/rescript-pulumi-aws",
    "@reventlessdev/rescript-fast-csv",
    ...
  ]
}
```

**7.3 Run npm install**

```bash
cd packages/reventless
npm install
```

This will update package-lock.json to reflect the removed dependencies.

### Step 8: Build and Verify

**8.1 Build in correct order**

```bash
# Build spec first (new interfaces)
cd packages/reventless-spec
npm run build

# Build reventless (should succeed without AWS deps)
cd ../reventless
npm run build

# Build reventless-aws (with AWS implementations)
cd ../reventless-aws
npm run build
```

**8.2 Verify no AWS imports in reventless**

```bash
cd packages/reventless
grep -r "PulumiAws\|AwsSdk" src/ --include="*.res"
# Should return no results
```

**8.3 Run tests**

```bash
cd packages/reventless
npm run test

cd ../reventless-aws
npm run build  # Verify builds successfully
```

**8.4 Check for broken imports**

Search for any code importing moved components:

```bash
# Find references to Reventless.Vpc
grep -r "Reventless\.Vpc" packages/ --include="*.res"

# Find references to AWS utility
grep -r "AWS\.validateName\|AWS\.arn2Name" packages/reventless/ --include="*.res"
```

All should be updated to use either:
- `ReventlessAws.Vpc` (for AWS-specific code)
- `Spec.resourceNaming.*` (for provider-agnostic code with injected operations)

## Verification Checklist

- [ ] No `PulumiAws` imports in packages/reventless/src
- [ ] No `AwsSdk` imports in packages/reventless/src
- [ ] No AWS package dependencies in packages/reventless/package.json
- [ ] VPC component accessible via ReventlessAws namespace
- [ ] Plugin runtime operations use dependency injection
- [ ] Schedule operations accept resourceNaming parameter
- [ ] All packages build successfully in order (spec → reventless → reventless-aws)
- [ ] Tests pass in reventless package
- [ ] No broken imports or missing modules
- [ ] package-lock.json updated and committed with package.json

## Breaking Changes & Migration Guide

### For Users of reventless v3.0.0-alpha.2

**VPC Component:**
```rescript
// BEFORE
open Reventless
let vpc = Vpc.make(~name="myVpc")

// AFTER
open ReventlessAws
let vpc = Vpc.make(~name="myVpc")
```

**AWS Utilities:**
```rescript
// BEFORE
open Reventless
let validName = AWS.validateName(name)

// AFTER
open ReventlessAws
let validName = Util_ResourceNaming.validateName(name)
```

**Plugin Builders:**
Most users don't directly use the plugin builder internals. The changes are in the AWS adapter layer which already depends on reventless-aws.

### Release Strategy

1. **v3.1.0-alpha.x**: Implement this migration
2. **v3.1.0-beta.x**: User testing, documentation updates
3. **v3.1.0**: Release with migration guide in CHANGELOG

## Files Modified Summary

**reventless-spec (3 new files):**
- src/PluginRuntimeOperations.res
- src/ResourceNaming.res
- Update module exports

**reventless (5 modified, 5 deleted):**
- Modified: Plugin_Callback.res, PluginExtensionPoint_Plugin.res, PluginConnectExtension_Builder.res, Schedule.res, Env.res
- Deleted: Vpc.res, Vpc.resi, Util_Vpc.res, AWS.res, package.json changes
- Updated: package.json, rescript.json, package-lock.json

**reventless-aws (11 new/moved files, 3+ modified):**
- Moved: Vpc.res, Vpc.resi, Util_Vpc.res
- New: Util_ResourceNaming.res, Util_Env.res, Util_TopicSubscription_Runtime.res, Util_PluginMessage_Runtime.res, PluginRuntimeOperations.res, ResourceNaming.res
- Modified: Plugin_Aggregate_Builder.res, Plugin_ReadModel_Builder.res, Plugin_ExtensionPoint_Builder.res, any files importing moved VPC component

**Total impact:** ~19 files across 3 packages
