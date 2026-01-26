---
title: Pulumi
date: 2024-08-13
draft: false
---

# Pulumi

## What is Pulumi?

Pulumi is a modern Infrastructure as Code (IaC) platform that allows you to define, deploy, and manage cloud infrastructure using familiar programming languages. Unlike traditional IaC tools that use domain-specific languages, Pulumi enables you to use languages like TypeScript, Python, Go, and in our case, ReScript.

**Key Benefits:**
- **Type Safety**: Compile-time checking of infrastructure configurations
- **Familiar Languages**: Use programming constructs like loops, conditionals, and functions
- **Cloud Agnostic**: Support for multiple cloud providers
- **State Management**: Automatic state tracking and conflict resolution
- **Resource Dependencies**: Automatic dependency resolution and ordering

**Learn More**: [Official Pulumi Documentation](https://www.pulumi.com/docs/)

## Why Pulumi in Reventless?

Reventless uses Pulumi for several strategic reasons that align perfectly with the framework's architecture and goals:

### 1. Type Safety with ReScript Integration
Pulumi's programmatic approach integrates seamlessly with ReScript's type system, providing compile-time guarantees for infrastructure configurations. This eliminates entire classes of deployment errors that would only be discovered at runtime with traditional IaC tools.

### 2. Component-Based Architecture Alignment
Pulumi's component resource model aligns naturally with reventless's component-based architecture. Each reventless component can encapsulate its infrastructure requirements as a Pulumi component resource, creating clear boundaries and reusable patterns.

### 3. AWS-First Approach with Extensibility
While reventless is AWS-first, Pulumi's multi-cloud support provides a path for future extensibility without architectural changes. The framework can leverage Pulumi's excellent AWS provider while maintaining the option to support other cloud providers.

### 4. Programmatic Infrastructure Management
Complex infrastructure patterns that would be difficult or impossible to express in declarative languages become straightforward with Pulumi's programmatic approach. This enables sophisticated resource orchestration and dynamic configuration.

### 5. Deploy-time/Runtime Separation
Pulumi enables a clear separation between deploy-time infrastructure provisioning and runtime application logic, which is fundamental to reventless's architecture.

## Pulumi in Reventless Architecture

### Deploy-time vs Runtime Separation

The reventless framework maintains a strict separation between two distinct phases:

- **Deploy-time**: Pulumi infrastructure definitions, resource creation, and dependency resolution
- **Runtime**: Lambda handlers, application logic, and business operations

This separation ensures that:
- Infrastructure concerns don't leak into runtime code
- Runtime code remains lightweight and focused on business logic
- Infrastructure can be reasoned about independently
- Deployment and runtime scaling can be optimized separately

### Pulumi.Output.t Wrapping

All infrastructure values in reventless are wrapped in [`Pulumi.Output.t<'a>`](packages/reventless/src/components/Component.res:7) to handle:

- **Asynchronous Resource Creation**: Resources may not be immediately available during deployment
- **Dependency Resolution**: Pulumi automatically resolves dependencies between resources
- **Value Propagation**: Values flow correctly through the dependency graph

Example from [`EventLog_Builder.res`](packages/reventless/src/components/EventLog/EventLog_Builder.res:26-44):

```rescript
self->Component.setOperations(
  (storage.operations, eventTopic->Component.operations)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((storageOps, eventTopicOps)) => {
    // Operations are only available after both dependencies resolve
    {
      append: Ops.append,
      replay: Ops.replay,
    }
  }),
)
```

### Component Resource Patterns

Reventless components extend [`Pulumi.ComponentResource`](packages/reventless/src/components/Component.res:24-29) to create reusable infrastructure patterns with proper parent-child relationships:

```rescript
@module("./Component") @new
external make: (
  ~componentType: string,
  ~name: string,
  ~construct: 'construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => t<'component, 'outputs, 'operations> = "default"
```

This pattern ensures:
- **Resource Organization**: Related resources are grouped under a parent component
- **Dependency Management**: Child resources automatically depend on parent resources
- **Naming Consistency**: Resource names follow a consistent hierarchy
- **Cleanup**: Deleting a parent component removes all child resources

## ReScript Bindings

Reventless includes custom ReScript bindings for Pulumi that provide type-safe access to Pulumi APIs:

### Core Dependencies
- **[@reventless/rescript-pulumi-pulumi](packages/reventless/package.json:38)**: ^2.2.0 (Core Pulumi bindings)
- **[@reventless/rescript-pulumi-aws](packages/reventless/package.json:37)**: ^2.3.0 (AWS provider bindings)

### Advantages of Custom Bindings

1. **Type-Safe Access**: All Pulumi APIs are properly typed in ReScript
2. **Integration with ReScript's Type System**: Leverages ReScript's powerful type inference
3. **Compile-Time Error Checking**: Catches configuration errors before deployment
4. **Better Developer Experience**: IDE support with autocomplete and type hints
5. **Consistent API Surface**: Uniform interface across all Pulumi providers

## Common Patterns and Examples

### Component Creation Pattern

From [`EventLog_Builder.res`](packages/reventless/src/components/EventLog/EventLog_Builder.res:14-24):

```rescript
let construct = (self, name) => {
  let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

  let storage = Storage.make(~name=name->ComponentType.name(EventLog.componentType), ~opts)

  module SpecificEventTopic = EventTopic_Builder.Make(Spec, EventTopicPublisher)
  let eventTopic = SpecificEventTopic.make(
    ~name,
    ~storageResources=storage.resources,
    ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
  )
  // ...
}
```

### Output Wrapping and Dependency Management

From [`Component.res`](packages/reventless/src/components/Component.res:7):

```rescript
let wrappedOutputs = component => component->Pulumi.Output.apply(component => component->outputs)
```

### Resource Type Definitions

From [`QueryDb_Adapter.res`](packages/reventless/src/components/QueryDb/QueryDb_Adapter.res:5-9):

```rescript
type storage = {
  resources: array<ReventlessSpec.Adapter.resource>,
  dataSourceName: Pulumi.Output.t<string>,
  operations: Pulumi.Output.t<operations>,
}
```

### Cross-Component Dependencies

Components can depend on outputs from other components, with Pulumi automatically managing the dependency graph:

```rescript
let eventTopic = SpecificEventTopic.make(
  ~name,
  ~storageResources=storage.resources, // Dependency on storage component
  ~opts,
)
```

## Best Practices in Reventless

### 1. Resource Naming Conventions
- Use consistent naming patterns across components
- Include component type and instance name in resource names
- Leverage [`ComponentType.name`](packages/reventless/src/components/EventLog/EventLog_Builder.res:17) for standardized naming

### 2. Dependency Management
- Always wrap infrastructure values in [`Pulumi.Output.t`](packages/reventless/src/components/Component.res:7)
- Use [`Pulumi.Output.all2`](packages/reventless/src/components/EventLog/EventLog_Builder.res:28) and similar functions to combine multiple outputs
- Apply transformations using [`Pulumi.Output.apply`](packages/reventless/src/components/EventLog/EventLog_Builder.res:29)

### 3. Component Resource Organization
- Create component resources for logical groupings of infrastructure
- Set proper parent-child relationships using [`Pulumi.CustomResourceOptions.parent`](packages/reventless/src/components/EventLog/EventLog_Builder.res:15)
- Register outputs using [`Component.setOutputs`](packages/reventless/src/components/Component.res:35-38)

### 4. Error Handling Patterns
- Leverage ReScript's type system to catch configuration errors at compile time
- Use option types for optional configuration parameters
- Validate inputs early in the component construction process

### 5. Performance Considerations
- Minimize the number of Pulumi operations in hot paths
- Cache expensive computations in component outputs
- Use resource dependencies efficiently to minimize deployment time

## Integration with AWS

Reventless leverages Pulumi's AWS provider through custom ReScript bindings to create:

- **Lambda Functions**: For serverless compute
- **DynamoDB Tables**: For event storage and state management
- **SNS Topics**: For event publishing and messaging
- **API Gateway**: For HTTP endpoints
- **IAM Roles and Policies**: For security and access control

The AWS-specific adapters (like those referenced in [`EventLog_Builder.res`](packages/reventless/src/components/EventLog/EventLog_Builder.res:3)) encapsulate the complexity of AWS resource creation while providing a clean, type-safe interface to the reventless components.

## Troubleshooting

### Common Issues

1. **Dependency Cycles**: Ensure that component dependencies form a directed acyclic graph
2. **Output Access**: Always use [`Pulumi.Output.apply`](packages/reventless/src/components/EventLog/EventLog_Builder.res:29) to access values inside outputs
3. **Resource Naming**: Avoid hardcoded resource names that might conflict across deployments
4. **Type Mismatches**: Leverage ReScript's type system to catch binding issues early

### Debugging Tips

- Use Pulumi's preview mode to understand resource changes before deployment
- Leverage ReScript's compiler errors to identify type mismatches
- Check resource dependencies in the Pulumi console
- Use structured logging in component constructors for debugging

## Conclusion

Pulumi's integration with reventless provides a powerful foundation for type-safe, programmatic infrastructure management. The combination of ReScript's type system, Pulumi's resource model, and reventless's component architecture creates a robust platform for building and deploying event-sourced applications on AWS.

The patterns established in reventless demonstrate how modern Infrastructure as Code can be both powerful and maintainable when properly integrated with a strongly-typed functional programming language.