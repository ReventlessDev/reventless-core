# AWS Adapter Architecture

## Service Mapping

| Reventless Component | AWS Service | Adapter Module |
|---------------------|------------|----------------|
| EventLog | DynamoDB | `EventLogStorage_DynamoDb` |
| DcbEventLog | DynamoDB | `DcbEventLogStorage_DynamoDb` |
| CommandTopic | SQS FIFO | `CommandTopicChannel_SQS_FIFO` |
| EventTopic | SNS / SNS FIFO | `EventTopicPublisher_SNS` |
| EventCollector | SQS | `EventCollectorChannel_SQS` |
| QueryDb | DynamoDB | `QueryDbStorage_DynamoDb` |
| CommandGenerator | AppSync | `CommandGeneratorResolvers_AppSync` |
| Task (buckets) | S3 | `TaskBucket_S3` |
| Heartbeat | CloudWatch Events | `HeartbeatRunner_CloudWatchEvents` |
| Scheduler | CloudWatch Events | `ScheduledPublisher_CloudWatchEvents` |
| MCP Server | Lambda Function URL | `MCP_Lambda` |
| Cloner | Fargate | `ClonerRunner_Fargate` |

## Deploy-Time vs Runtime

The framework separates infrastructure provisioning from application logic:

- **Deploy-time:** Pulumi creates AWS resources (tables, queues, topics, functions)
- **Runtime:** Lambda handlers execute business logic (command processing, event projection)

All infrastructure values are wrapped in `Pulumi.Output.t<'a>` during deploy-time. Runtime code never sees Pulumi types — it receives resolved values via Lambda environment variables or handler arguments.

## Stream-Based Change Capture

DynamoDB Streams provide change data capture:

- `EventLogStorage_DynamoDbStream` — captures event appends for projection
- `EventCollectorChannel_DynamoDbStream` — fans in events from multiple streams
- `StateTopic Publisher_DynamoDbStream` — publishes state changes
- `CounterHandler_DynamoDbStream` — triggers threshold-based automation

## IAM and Security

Each Lambda function gets a scoped IAM role:
- Event processing: `dynamodb:PutItem` on EventLog, `dynamodb:Query` on QueryDb
- Command handling: `sqs:SendMessage` on CommandTopic, `dynamodb:Query`/`PutItem` on EventLog
- Query resolvers: `dynamodb:Query` on QueryDb (read-only)
- MCP: `sqs:SendMessage` on CommandTopic, `dynamodb:Query` on QueryDb and EventLog
