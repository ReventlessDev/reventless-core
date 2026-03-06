# Azure Cloud Provider Analysis

**Date**: 2026-03-06
**Scope**: Feasibility and effort analysis for implementing `reventless-azure` as a second cloud provider alongside `reventless-aws`.

## Executive Summary

Azure provides viable counterparts for nearly all AWS services used by Reventless. The core adapter architecture (`reventless-core`, `reventless-infra`, `reventless-spec`) is already designed for provider-agnostic operation with pluggable cloud implementations. However, several semantic differences between AWS and Azure services would require careful handling, and a few areas present significant gaps or behavioral mismatches.

**Overall feasibility**: High — the architecture supports it by design.
**Estimated effort**: Large (comparable to the original `reventless-aws` package: ~130 source files).
**Core package changes required**: Minimal to moderate — mostly in infrastructure/Pulumi layers, not in domain logic.

---

## 1. Service Mapping: AWS to Azure

### 1.1 Direct Equivalents (Low Risk)

| Reventless Component | AWS Service | Azure Service | Notes |
|----------------------|-------------|---------------|-------|
| **EventLog Storage** | DynamoDB (table) | Azure Cosmos DB (NoSQL API) | Cosmos DB supports partition key + sort key, consistent reads, conditional writes. Good fit. |
| **QueryDb Storage** | DynamoDB (table + GSIs) | Azure Cosmos DB (NoSQL API) | Cosmos DB supports secondary indexes (composite indexes, unique keys). Different indexing model — see Section 3. |
| **Task Bucket** | S3 | Azure Blob Storage | Event Grid triggers on blob create/delete replace S3 event notifications. |
| **Serverless Compute** | Lambda | Azure Functions | Similar event-driven model. Supports SQS-equivalent triggers. |
| **IAM / Access Control** | IAM Roles + Policies | Azure Managed Identities + RBAC | Different model but equivalent capability. |
| **Scheduling** | CloudWatch Events / EventBridge Scheduler | Azure Logic Apps / Azure Functions Timer Trigger | Timer triggers are simpler; Logic Apps for dynamic schedule creation. |
| **VPC / Networking** | VPC + Subnets | Azure VNet + Subnets | Structural equivalent. |

### 1.2 Functional Equivalents with Behavioral Differences (Medium Risk)

| Reventless Component | AWS Service | Azure Service | Key Differences |
|----------------------|-------------|---------------|-----------------|
| **CommandTopic Channel** | SQS FIFO | Azure Service Bus (Queues, Sessions) | Service Bus sessions provide FIFO per session ID (= message group). No content-based deduplication — must supply explicit dedup ID. See Section 3.1. |
| **EventTopic Publisher** | SNS / SNS FIFO | Azure Service Bus (Topics + Subscriptions) | Service Bus Topics replace SNS. Sessions on subscriptions provide ordering. Different subscription filter model. |
| **EventCollector Channel** | SQS + SNS subscription / DynamoDB Streams | Azure Service Bus Subscriptions / Cosmos DB Change Feed | Cosmos DB Change Feed replaces DynamoDB Streams. Different ordering guarantees — see Section 3.2. |
| **Dead-Letter Queue** | SQS DLQ (redrive policy) | Service Bus DLQ (built-in per queue/subscription) | Built-in DLQ on every Service Bus entity. Different redrive semantics — no automatic redrive, requires explicit peek/complete. |

### 1.3 Significant Gaps or Mismatches (High Risk)

| Reventless Component | AWS Service | Azure Candidate | Gap Description |
|----------------------|-------------|-----------------|-----------------|
| **GraphQL API** | AppSync | Azure API Management + custom resolver | **No native AppSync equivalent.** Azure has no managed GraphQL service with built-in DynamoDB/Cosmos DB resolvers. Requires custom GraphQL server (e.g., graphql-yoga on Azure Functions) or third-party service. See Section 3.3. |
| **Authentication** | Cognito | Azure AD B2C / Entra External ID | Different authentication model. Azure AD B2C is more enterprise-oriented. User pool concepts differ significantly. |
| **Event Streaming (alt)** | Kinesis | Azure Event Hubs | Good functional equivalent, but different partition/shard model. |
| **DynamoDB Streams** | DynamoDB Streams (NEW_IMAGE) | Cosmos DB Change Feed | Change Feed is pull-based (not push). Different consistency model — see Section 3.2. |

