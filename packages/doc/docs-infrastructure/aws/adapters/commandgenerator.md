---
title: "CommandGenerator → Lambda + EventBridge Pipes"
date: 2026-01-15
draft: false
---

## CommandGenerator → AppSync

The CommandGenerator adapter provides GraphQL-based command generation using AWS AppSync, enabling web and mobile clients to generate commands through a type-safe GraphQL API that integrates with Reventless aggregates.

## How CommandGenerator Works

CommandGenerator creates a bridge between GraphQL mutations and Reventless commands:

1. **Client** sends a GraphQL mutation (e.g., `createOrder`, `updateUser`)
2. **AppSync Resolver** invokes a Lambda function with mutation arguments
3. **Lambda** runs the command generator function to create a Reventless command
4. **Command** is published to the appropriate CommandTopic (SQS queue)
5. **Aggregate** processes the command and emits events

This pattern enables frontend applications to interact with event-sourced aggregates through a familiar GraphQL API.

## Deploy-time Configuration

The CommandGenerator adapter creates AppSync resolvers, Lambda functions, and IAM roles:

```rescript
let make: Reventless.CommandGenerator_Adapter.resolversMaker<api, Util.Lambda.runtimeParts> = (
  ~name: string,
  ~api: api,
  ~fields,
  ~runtime,
  ~resources: array<Reventless.Adapter.resource>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  // Create IAM role for AppSync DataSource
  let dataSourceRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "DataSource",
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~opts,
  )

  // Configure Lambda permissions for SQS
  let _ =
    (lambda->Pulumi.Output.flatMap(lambda => lambda.arn),
     lambda->Pulumi.Output.flatMap(lambda => lambda.name),
     lambdaRole.id,
     resources->Reventless.Adapter.resourcesToResolvedOutput)
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((lambdaArn, lambdaName, lambdaRoleId, resources)) => {
      let targetSqsResources =
        resources->Reventless.Util.Adapter.filterSupportedResolvedResources([
          AWS.SQS.service,
          AWS.SQS_FIFO.service,
        ])

      let lambdaSqsSendPolicyDocument =
        targetSqsResources->Array.length > 0
          ? Some(PulumiAws.PolicyDocument.make(
              ~id=name ++ "SendSQS",
              ~statements=[{
                sid: "LambdaAllowSendSQS",
                effect: Allow,
                actions: Action("sqs:SendMessage"),
                resources: Resources(targetSqsResources->urns),
              }],
            ))
          : None

      let _lambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [Some(PulumiAws.Lambda.defaultLoggingPolicyDocument), lambdaSqsSendPolicyDocument]
            ->Array.keepSome,
          )->Pulumi.Output.asInput,
          role: lambdaRoleId->Pulumi.Input.make,
        },
        ~opts,
      )
    })

  // Create AppSync DataSource pointing to Lambda
  let dataSource = PulumiAws.AppSync.DataSource.make(
    ~name,
    ~args={
      type_: AWS_LAMBDA,
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      lambdaConfig: {
        PulumiAws.AppSync.DataSource.functionArn: lambda
        ->Pulumi.Output.flatMap(lambda => lambda.arn)
        ->Pulumi.Output.asInput,
      }->Pulumi.Input.make,
      serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )

  // Create resolver for each GraphQL field
  let resolvers = fields->Array.map(field => {
    let commandName = switch field->Js.String2.split("_") {
    | [_aggregate, commandName] => commandName->StringLabels.capitalize_ascii
    | _ => field->StringLabels.capitalize_ascii
    }
    PulumiAws.AppSync.Resolver.makeUnitResolver(
      ~name=field->StringLabels.capitalize_ascii,
      ~api,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~type_="Mutation"->Pulumi.Input.make,
      ~field=field->Pulumi.Input.make,
      ~requestTemplate=invokeCommandGenerator(commandName),
      ~responseTemplate=PulumiAws.AppSync.Resolver.Templates.result,
      ~opts,
    )
  })

  {resources: resolvers->Array.map(Util_AppSync.toResource)}
}
```

**Deploy-time components:**

- **DataSource IAM Role** - AppSync role with `lambda:InvokeFunction` permission
- **Lambda IAM Role** - Lambda role with `sqs:SendMessage` permission for target CommandTopics
- **AppSync DataSource** - Connects AppSync API to the Lambda function
- **AppSync Resolvers** - One resolver per GraphQL mutation field
- **Request Template** - VTL template that transforms GraphQL input to Lambda event
- **Response Template** - VTL template that returns Lambda result to GraphQL client

