---
title: Config
date: 2024-08-13
draft: false
---

# Config Module

The Config module defines the configuration interface that plugins use to access shared infrastructure resources and settings within a Reventless application.

## Module Type Definition

The Config module type is defined as follows:

```rescript
module type T = {
  type api
  type role
  type userPool

  let pluginName: string

  let api: api
  let apiRole: role
  let userPoolId: Pulumi.Output.t<string>

  let scheduler: Pulumi.Output.t<Scheduler.operations>
}
```

## Configuration Fields

### Type Parameters

- **`api`** - Abstract type representing the API Gateway instance
- **`role`** - Abstract type representing IAM role resources
- **`userPool`** - Abstract type representing Cognito User Pool resources

### Required Fields

- **`pluginName: string`** - Unique identifier for the plugin within the application

- **`api: api`** - Reference to the shared API Gateway instance that the plugin's endpoints will be attached to

- **`apiRole: role`** - IAM role used by the API Gateway to invoke Lambda functions

- **`userPoolId: Pulumi.Output.t<string>`** - Cognito User Pool ID for authentication integration

- **`scheduler: Pulumi.Output.t<Scheduler.operations>`** - Reference to the shared scheduler component for scheduled task execution

## Usage

The Config module is typically created at the application/stack level and passed to plugins during initialization. Each plugin receives the same configuration, allowing them to:

1. Register API endpoints with the shared API Gateway
2. Use common authentication via the User Pool
3. Schedule recurring tasks via the shared Scheduler
4. Maintain consistent IAM permissions via the shared role

## Example

```rescript
// In your stack/application setup
module MyConfig = {
  type api = Pulumi.Aws.ApiGateway.RestApi.t
  type role = Pulumi.Aws.Iam.Role.t
  type userPool = Pulumi.Aws.Cognito.UserPool.t

  let pluginName = "my-plugin"
  let api = myApiGatewayInstance
  let apiRole = myIamRole
  let userPoolId = myUserPool.id
  let scheduler = schedulerOperations
}

// Pass to plugin
module MyPlugin = Plugin.Make(MyPluginSpec, MyConfig)
```

## Related Documentation

- [Plugin Component](../components/plugin.md) - Plugins consume Config
- [Scheduler Component](../components/scheduler.md) - Scheduler operations
- [API Component](../components/api.md) - API Gateway integration