---

## 2. Detailed Component Analysis

### 2.1 EventLog Storage (DynamoDB -> Cosmos DB)

**Current AWS implementation**:
- DynamoDB table with `id` (partition key) + `sequenceNr` (sort key)
- Conditional writes for idempotency (`putIfNotExists`)
- Consistent reads for replay
- Batch writes with retry
- DynamoDB Streams for event fanout (NEW_IMAGE)

**Azure equivalent**:
- Cosmos DB container with `/id` partition key, `sequenceNr` as logical sort
- Cosmos DB supports conditional writes via ETags and optimistic concurrency
- Strong consistency available (configurable per-request or per-account)
- Bulk operations API for batch writes
- Change Feed for event fanout

**Differences to handle**:
- Cosmos DB does not have a native "sort key" in the same way as DynamoDB. The partition key determines physical distribution; within a partition, items are sorted by default on a system property. Composite keys must be modeled differently (e.g., using `/id` as partition key and querying with `ORDER BY sequenceNr`).
- Cosmos DB pricing is RU-based (Request Units) vs DynamoDB's on-demand/provisioned capacity. Cost model is fundamentally different.
- Change Feed is pull-based — requires a "change feed processor" or Azure Functions trigger to push events. No direct equivalent of DynamoDB Streams' Lambda event source mapping with batch windows.

**Effort**: Medium. Core read/write operations map well. Change Feed integration requires new patterns.

### 2.2 DcbEventLog Storage (DynamoDB + GSIs -> Cosmos DB)

**Current AWS implementation**:
- Single partition ("dcb") with position-based sort
- Global Secondary Indexes for tag-based filtering
- Tag extraction from event schemas via `@s.matches(DcbTag.string)`

**Azure equivalent**:
- Cosmos DB container with composite index on tags
- Cosmos DB supports indexing policies (include/exclude paths, composite indexes)
- Cross-partition queries with tag filters

**Differences to handle**:
- Cosmos DB's indexing model is fundamentally different from DynamoDB GSIs. Cosmos DB indexes all paths by default (tunable), while DynamoDB requires explicit GSI creation per access pattern.
- Tag-based filtering in Cosmos DB would use SQL-like queries (`SELECT * FROM c WHERE c.tags[0].key = 'categoryId' AND c.tags[0].value = 'cat-1'`) rather than GSI key conditions.
- Single-partition design ("dcb") may hit Cosmos DB's 20GB logical partition limit at scale. Needs a partitioning strategy rethink.
- Conditional append with `appendCondition` maps to Cosmos DB's optimistic concurrency via ETags, but the query-based condition check ("no matching events since position X") would need a different implementation — likely a stored procedure or transactional batch.

**Effort**: High. The tag filtering and conditional append semantics require significant rearchitecting.

### 2.3 CommandTopic Channel (SQS FIFO -> Service Bus Sessions)

**Current AWS implementation**:
- SQS FIFO queue with message group ID = aggregate ID
- Content-based deduplication
- Visibility timeout: 180s, max receive count: 5
- Dead-letter queue with redrive policy

**Azure equivalent**:
- Azure Service Bus Queue with sessions enabled
- Session ID = aggregate ID (provides FIFO per session)
- Duplicate detection window (configurable, up to 7 days)
- Lock duration (equivalent to visibility timeout)
- DLQ built-in per queue

