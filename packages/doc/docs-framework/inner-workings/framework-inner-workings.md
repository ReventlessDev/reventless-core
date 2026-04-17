---
title: Framework Inner Workings
date: 2021-11-22
draft: false
---

## Framework Architecture Patterns

Reventless follows several key architectural patterns that ensure consistency, type safety, and maintainability across the framework:

### Component Structure Pattern

All framework components follow a standardized structure pattern using a multi-file organization:
- `Component.res` - Interface and type definitions
- `Component_Builder.res` - Factory and construction logic
- `Component_Adapter.res` - Provider-agnostic adapter interface (optional)
- `Component_Operations.res` - Runtime business logic implementation (optional)
- `Component_Callback.res` - Runtime behavior handlers (optional)

This pattern ensures clear separation of concerns, type safety through module types, and provider independence.

[Learn more about the Component Structure Pattern →](./component-structure-pattern.md)

### Other Patterns

- [Messages](./messages.md) - How messages flow through the system
- [Runtime & Deployment](./runtime.md) - Runtime environments and deployment strategies
- [Pulumi Integration](./pulumi.md) - Deploy-time vs runtime separation
- [Serialization](./serialization.md) - Data encoding/decoding patterns
- [Resources](./resources.md) - Infrastructure resource management
- [MCP (Model Context Protocol)](./mcp.md) - AI-native access via tools and resources
- [AWS Adapters](/infrastructure/aws) - Provider-specific implementations

# Framework Inner Workings

This section provides in-depth documentation about how the Reventless framework is structured and operates internally.

## Framework Architecture Patterns

Reventless follows several key architectural patterns that provide consistency, type safety, and maintainability:

### Component Structure Pattern

All framework components follow a **standardized three-file structure pattern** that ensures consistency and clear separation of concerns:

- **`Component.res`** - Interface and type definitions
- **`Component_Builder.res`** - Factory and construction logic using functors
- **`Component_Callback.res`** - Runtime behavior handlers (when applicable)

This pattern uses **first-class modules**, **functors**, and the **adapter pattern** to achieve:
- Type safety through module types
- Provider independence via dependency injection
- Clear separation between deploy-time (Pulumi) and runtime (Lambda) concerns

[**Learn more about the Component Structure Pattern →**](./component-structure-pattern.md)

### Other Architectural Patterns

The framework employs several other important patterns:

- [**Messages**](./messages.md) - How messages flow through the system
- [**Runtime & Deployment**](./runtime.md) - Runtime environments and deployment strategies
- [**Pulumi Integration**](./pulumi.md) - Deploy-time vs runtime separation
- [**Resources**](./resources.md) - Resource management patterns
- [**Serialization**](./serialization.md) - Data encoding and decoding
- [**MCP (Model Context Protocol)**](./mcp.md) - AI-native access via tools and resources

## AWS Adapter Implementations

Provider-specific implementations of framework components:

- [**CommandGenerator**](/infrastructure/aws/adapters/commandgenerator)
- [**CommandTopic**](/infrastructure/aws/adapters/commandtopic)
- [**EventCollector**](/infrastructure/aws/adapters/eventcollector)
- [**EventLog**](/infrastructure/aws/adapters/eventlog)
- [**EventTopic**](/infrastructure/aws/adapters/eventtopic)
- [**ScheduledPublisher**](/infrastructure/aws/adapters/scheduledpublisher)
- [**Task**](/infrastructure/aws/adapters/task)

## Understanding the Framework

To effectively work with Reventless, understanding these architectural patterns is essential:

1. **Start with the Component Structure Pattern** - This is foundational to understanding how all components are organized
2. **Learn the Message Flow** - Understand how commands and events move through the system
3. **Study Pulumi Integration** - See how infrastructure is defined and deployed
4. **Explore AWS Adapters** - Learn how abstract components map to concrete AWS services

## For Contributors

If you're contributing to the framework or creating custom components:

1. Read the [Component Structure Pattern](./component-structure-pattern.md) guide thoroughly
2. Study existing components like `EventLog` for reference
3. Follow the established patterns for consistency
4. Ensure proper separation between interface, construction, and runtime logic

## Related Documentation

- [Component Overview](/app/component-overview) - High-level component architecture
- [ReScript Syntax](/app/rescript-syntax) - Language features used in the framework