## Request Template

The `invokeCommandGenerator` template transforms GraphQL mutations into Lambda events:

```vtl
#set($parentTypeName = $context.info.parentTypeName)
#set($fieldName = $context.info.fieldName)
{
  "version": "2017-02-28",
  "operation": "Invoke",
  "payload": {
    "command": "${command}",
    "arguments": $utils.toJson($context.arguments),
    "meta": {
      "ip": $util.toJson($context.identity.sourceIp),
      "user": $util.toJson($context.identity.username),
      "info": $util.toJson("$parentTypeName.$fieldName")
    }
  }
}
```

**Template features:**

- **Command name extraction** - Derives command name from field name (e.g., `user_create` → `Create`)
- **Arguments passthrough** - Forwards all GraphQL arguments to Lambda
- **Metadata injection** - Adds client IP, username, and field info for audit/logging
- **Standard format** - Uses AppSync's 2017-02-28 Lambda invocation format

## Runtime Operations

The CommandGenerator runtime is minimal - it simply invokes the user-provided command generator function:

```rescript
let generateCommand = (commandGenerator, event, _) => event->commandGenerator
```

**The command generator function** (provided by the user) receives:

```rescript
type commandGeneratorEvent = {
  command: string,      // "Create", "Update", etc.
  arguments: Js.Json.t, // GraphQL mutation arguments
  meta: {
    ip: option<string>,
    user: option<string>,
    info: string,       // "Mutation.user_create"
  },
}
```

**Example command generator:**

```rescript
let generateUserCommands = (event) => {
  switch event.command {
  | "Create" =>
    let {email, name} = event.arguments->parseCreateUserArgs
    UserAggregate.Create({email, name, createdBy: event.meta.user})
  | "Update" =>
    let {id, email, name} = event.arguments->parseUpdateUserArgs
    UserAggregate.Update({id, email, name, updatedBy: event.meta.user})
  | _ => raise(UnknownCommand(event.command))
  }
}
```

**Command publishing:**

The generated command is automatically published to the appropriate CommandTopic (configured during deployment).

## Use Cases

**Web/mobile applications:**
```graphql
mutation CreateOrder {
  order_create(
    customerId: "customer-123"
    items: [{productId: "prod-1", quantity: 2}]
  ) {
    orderId
    status
  }
}
```

**Admin dashboards:**
```graphql
mutation UpdateUserProfile {
  user_update(
    userId: "user-456"
    email: "new@example.com"
    name: "New Name"
  ) {
    success
    errors
  }
}
```

**Batch operations:**
```graphql
mutation ProcessBulkActions {
  order_cancel(orderIds: ["order-1", "order-2", "order-3"]) {
    successCount
    failedIds
  }
}
```

**Key advantages:**

- **Type-safe API** - GraphQL schema provides compile-time type safety for clients
- **Auto-generated docs** - GraphQL introspection enables automatic API documentation
- **Flexible authentication** - AppSync supports Cognito, API keys, IAM, and OpenID Connect
- **Real-time subscriptions** - AppSync supports GraphQL subscriptions for real-time updates
- **Client SDK generation** - Tools like AWS Amplify auto-generate typed client SDKs
- **Managed service** - No need to manage GraphQL server infrastructure

**Integration patterns:**

1. **Direct command generation** - Mutation → Lambda → Command → Aggregate
2. **Validation layer** - Lambda validates input before generating commands
3. **Authorization** - Lambda checks permissions before command generation
4. **Transformation** - Lambda transforms GraphQL schema to domain model
5. **Enrichment** - Lambda adds metadata (user ID, timestamps) to commands

**Comparison with REST:**

| Feature | AppSync CommandGenerator | REST API |
|---------|-------------------------|----------|
| **Schema** | GraphQL (strongly typed) | OpenAPI (optional) |
| **Queries** | Single endpoint, flexible queries | Multiple endpoints |
| **Over-fetching** | Eliminated (request exactly what you need) | Common issue |
| **Versioning** | Schema evolution | URL or header versioning |
| **Real-time** | Built-in subscriptions | Requires WebSocket setup |
| **Caching** | AppSync + Apollo Client | HTTP caching headers |
| **Documentation** | Auto-generated from schema | Requires manual effort |