**Differences to handle**:
- **No content-based deduplication**: Service Bus requires an explicit `MessageId` for deduplication. The framework must generate deterministic message IDs. This is a behavioral change that affects `CommandTopicChannel` adapter logic.
- **Session model**: Service Bus sessions are more powerful than SQS message groups — they maintain session state and require explicit session acceptance. The handler model changes from "process next message" to "accept session, process all messages in session."
- **Lock renewal**: Service Bus uses lock-based consumption (peek-lock) rather than visibility timeout. Long-running handlers need lock renewal. Different failure semantics.
- **Batch size**: Service Bus `receiveMessages` has different batching semantics than SQS `ReceiveMessage`.

**Effort**: Medium-High. The session model is a conceptual shift that affects handler patterns.

### 2.4 EventTopic Publisher (SNS -> Service Bus Topics)

**Current AWS implementation**:
- SNS topic (standard or FIFO) for event fanout
- SNS-SQS subscription for EventCollectors
- Batch publishing (10 events per batch)

**Azure equivalent**:
- Service Bus Topic with Subscriptions
- Each EventCollector subscribes via a Service Bus Subscription
- Sessions on subscriptions for ordered delivery
- Subscription filters (SQL-like or correlation) for content-based routing

**Differences to handle**:
- Service Bus Topics have a **subscription limit** (2,000 per topic). Not a practical concern for most deployments but different from SNS's effectively unlimited subscriptions.
- **Filter model**: Service Bus subscription filters are SQL expressions on message properties, vs SNS filter policies on message attributes. The filter syntax differs.
- Publishing batched messages uses Service Bus's `sendMessages` with `ServiceBusMessageBatch`.

**Effort**: Medium. Good conceptual match but different APIs.

### 2.5 EventCollector Channel (DynamoDB Streams -> Cosmos DB Change Feed)

**Current AWS implementation**:
- DynamoDB Streams with NEW_IMAGE stream view
- Lambda event source mapping with batch window
- Alternatively: SQS FIFO subscription to SNS topic

**Azure equivalent**:
- Cosmos DB Change Feed with Azure Functions trigger
- Alternatively: Service Bus Subscription trigger on Azure Functions

