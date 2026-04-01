# Lambda Runtime Patterns

## Deployment Strategies

### Single (Default)

One Lambda function handles all aggregates and event collectors. Simplest to deploy, lowest cost at low scale.

```
Lambda "AllAggregates" → handles all command topics
Lambda "AllEventCollectors" → handles all event projections
```

**Builder:** `AggregateRuntime_Builder_Single`, `EventCollectorRuntime_Builder_Single`

**When to use:** Development, small applications, low traffic.

### PerAggregate

One Lambda function per aggregate type. Better isolation, independent scaling.

```
Lambda "ProductAggregate" → handles Product commands only
Lambda "OrderAggregate" → handles Order commands only
Lambda "AllEventCollectors" → handles all projections
```

**Builder:** `AggregateRuntime_Builder_PerAggregate`, `EventCollectorRuntime_Builder_PerEventCollector`

**When to use:** Production workloads with uneven traffic patterns across aggregates.

### Micro

Most granular — separate Lambda for each command type, each projection, each side effect.

```
Lambda "Product_Add" → handles Add command only
Lambda "Product_UpdatePrice" → handles UpdatePrice only
Lambda "ProductsReadModel_Projection" → handles Products projection only
```

**Builder:** `AggregateRuntime_Builder_Micro`

**When to use:** High-scale applications needing per-operation scaling and monitoring.

## Runtime Builder Pattern

All runtime builders follow the same pattern:

```rescript
// Deploy-time: create runtime configuration
module Runtime = AggregateRuntime_Builder_Single.Make(Platform)

// Runtime creates Lambda functions with appropriate:
// - SQS event sources (for command topics)
// - DynamoDB stream sources (for event collectors)
// - IAM roles with scoped permissions
// - Environment variables with resource ARNs
```

## Lambda Handler Entry Points

Entry point files (`.mjs`) bootstrap the Lambda handler:

- `AggregateEntryPoint.mjs` — processes SQS messages as commands
- `EventCollectorEntryPoint.mjs` — processes DynamoDB stream records as events
- `HeartbeatEntryPoint.mjs` — periodic tick handler
- `TaskEntryPoint.mjs` — S3 event handler
- `ClonerEntryPoint.mjs` — data migration handler

## Lambda Layer

Framework code is packaged as a Lambda Layer to reduce cold start times and deployment size:

- Layer contains: reventless-core, reventless-aws, rescript-aws-sdk, and all framework dependencies
- Application Lambda only contains app-specific code (specs, behaviors, slices)
- Layer ARN is managed via CI/CD and updated in `reventless-layer-builder`
