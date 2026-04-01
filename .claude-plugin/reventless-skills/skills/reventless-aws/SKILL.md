---
name: reventless-aws
description: >-
  AWS deployment patterns for Reventless platforms. Use when deploying
  to AWS, configuring infrastructure, working with Pulumi, or understanding
  the DynamoDB/Lambda/SQS/SNS adapter architecture.
---

## Purpose

Provides AWS-specific deployment patterns for Reventless applications. Covers the adapter architecture (how framework components map to AWS services), Pulumi infrastructure-as-code patterns, Lambda runtime strategies, and DynamoDB table design.

## When to Use

- Deploying a Reventless platform to AWS
- Switching from in-memory platform to AWS platform
- Configuring Pulumi stacks and component resources
- Understanding DynamoDB table design for event logs and query databases
- Choosing Lambda deployment strategy (Single, PerAggregate, Micro)
- Working with SQS FIFO queues, SNS topics, or S3 buckets

## Reference Files

| File | Content |
|------|---------|
| `references/adapter-architecture.md` | AWS adapters: DynamoDB, Lambda, SQS, SNS, S3 |
| `references/runtime-patterns.md` | Single, PerAggregate, Micro deployment strategies |
| `references/pulumi-patterns.md` | Output.t wrapping, component resources, stacks |
| `references/dynamodb-design.md` | Table design for EventLog, QueryDb, DcbEventLog |

## Key Differences from In-Memory

| Aspect | In-Memory | AWS |
|--------|-----------|-----|
| Platform | `ReventlessInMemory.Platform.Make()` | `ReventlessAws.Platform.Make()` |
| Event storage | In-memory arrays | DynamoDB tables |
| Command delivery | Direct function calls | SQS FIFO queues |
| Event publication | In-memory bus | SNS topics |
| Query storage | In-memory maps | DynamoDB tables |
| API | GraphQL Yoga (port 4000) | AppSync GraphQL |
| MCP | HTTP server (port 3001) | Lambda Function URL |
| Compute | Node.js process | Lambda functions |
| Infrastructure | None | Pulumi IaC |

## Related Skills

- `reventless-app` — generates platform-agnostic code that works with both in-memory and AWS
- `rescript` — ReScript patterns including Pulumi.Output.t wrapping