**Differences to handle**:
- **Change Feed is pull-based**: No direct push model like DynamoDB Streams -> Lambda. The Azure Functions Cosmos DB trigger uses a lease-based processor that polls for changes. This introduces latency (configurable polling interval).
- **Change Feed ordering**: Changes are ordered within a logical partition, but cross-partition ordering is not guaranteed. For EventLog (partitioned by aggregate ID), this works. For DcbEventLog (potentially cross-partition), this needs careful design.
- **No "old image"**: Cosmos DB Change Feed only provides the new version of the document (like DynamoDB's NEW_IMAGE), which is what Reventless uses. Compatible.
- **Checkpoint management**: Change Feed processor manages checkpoints via a "lease container." Different from DynamoDB Streams' shard iterator model.

**Effort**: Medium. The pull-based model requires different wiring but the Azure Functions trigger abstracts most complexity.

### 2.6 QueryDb Storage (DynamoDB + GSIs -> Cosmos DB)

**Current AWS implementation**:
- DynamoDB table with configurable GSIs
- Projection types: ALL, KEYS_ONLY, INCLUDE
- TTL support
- AppSync data source binding

**Azure equivalent**:
- Cosmos DB container with composite indexes
- Indexing policy instead of explicit GSIs
- TTL support (native in Cosmos DB)
- No AppSync equivalent — see Section 3.3

**Differences to handle**:
- **Index model**: Cosmos DB indexes all properties by default. "GSI" equivalent is achieved through composite indexes in the indexing policy. The `indexConfig` type in the adapter would need to be translated to Cosmos DB indexing policy definitions.
- **Query patterns**: DynamoDB's key-value query model (`Query` with key condition) vs Cosmos DB's SQL query API. The adapter would need to translate query operations.
- **Throughput**: Cosmos DB's RU model vs DynamoDB's read/write capacity units. Different cost optimization strategies.

**Effort**: Medium. Good functional match but different query/index semantics.

### 2.7 GraphQL API (AppSync -> Custom Solution)

**Current AWS implementation**:
- AppSync with auto-generated schema stitching
- DynamoDB data sources with resolver mapping templates
- Cognito user pool authorization
- Schema introspection and type generation

**Azure equivalent**:
- **No direct equivalent.** Options:
  1. **Azure Functions + graphql-yoga**: Self-hosted GraphQL server on serverless compute. Requires custom resolver implementation.
  2. **Azure API Management**: Can proxy a GraphQL backend but doesn't provide resolver logic.
  3. **Third-party**: Hasura, Apollo Server on Azure Container Apps.

**Differences to handle**:
- The `Util_AppSync.res` module (schema stitching, resolver generation, data source binding) has **no Azure counterpart**. This is the largest gap.
- `CommandGeneratorResolvers` (AppSync -> Commands) would need a completely different implementation — likely a custom GraphQL server with resolvers that publish to Service Bus.
- The `Api` component builder and `Core_Builder` wiring around AppSync would need Azure-specific alternatives.

**Effort**: Very High. This is effectively a new component, not a port.

### 2.8 Authentication (Cognito -> Azure AD B2C / Entra External ID)

**Current AWS implementation**:
- Cognito User Pools for user management
- Cognito groups for authorization
- AppSync Cognito authorization

**Azure equivalent**:
- Azure AD B2C or Entra External ID
- Custom policies for user flows
- JWT token validation in Azure Functions / API Management

**Differences to handle**:
- Completely different user management APIs
- Authorization model differs (Cognito groups vs Azure AD roles/claims)
- Token format and validation differ

**Effort**: High. Different paradigm, needs full reimplementation.

---

## 3. Critical Semantic Differences

### 3.1 Message Deduplication

**AWS (SQS FIFO)**: Content-based deduplication — SQS hashes the message body and deduplicates within a 5-minute window automatically.

**Azure (Service Bus)**: Requires explicit `MessageId` for deduplication. The framework must:
1. Generate deterministic message IDs (e.g., hash of command payload + aggregate ID)
2. Set the deduplication detection window on the queue

**Impact**: The `CommandTopicChannel` adapter contract may need an optional deduplication ID field, or the Azure adapter must compute it internally. If computed internally, no core changes needed.

### 3.2 Change Data Capture Ordering

**AWS (DynamoDB Streams)**: Provides ordered stream of changes per partition (shard). Lambda processes events in order within a shard. Failed batches block the shard (back-pressure).

**Azure (Cosmos DB Change Feed)**: Pull-based, ordered within a logical partition. The Azure Functions trigger processes changes in feed-page order. Failed processing does not block the feed — the lease just doesn't advance. However, there's no built-in back-pressure to the writer.

**Impact**: Error handling in EventCollector adapters would behave differently. AWS blocks on failure (retry same batch); Azure skips and retries on next poll. This could affect event ordering guarantees under failure conditions. May need a custom error-handling wrapper.

### 3.3 No Managed GraphQL Service

AppSync is deeply integrated into the current `reventless-aws` package:
- `Util_AppSync.res` handles schema stitching across plugins
- `CommandGeneratorResolvers` auto-wire GraphQL mutations to command topics
- `QueryDb` auto-generates AppSync data sources and resolvers
- The `Api` component builder creates the entire AppSync API

**Impact on core packages**: The `Api` component and `CommandGenerator` interfaces reference AppSync concepts. Two options:
1. **Abstract the GraphQL layer** into a provider-agnostic interface in `reventless-infra` (requires core changes)
2. **Implement a custom GraphQL server** in `reventless-azure` that mimics AppSync behavior (no core changes, but high effort)

Option 2 is recommended to minimize core disruption.

### 3.4 Cosmos DB Partition Limits

DynamoDB has a 10GB partition limit (but handles splits automatically). Cosmos DB has a **20GB logical partition limit** that is hard. For the DcbEventLog's single-partition design ("dcb"), this could become a scaling bottleneck on Azure.

**Impact**: The DcbEventLog may need a different partitioning strategy on Azure — e.g., time-based partitioning or hash-based distribution with scatter-gather queries. This would be an Azure-specific concern handled in the adapter.

---

## 4. Required Changes in Other Packages

### 4.1 No Changes Required

| Package | Reason |
|---------|--------|
| `reventless-spec` | Pure type definitions, no cloud dependencies |
| `reventless` (core) | Provider-agnostic by design; adapter interfaces are already abstract |
| `rescript-uuid`, `rescript-hash-object`, etc. | Utility packages, no cloud coupling |
| `reventless-in-memory` | Test platform, independent of cloud providers |
| `reventless-gen` | Code generation, cloud-agnostic |

### 4.2 Minimal Changes Likely Required

| Package | Change | Reason |
|---------|--------|--------|
| `reventless-infra` | Add Azure resource type identifiers | The `resource.service` field identifies the cloud provider. Azure resources need new service type constants. |
| `reventless-infra` | Optional: abstract GraphQL API interface | If we want a provider-agnostic API component (recommended for long term). |

### 4.3 New Packages Required

| Package | Location | Purpose |
|---------|----------|---------|
| `reventless-azure` | `reventless/reventless-azure/` | Azure adapter implementations (main deliverable) |
| `rescript-azure-sdk` | `rescript/rescript-azure-sdk/` | ReScript bindings for Azure SDK (`@azure/cosmos`, `@azure/service-bus`, `@azure/storage-blob`, `@azure/identity`, `@azure/functions`) |
| `rescript-pulumi-azure` | `rescript/rescript-pulumi-azure/` | ReScript bindings for `@pulumi/azure-native` |

### 4.4 Pulumi Consideration

The deploy-time layer uses Pulumi, which has first-class Azure support via `@pulumi/azure-native`. This is a significant advantage — the Pulumi resource model, `Output.t<'a>` wrapping, and component resource pattern all work identically on Azure. No changes to the Pulumi integration pattern are needed.

---

## 5. Effort Estimation

### 5.1 Work Breakdown

| Work Item | Estimated Size | Complexity |
|-----------|---------------|------------|
| **ReScript Azure SDK bindings** (`rescript-azure-sdk`) | ~40 files | Medium — straightforward FFI wrapping |
| **ReScript Pulumi Azure bindings** (`rescript-pulumi-azure`) | ~30 files | Medium — follows existing `rescript-pulumi-aws` patterns |
| **EventLog adapter** (Cosmos DB) | ~8 files | Medium |
| **DcbEventLog adapter** (Cosmos DB + custom indexing) | ~10 files | High |
| **CommandTopic adapter** (Service Bus Sessions) | ~8 files | Medium-High |
| **EventTopic adapter** (Service Bus Topics) | ~6 files | Medium |
| **EventCollector adapter** (Change Feed + Service Bus) | ~8 files | Medium-High |
| **QueryDb adapter** (Cosmos DB) | ~8 files | Medium |
| **Task adapter** (Blob Storage + Event Grid) | ~6 files | Medium |
| **Scheduler adapter** (Timer Triggers / Logic Apps) | ~4 files | Low-Medium |
| **GraphQL API replacement** (graphql-yoga on Functions) | ~15 files | Very High |
| **Authentication adapter** (Azure AD B2C) | ~8 files | High |
| **Error handling** (Azure-specific error classification) | ~6 files | Medium |
| **Runtime builders** (Azure Functions variants) | ~10 files | Medium |
| **Component builders** (Azure wiring) | ~15 files | Medium |
| **Platform entry point** | ~3 files | Low |
| **Utility modules** | ~20 files | Medium |
| **`reventless-infra` changes** | ~3 files | Low |
| **Tests** | ~40 files | Medium-High |
| **Documentation** | ~10 pages | Medium |

### 5.2 Total Estimate

- **New ReScript source files**: ~200 (vs ~130 for AWS, due to SDK bindings overhead)
- **Relative effort vs `reventless-aws`**: ~1.3-1.5x (additional SDK binding work + GraphQL gap)
- **Critical path**: GraphQL API replacement and DcbEventLog partitioning strategy

### 5.3 Suggested Implementation Order

1. **Phase 1 — Foundation**: `rescript-azure-sdk`, `rescript-pulumi-azure`, error handling
2. **Phase 2 — Storage**: EventLog, QueryDb, DcbEventLog adapters (Cosmos DB)
3. **Phase 3 — Messaging**: CommandTopic, EventTopic, EventCollector adapters (Service Bus)
4. **Phase 4 — Compute**: Azure Functions runtime builders, Task adapter (Blob Storage)
5. **Phase 5 — API**: GraphQL server, Authentication adapter
6. **Phase 6 — Integration**: Component builders, Platform assembly, E2E tests

---

## 6. Risk Assessment

### 6.1 High Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **No managed GraphQL service** | Requires building custom GraphQL server; significant development and maintenance burden | Start with graphql-yoga on Azure Functions. Consider abstracting the API layer in core for long-term multi-cloud support. |
| **Cosmos DB partition limit (20GB)** for DcbEventLog | Single-partition DCB design may hit hard limit at scale | Design Azure-specific partitioning strategy early. Consider time-bucketed partitions with scatter-gather reads. |
| **Service Bus session model mismatch** | Handler model is fundamentally different from SQS message-level consumption. Could introduce subtle ordering bugs. | Build comprehensive integration tests. Prototype the session-based handler pattern early to validate. |
| **Change Feed eventual consistency** | Pull-based model may introduce higher latency and different failure semantics than DynamoDB Streams | Benchmark Change Feed latency. Implement explicit error handling with dead-letter patterns. |

### 6.2 Medium Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **ReScript Azure SDK bindings maintenance** | Azure SDK has frequent breaking changes; binding maintenance is ongoing | Pin SDK versions. Generate bindings semi-automatically where possible. |
| **Cost model differences** | Cosmos DB RU pricing may surprise users coming from DynamoDB on-demand | Document cost implications. Provide capacity planning guidance. |
| **Pulumi Azure provider maturity** | `@pulumi/azure-native` is actively maintained but may lag behind Azure API updates | Pin provider versions. Test with latest Azure features needed. |
| **Authentication model differences** | Azure AD B2C has different user management paradigm than Cognito | Abstract auth interface early. Support both identity providers behind a common contract. |
| **Dual maintenance burden** | Two cloud providers means every framework change must be implemented twice | Ensure adapter interfaces are well-defined. Consider shared test suites that validate adapter contracts generically. |

### 6.3 Low Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Blob Storage event triggers** | Event Grid may have different delivery guarantees than S3 events | Event Grid provides at-least-once delivery, similar to S3. Low risk of mismatch. |
| **Scheduling** | Timer triggers / Logic Apps well-understood | Straightforward implementation. |
| **IAM / RBAC differences** | Different authorization model but well-documented | Pulumi abstracts most of this. |
| **Core package contamination** | Risk that Azure-specific concerns leak into core | Existing adapter pattern already prevents this. Enforce in code review. |

---

## 7. Recommendations

1. **Start with a proof-of-concept** for the three highest-risk areas: Cosmos DB EventLog, Service Bus CommandTopic, and a custom GraphQL API on Azure Functions. This validates the core adapter contracts work for Azure before committing to a full implementation.

2. **Do not modify core packages initially.** The existing adapter interfaces should be sufficient for Azure. If gaps are found during PoC, evaluate targeted extensions rather than redesigns.

3. **Consider abstracting the API/GraphQL layer** in `reventless-infra` as a longer-term improvement. This benefits both AWS (AppSync could become one option among several) and Azure.

4. **Invest heavily in integration tests.** The semantic differences between AWS and Azure services mean that unit tests alone won't catch ordering, consistency, and failure-mode issues. A shared adapter contract test suite (using the existing in-memory platform as a reference implementation) would be valuable.

5. **Design the DcbEventLog partitioning strategy for Azure upfront.** This is the area where AWS and Azure diverge most, and retrofitting a partitioning strategy is much harder than designing it from the start.

6. **Document cost model differences.** Users choosing between AWS and Azure deployments need clear guidance on cost implications, especially around Cosmos DB RU consumption vs DynamoDB pricing.
