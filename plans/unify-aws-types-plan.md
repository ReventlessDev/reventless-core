# Centralize AWS Type Definitions in Reventless

## Status: ✅ IMPLEMENTED

## Problem Statement

AWS-specific types like `AppSync.GraphQLApi` and `IAM.Role` are currently defined inconsistently across multiple files in the `reventless-aws` package:

### Current Issues

1. **Inconsistent Type References**
   - Some files use fully qualified paths: `Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>`
   - Others use shortened paths after `open PulumiAws`: `Pulumi.Output.t<AppSync.GraphQLApi.t>`
   - This inconsistency leads to confusion and potential import issues

2. **Duplicated Type Definitions**
   The same `api` and `role` type aliases are duplicated in at least 7 files:
   
   | File | Type Definition |
   |------|-----------------|
   | `src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | `type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>` |
   | `src/components/Plugin.res` | `type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>` |
   | `src/adapter/QueryDb/QueryDbStorage_DynamoDb.res` | `type api = Pulumi.Output.t<AppSync.GraphQLApi.t>` |
   | `src/adapter/QueryDb/QueryDbStorage_DynamoDbStream.res` | `type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>` |
   | `src/adapter/Cloner/ClonerRunner_Fargate.res` | `type api = Pulumi.Output.t<AppSync.GraphQLApi.t>` |
   | `src/components/Counter_Builder.res` | `let api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>` |
   | `src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res` | `type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>` |

3. **Tight Coupling with Pulumi Types**
   - The `reventless` package has abstract types `api` and `role` that are meant to be polymorphic
   - These get concretely tied to AppSync-specific types in implementation files
   - Makes it harder to support other API backends in the future

## Proposed Solution

Create a single central types module in the `reventless-aws` package.

### Implementation Plan

#### 1. Create a Single Central Types Module ✅

Created `packages/reventless-aws/src/Types.res`:

```rescript
/** Central type definitions for AWS resources used by Reventless.
  * 
  * All AWS-specific types should be defined here and imported from 
  * this module rather than directly from PulumiAws.
  * 
  * Usage: Since we're in the same package, use types directly:
  *   type api = Types.AppSync.api
  *   type role = Types.AppSync.role
  */

open PulumiAws

module AppSync = {
  // Base Pulumi types first
  type graphQLApi = AppSync.GraphQLApi.t
  type resolver = AppSync.Resolver.t
  type dataSource = AppSync.DataSource.t
  type function_ = AppSync.Function.t
  
  // Then types that use the base types (Output-wrapped)
  type api = Pulumi.Output.t<graphQLApi>
  type role = Pulumi.Output.t<IAM.Role.t>
}

module DynamoDb = {
  type table = DynamoDb.Table.t
}

module SQS = {
  type queue = SQS.Queue.t
}

module SNS = {
  type topic = SNS.Topic.t
}

module Lambda = {
  type function_ = Lambda.Function.t
  type role = IAM.Role.t
}

// ... etc for other services
```

#### 2. Update All Files to Use Central Types ✅

Replaced duplicated type definitions with imports from the central module using direct type references:

| File | New Pattern |
|------|-------------|
| `src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | `Types.AppSync.api`, `Types.AppSync.role` |
| `src/components/Plugin.res` | `Types.AppSync.api`, `Types.AppSync.role` |
| `src/adapter/QueryDb/QueryDbStorage_DynamoDb.res` | `Types.AppSync.api`, `Types.AppSync.role` |
| `src/adapter/QueryDb/QueryDbStorage_DynamoDbStream.res` | `Types.AppSync.api`, `Types.AppSync.role` |
| `src/adapter/Cloner/ClonerRunner_Fargate.res` | `Types.AppSync.api` |
| `src/components/Counter_Builder.res` | `Types.AppSync.api`, `Types.AppSync.role` |
| `src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res` | `Types.AppSync.api` |
| `src/util/Util_AppSync.res` | `Types.AppSync.resolver` |

## Benefits

1. **Single Source of Truth**: All AWS type definitions in one place
2. **Easier Maintenance**: Change AWS type in one location, propagates everywhere
3. **Consistency**: Eliminates the mixed usage of qualified vs. unqualified type paths
4. **Explicit Dependencies**: Using direct type references makes it clear where types come from (no hidden imports via `open`)
5. **Future-Proofing**: Easier to add support for other API backends (GraphQL servers other than AppSync)
6. **Type Safety**: Compiler ensures all files use the same types

## Backward Compatibility

- The new `Types` module is additive
- Existing code using direct Pulumi imports continues to work

## Alternative Considerations

### Option 2: Use Type Aliases in reventless package
Instead of defining types in `reventless-aws`, define them in `reventless` with abstract types that get constrained by the implementing packages.

**Pros**: More abstraction, better support for alternative backends
**Cons**: More complex, requires changes to the core `reventless` package

### Option 3: Use Functors for Type Injection
Pass AWS types through functors from the implementation package.

**Pros**: Maximum flexibility
**Cons**: Significant refactoring, may break existing code

## Recommendation

**Proceed with this approach** (Single Types Module + Direct Type References) as it:
- Provides immediate benefits with minimal disruption
- Uses clear, explicit type paths (no `open` statements)
- Defines base Pulumi types first, then wrapped types (proper dependency order)
- Since we're in the same package, no need for full package qualification
- Can be implemented incrementally
- Sets the foundation for future abstraction if needed
