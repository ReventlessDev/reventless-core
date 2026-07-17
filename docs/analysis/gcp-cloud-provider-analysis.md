# GCP Cloud Provider Analysis

**Date**: 2026-03-06
**Scope**: Feasibility and effort analysis for implementing `reventless-gcp` as a cloud provider alongside `reventless-aws`.

## Executive Summary

GCP provides strong equivalents for most AWS services used by Reventless, with some areas where GCP's offerings are arguably a better fit (Firestore's real-time listeners, Pub/Sub's global ordering) and others where significant gaps exist (no managed GraphQL service, no direct DynamoDB Streams equivalent). The core adapter architecture remains provider-agnostic and requires no changes for GCP support.

**Overall feasibility**: High — GCP's serverless ecosystem is mature and well-suited to event-sourced architectures.
**Estimated effort**: Large (comparable to `reventless-aws`: ~130-150 source files, plus SDK bindings).
**Core package changes required**: Minimal — same scope as the Azure analysis (resource type constants in `reventless-infra`).

---

## 1. Service Mapping: AWS to GCP

### 1.1 Direct Equivalents (Low Risk)

| Reventless Component | AWS Service | GCP Service | Notes |
|----------------------|-------------|-------------|-------|
| **Task Bucket** | S3 | Cloud Storage (GCS) | Eventarc triggers on object create/delete replace S3 event notifications. Very close match. |
| **Serverless Compute** | Lambda | Cloud Functions (2nd gen) / Cloud Run | Cloud Functions 2nd gen is built on Cloud Run. Supports Pub/Sub, Eventarc, and HTTP triggers. |
| **IAM / Access Control** | IAM Roles + Policies | GCP IAM + Service Accounts | Different model (service accounts vs roles) but equivalent capability. Simpler than AWS IAM in many cases. |
| **Event Streaming (alt)** | Kinesis | Pub/Sub (or Dataflow) | Pub/Sub is a superset of Kinesis for most use cases. |
| **VPC / Networking** | VPC + Subnets | VPC + Subnets | Structural equivalent. GCP's VPC is global by default. |

### 1.2 Functional Equivalents with Behavioral Differences (Medium Risk)

| Reventless Component | AWS Service | GCP Service | Key Differences |
|----------------------|-------------|---------------|-----------------|
| **EventLog Storage** | DynamoDB | Firestore (Native mode) or Bigtable | Firestore: document DB with real-time listeners. Bigtable: wide-column store, better for high-throughput append. See Section 3.1. |
| **QueryDb Storage** | DynamoDB + GSIs | Firestore (Native mode) | Firestore supports composite indexes, collection group queries. Different query model — see Section 3.2. |
| **CommandTopic Channel** | SQS FIFO | Pub/Sub with ordering keys | Pub/Sub supports ordering within a partition (ordering key). No content-based deduplication. See Section 3.3. |
| **EventTopic Publisher** | SNS / SNS FIFO | Pub/Sub (Topics + Subscriptions) | Pub/Sub natively supports fan-out via multiple subscriptions per topic. Ordering keys for FIFO behavior. |
| **EventCollector Channel** | SQS + SNS subscription / DynamoDB Streams | Pub/Sub Subscriptions / Firestore real-time listeners | Pub/Sub pull or push subscriptions. Firestore listeners as alternative to DynamoDB Streams. See Section 3.4. |
| **Dead-Letter Queue** | SQS DLQ (redrive policy) | Pub/Sub Dead-Letter Topic | Built-in DLT per subscription. Messages forwarded after max delivery attempts. |
| **Scheduling** | CloudWatch Events / EventBridge Scheduler | Cloud Scheduler | Direct equivalent. Cron-based job scheduling with Pub/Sub or HTTP targets. Very clean API. |

### 1.3 Significant Gaps or Mismatches (High Risk)

| Reventless Component | AWS Service | GCP Candidate | Gap Description |
|----------------------|-------------|---------------|-----------------|
| **GraphQL API** | AppSync | Apigee + custom resolver / Cloud Endpoints | **No native managed GraphQL service.** Same gap as Azure. Requires custom GraphQL server (graphql-yoga on Cloud Functions/Cloud Run). See Section 3.5. |
| **Authentication** | Cognito | Firebase Auth / Identity Platform | Firebase Auth is a closer match to Cognito than Azure AD B2C. User pools, social login, and custom claims are supported. Lower risk than Azure. |
| **DynamoDB Streams** | DynamoDB Streams (NEW_IMAGE) | Firestore real-time listeners / Change Streams | Different mechanism — see Section 3.4. |
| **DcbEventLog Storage** | DynamoDB + GSIs (tag-based filtering) | Firestore (composite indexes) or Bigtable | Tag-based filtering needs different indexing strategy. See Section 3.6. |

---

## 2. Detailed Component Analysis

### 2.1 EventLog Storage (DynamoDB -> Firestore or Bigtable)

**Current AWS implementation**:
- DynamoDB table with `id` (partition key) + `sequenceNr` (sort key)
- Conditional writes (`putIfNotExists`)
- Consistent reads for replay
- Batch writes with retry
- DynamoDB Streams for event fanout

**Option A: Firestore (Native mode)**

- Document model: collection `eventLogs/{id}/events/{sequenceNr}`
- Firestore supports **transactions** for conditional writes (stronger than DynamoDB's conditional expressions)
- Strong consistency by default (all reads are strongly consistent since 2021)
- Batch writes up to 500 operations per batch
- Real-time listeners for change notifications (replaces DynamoDB Streams)
- **Advantage**: Real-time listeners are push-based and more natural than DynamoDB Streams

**Option B: Bigtable**

- Wide-column model: row key = `{id}#{sequenceNr}`, column family for event data
- Extremely high throughput for append workloads
- No built-in change notifications — would need Pub/Sub integration via Cloud Functions
- Better for very high event volumes; overkill for typical workloads
- No transactions or conditional writes — needs application-level idempotency

**Recommendation**: Firestore for most use cases. Bigtable only if event throughput requirements exceed Firestore's limits (10,000 writes/sec per database).

**Differences to handle**:
- Firestore has a **1MB document size limit** and **1 write per second per document** sustained rate. EventLog entries are small, so this is not a concern.
- Firestore's subcollection model (`eventLogs/{id}/events/{sequenceNr}`) is a natural fit for the partition+sort key pattern.
- Batch writes are transactional in Firestore (all-or-nothing within 500 ops), which is actually stronger than DynamoDB's `BatchWriteItem`.

**Effort**: Medium. Firestore's document model is a good fit. Real-time listeners simplify the event fanout pattern.

### 2.2 CommandTopic Channel (SQS FIFO -> Pub/Sub with Ordering Keys)

**Current AWS implementation**:
- SQS FIFO queue with message group ID = aggregate ID
- Content-based deduplication
- Visibility timeout: 180s, max receive count: 5
- Dead-letter queue with redrive policy

**GCP equivalent**:
- Pub/Sub topic + subscription with ordering key = aggregate ID
- Ordering keys guarantee in-order delivery within the same key
- Acknowledgement deadline (equivalent to visibility timeout, default 10s, max 600s)
- Dead-letter topic after max delivery attempts
- Exactly-once delivery available (Pub/Sub exactly-once feature, GA since 2022)

**Differences to handle**:
- **No content-based deduplication**: Like Azure Service Bus, Pub/Sub requires explicit deduplication. However, Pub/Sub's **exactly-once delivery** feature (per-subscription) reduces the need for application-level deduplication significantly. When enabled, Pub/Sub guarantees each message is delivered and acknowledged exactly once.
- **Ordering key semantics**: Similar to SQS FIFO message groups. Messages with the same ordering key are delivered in order. Messages with different ordering keys may be delivered in parallel. This is a close match.
- **Push vs Pull**: Pub/Sub supports both push (HTTP endpoint) and pull subscriptions. Cloud Functions 2nd gen uses Eventarc (push-based), which is analogous to SQS -> Lambda event source mapping.
- **Acknowledgement model**: Pub/Sub uses explicit ack/nack rather than visibility timeout + delete. Messages not acknowledged within the deadline are redelivered. `modifyAckDeadline` extends the deadline (like SQS `ChangeMessageVisibility`).

**Effort**: Medium. Pub/Sub's ordering keys are a close match to SQS FIFO message groups. The exactly-once delivery feature is a bonus.

### 2.3 EventTopic Publisher (SNS -> Pub/Sub Topics)

**Current AWS implementation**:
- SNS topic (standard or FIFO)
- SNS-SQS subscription for fan-out
- Batch publishing (10 per batch)

**GCP equivalent**:
- Pub/Sub topic with multiple subscriptions
- Each subscription = one EventCollector
- Ordering keys on the topic for ordered delivery
- Batch publishing via `PublishRequest` (up to 1000 messages or 10MB per request)

**Differences to handle**:
- Pub/Sub natively unifies SNS (topics) and SQS (queues) into a single service. **This is simpler than AWS**, where SNS-SQS fan-out requires explicit subscription wiring. On GCP, a single Pub/Sub topic with multiple subscriptions handles both pub and sub.
- **Message retention**: Pub/Sub retains undelivered messages for up to 31 days (configurable). SNS has no retention — if the subscriber is down, messages are lost. Pub/Sub is more resilient.
- **Filter model**: Pub/Sub subscription filters use attribute-based filtering (key-value matching). Different syntax from SNS filter policies but similar capability.

**Effort**: Low-Medium. Pub/Sub is arguably a better fit than SNS+SQS for the EventTopic pattern.

### 2.4 EventCollector Channel (DynamoDB Streams -> Firestore Listeners / Pub/Sub)

**Current AWS implementation**:
- DynamoDB Streams with NEW_IMAGE
- Lambda event source mapping with batch window
- Alternatively: SQS subscription to SNS topic

**GCP equivalent — Option A: Firestore real-time listeners**:
- `onSnapshot` listeners receive document changes in real-time
- Push-based, ordered within a document collection
- Cloud Functions Firestore trigger (`onDocumentCreated`, `onDocumentUpdated`)
- Provides both old and new document snapshots

**GCP equivalent — Option B: Pub/Sub subscription**:
- Direct subscription to the EventTopic's Pub/Sub topic
- Cloud Functions Eventarc trigger
- Pull or push delivery

**Differences to handle**:
- **Firestore triggers are push-based** — closer to DynamoDB Streams -> Lambda than Cosmos DB Change Feed. Cloud Functions are invoked automatically on document writes. This is a good match.
- **Ordering**: Firestore triggers may fire out of order under high write rates. For EventLog (low write rate per aggregate), this is acceptable. For high-throughput scenarios, Pub/Sub with ordering keys is safer.
- **No batch window**: Firestore triggers fire per-document, not in batches. This differs from DynamoDB Streams' configurable batch window. For high-volume EventCollectors, Pub/Sub subscriptions with batch delivery are preferable.

**Recommendation**: Use Pub/Sub subscriptions as the primary EventCollector channel (simpler, supports batching and ordering). Use Firestore triggers only for internal event propagation (replacing DynamoDB Streams' role within an aggregate).

**Effort**: Medium. Two implementation paths to maintain, but both are well-supported.

### 2.5 QueryDb Storage (DynamoDB + GSIs -> Firestore)

**Current AWS implementation**:
- DynamoDB table with configurable GSIs
- Projection types: ALL, KEYS_ONLY, INCLUDE
- TTL support
- AppSync data source binding

**GCP equivalent**:
- Firestore collection with composite indexes
- Automatic indexing for single-field queries
- Composite indexes for multi-field queries (defined in `firestore.indexes.json`)
- TTL support (field-level TTL policies, GA since 2023)
- No AppSync equivalent

**Differences to handle**:
- **Indexing model**: Firestore automatically indexes every field individually. Composite indexes must be explicitly created (similar to DynamoDB GSIs but defined declaratively). The `indexConfig` adapter type maps reasonably well.
- **Query limitations**: Firestore queries have restrictions — no `!=` on multiple fields, no `OR` across different fields (requires multiple queries + client-side merge), inequality filters on only one field per query. These may constrain read model query patterns.
- **Collection group queries**: Firestore can query across all subcollections with the same name. This is a powerful feature with no DynamoDB equivalent, potentially simplifying cross-aggregate read models.
- **No projection types**: Firestore always returns full documents. No KEYS_ONLY or INCLUDE equivalents. Field masking is available in some SDKs but not at the index level.

**Effort**: Medium. Good fit for most read model patterns, but query limitations need documentation.

### 2.6 Task Bucket (S3 -> Cloud Storage)

**Current AWS implementation**:
- S3 bucket with event notifications to Lambda
- Object create/delete triggers
- IAM policies for read/write access

**GCP equivalent**:
- Cloud Storage bucket with Eventarc triggers to Cloud Functions
- Object finalize/delete notifications
- IAM bindings for service accounts

**Differences to handle**:
- **Near-identical model.** Cloud Storage + Eventarc is a close match to S3 + Lambda event notifications.
- **Eventarc** provides more flexible event routing than S3's direct notification configuration. Events flow through Eventarc channels and can be filtered.
- Object finalize = object create (after upload completes). Same semantics as S3's `s3:ObjectCreated:*`.

**Effort**: Low. Straightforward port.

### 2.7 Scheduling (CloudWatch Events -> Cloud Scheduler)

**Current AWS implementation**:
- CloudWatch Events rules with cron expressions
- Targets Lambda functions

**GCP equivalent**:
- Cloud Scheduler jobs with cron expressions
- Targets: Pub/Sub topics, HTTP endpoints, App Engine
- For Reventless: Cloud Scheduler -> Pub/Sub topic -> Cloud Functions

**Differences to handle**:
- Cloud Scheduler requires a Pub/Sub topic or HTTP endpoint as target (cannot directly invoke Cloud Functions). This adds a Pub/Sub topic intermediary but is operationally identical.
- Cron expression syntax is compatible.

**Effort**: Low. Straightforward port with minor wiring difference.

### 2.8 GraphQL API (AppSync -> Custom Solution)

**Current AWS implementation**:
- AppSync with auto-generated schema stitching
- DynamoDB/Firestore data sources with resolver mapping
- Cognito authorization

**GCP equivalent**:
- **No direct equivalent.** Same gap as Azure. Options:
  1. **Cloud Functions/Cloud Run + graphql-yoga**: Self-hosted GraphQL server on serverless compute
  2. **Apigee**: API management platform, can proxy GraphQL but doesn't provide resolver logic
  3. **Cloud Endpoints**: OpenAPI-based, no native GraphQL support

**Impact**: Same as Azure — the AppSync integration (`Util_AppSync.res`, `CommandGeneratorResolvers`, `Api` component) has no GCP counterpart and must be reimplemented as a custom GraphQL server.

**Effort**: Very High. Same scope as the Azure analysis.

### 2.9 Authentication (Cognito -> Firebase Auth / Identity Platform)

**Current AWS implementation**:
- Cognito User Pools
- Cognito groups for authorization
- AppSync Cognito authorization

**GCP equivalent**:
- Firebase Auth (consumer) or Identity Platform (enterprise)
- Social login, email/password, phone auth
- Custom claims for authorization (replaces Cognito groups)
- JWT token validation in Cloud Functions

**Differences to handle**:
- Firebase Auth is a **closer match to Cognito** than Azure AD B2C. Both are consumer-oriented identity services with similar concepts (user pools, providers, custom attributes).
- Custom claims (up to 1000 bytes) replace Cognito groups. Different API but similar capability.
- Firebase Auth integrates well with Firestore security rules, but since Reventless uses server-side access, this is less relevant.
- Token validation: Firebase Admin SDK provides `verifyIdToken()` — straightforward to use in Cloud Functions.

**Effort**: Medium. Closer conceptual match to Cognito than Azure's offering.

---

## 3. Critical Semantic Differences

### 3.1 Storage Model: Document DB vs Key-Value

**AWS (DynamoDB)**: Key-value/wide-column store. Partition key + sort key. Items are flat (attributes at top level). GSIs are separate data structures with their own throughput.

**GCP (Firestore)**: Document-oriented with hierarchical collections. Documents can contain subcollections. Indexes are automatic for single fields, explicit for composites. No separate "throughput" per index.

**Impact**: The EventLog's `id + sequenceNr` pattern maps to Firestore's `collection/document/subcollection/document` hierarchy naturally: `eventLogs/{aggregateId}/events/{sequenceNr}`. This is arguably a **better fit** than DynamoDB's flat table model. However, adapter code must handle Firestore's query syntax (`where`, `orderBy`, `limit`) instead of DynamoDB's `KeyConditionExpression`.

### 3.2 Query Limitations in Firestore

Firestore has specific query restrictions that don't exist in DynamoDB:
- Inequality filters (`<`, `<=`, `>`, `>=`, `!=`) can only be applied to **one field** per query
- `OR` queries across different fields require multiple queries + client-side merge
- `array-contains` can only appear once per query
- No arbitrary expressions in filters (unlike DynamoDB's `FilterExpression`)

**Impact**: Some read model query patterns that work on DynamoDB may need restructuring for Firestore. The QueryDb adapter may need to document supported vs unsupported query patterns, or implement client-side query composition for complex cases.

### 3.3 Pub/Sub Ordering Guarantees

**AWS (SQS FIFO)**: Strict FIFO within a message group. Messages are dequeued in exact order. Blocked on failure (retry same message).

**GCP (Pub/Sub with ordering keys)**: In-order delivery within the same ordering key, **but only if the subscriber processes messages sequentially**. If a message fails (nack), subsequent messages with the same ordering key are also held back until the failed message is resolved. This is similar to SQS FIFO's behavior.

**Important caveat**: If ordering is enabled and a message is nacked, Pub/Sub **pauses delivery for that ordering key** until the message is successfully acknowledged or the subscription's retry policy expires. This is actually stricter than SQS FIFO in some respects and matches Reventless's requirement for ordered command processing well.

**Impact**: Low. Pub/Sub ordering keys are a good match for SQS FIFO message groups.

### 3.4 Change Notifications: Push vs Pull

**AWS (DynamoDB Streams)**: Push-based. Lambda is invoked with a batch of stream records. Back-pressure via failed batch retry.

**GCP (Firestore triggers)**: Push-based. Cloud Functions invoked per-document change. No batching. Back-pressure via function retry policy.

**GCP (Pub/Sub)**: Configurable push or pull. Push: HTTP endpoint receives messages. Pull: client polls for messages. Both support batching.

**Impact**: Firestore triggers are per-document (no batch window), which may increase function invocations for high-throughput EventLogs. For event fanout, Pub/Sub with batched push delivery is a better match. The adapter should use Pub/Sub for EventCollector and Firestore triggers only where DynamoDB Streams is used for internal propagation.

### 3.5 No Managed GraphQL Service

Same gap as Azure. See Azure analysis Section 3.3 for detailed discussion. The same recommendation applies: implement a custom GraphQL server using graphql-yoga on Cloud Functions or Cloud Run.

**GCP-specific consideration**: Cloud Run is a strong hosting option for the GraphQL server — it supports WebSockets (for GraphQL subscriptions), auto-scales to zero, and has no cold-start penalty for always-on minimum instances. This may be a better hosting model than Azure Functions for the GraphQL layer.

### 3.6 DcbEventLog on Firestore

**DynamoDB approach**: Single partition ("dcb") with GSIs for tag-based filtering.

**Firestore approach**:
- Collection `dcbEvents` with auto-incrementing position field
- Composite indexes for tag combinations
- `where` clauses for tag filtering

**Challenges**:
- Firestore's **single inequality filter restriction** may complicate tag-based queries that combine range filters (e.g., "events after position X with tag Y"). Solution: use `position` as the range filter and tag matches as equality filters. This actually works well for the DCB query pattern.
- No hard partition size limit in Firestore (unlike Cosmos DB's 20GB). Firestore scales automatically. **This is an advantage over Azure.**
- Conditional append via Firestore transactions: `runTransaction` can read the latest position and conditionally write, providing stronger guarantees than DynamoDB's conditional expressions.

**Effort**: Medium-High. Tag filtering needs a different indexing strategy, but Firestore transactions simplify conditional appends.

---

## 4. Required Changes in Other Packages

### 4.1 No Changes Required

| Package | Reason |
|---------|--------|
| `reventless-spec` | Pure type definitions, no cloud dependencies |
| `reventless` (core) | Provider-agnostic by design |
| `rescript-uuid`, `rescript-hash-object`, etc. | Utility packages, no cloud coupling |
| `reventless-local` | Test platform, independent of cloud providers |
| `reventless-gen` | Code generation, cloud-agnostic |

### 4.2 Minimal Changes Likely Required

| Package | Change | Reason |
|---------|--------|--------|
| `reventless-infra` | Add GCP resource type identifiers | `resource.service` field needs GCP constants |
| `reventless-infra` | Optional: abstract GraphQL API interface | Same recommendation as Azure analysis |

### 4.3 New Packages Required

| Package | Location | Purpose |
|---------|----------|---------|
| `reventless-gcp` | `reventless/gcp/` | GCP adapter implementations |
| `rescript-gcp-sdk` | `rescript/rescript-gcp-sdk/` | ReScript bindings for GCP SDKs (`@google-cloud/firestore`, `@google-cloud/pubsub`, `@google-cloud/storage`, `@google-cloud/functions-framework`) |
| `rescript-pulumi-gcp` | `rescript/rescript-pulumi-gcp/` | ReScript bindings for `@pulumi/gcp` |

### 4.4 Pulumi Consideration

Pulumi has first-class GCP support via `@pulumi/gcp` (classic) and `@pulumi/google-native` (auto-generated from Google APIs). The `@pulumi/gcp` provider is more mature and widely used. Same Pulumi patterns (`Output.t<'a>`, component resources) apply.

---

## 5. Effort Estimation

### 5.1 Work Breakdown

| Work Item | Estimated Size | Complexity |
|-----------|---------------|------------|
| **ReScript GCP SDK bindings** (`rescript-gcp-sdk`) | ~35 files | Medium |
| **ReScript Pulumi GCP bindings** (`rescript-pulumi-gcp`) | ~25 files | Medium |
| **EventLog adapter** (Firestore) | ~8 files | Medium |
| **DcbEventLog adapter** (Firestore + composite indexes) | ~10 files | Medium-High |
| **CommandTopic adapter** (Pub/Sub with ordering keys) | ~6 files | Medium |
| **EventTopic adapter** (Pub/Sub Topics) | ~5 files | Low-Medium |
| **EventCollector adapter** (Pub/Sub Subscriptions + Firestore triggers) | ~8 files | Medium |
| **QueryDb adapter** (Firestore) | ~8 files | Medium |
| **Task adapter** (Cloud Storage + Eventarc) | ~6 files | Low |
| **Scheduler adapter** (Cloud Scheduler) | ~4 files | Low |
| **GraphQL API replacement** (graphql-yoga on Cloud Run/Functions) | ~15 files | Very High |
| **Authentication adapter** (Firebase Auth) | ~6 files | Medium |
| **Error handling** (GCP-specific error classification) | ~5 files | Medium |
| **Runtime builders** (Cloud Functions variants) | ~10 files | Medium |
| **Component builders** (GCP wiring) | ~15 files | Medium |
| **Platform entry point** | ~3 files | Low |
| **Utility modules** | ~15 files | Medium |
| **`reventless-infra` changes** | ~3 files | Low |
| **Tests** | ~35 files | Medium |
| **Documentation** | ~10 pages | Medium |

### 5.2 Total Estimate

- **New ReScript source files**: ~170-190 (vs ~130 for AWS)
- **Relative effort vs `reventless-aws`**: ~1.1-1.3x
- **Critical path**: GraphQL API replacement (shared problem with Azure)

### 5.3 GCP vs Azure Effort Comparison

| Area | Azure | GCP | Winner |
|------|-------|-----|--------|
| **EventLog** | Cosmos DB (partition modeling) | Firestore (natural subcollection fit) | GCP |
| **CommandTopic** | Service Bus Sessions (paradigm shift) | Pub/Sub ordering keys (close to SQS FIFO) | GCP |
| **EventTopic** | Service Bus Topics (good) | Pub/Sub (unified pub+sub) | GCP |
| **EventCollector** | Change Feed (pull-based) | Firestore triggers (push-based) + Pub/Sub | GCP |
| **DcbEventLog** | Cosmos DB (20GB partition limit risk) | Firestore (no partition limit) | GCP |
| **QueryDb** | Cosmos DB (flexible queries) | Firestore (query restrictions) | Azure |
| **GraphQL** | Custom (same gap) | Custom (same gap, Cloud Run advantage) | Tie (slight GCP edge) |
| **Auth** | Azure AD B2C (enterprise-oriented) | Firebase Auth (consumer-oriented, closer to Cognito) | GCP |
| **Task Bucket** | Blob Storage + Event Grid | Cloud Storage + Eventarc | Tie |
| **Scheduling** | Logic Apps / Timer Triggers | Cloud Scheduler | Tie |
| **SDK Bindings** | Azure SDK (large surface) | GCP SDK (smaller surface) | GCP |

**Summary**: GCP is a moderately easier port than Azure due to Pub/Sub's close match to SQS FIFO, Firestore's subcollection model, and Firebase Auth's similarity to Cognito.

### 5.4 Suggested Implementation Order

1. **Phase 1 — Foundation**: `rescript-gcp-sdk`, `rescript-pulumi-gcp`, error handling
2. **Phase 2 — Messaging**: CommandTopic, EventTopic, EventCollector (Pub/Sub) — GCP's strongest area
3. **Phase 3 — Storage**: EventLog, QueryDb, DcbEventLog (Firestore)
4. **Phase 4 — Compute**: Cloud Functions runtime builders, Task adapter (Cloud Storage)
5. **Phase 5 — API**: GraphQL server (Cloud Run), Authentication (Firebase Auth)
6. **Phase 6 — Integration**: Component builders, Platform assembly, E2E tests

---

## 6. Risk Assessment

### 6.1 High Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **No managed GraphQL service** | Same as Azure — requires building custom GraphQL server | Use graphql-yoga on Cloud Run (better fit than Cloud Functions for long-lived connections). Consider shared GraphQL server implementation reusable across Azure and GCP. |
| **Firestore query restrictions** | Inequality filter on one field only; no cross-field OR | Document supported query patterns. For complex read models, consider Firestore in Datastore mode (different query capabilities) or BigQuery for analytics. Design QueryDb adapter to surface limitations clearly. |
| **Firestore write rate limits** | 10,000 writes/sec per database (soft limit). Individual document: 1 write/sec sustained | For high-throughput aggregates, distribute writes across subcollections or use Bigtable as an alternative EventLog backend. Most event-sourced workloads are well within limits. |

### 6.2 Medium Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Pub/Sub exactly-once delivery maturity** | Feature is GA but less battle-tested than SQS FIFO in the Reventless context | Build comprehensive ordering and deduplication tests. Implement application-level idempotency as a safety net. |
| **Firestore trigger ordering** | Per-document triggers may fire out of order under high concurrency | Use Pub/Sub with ordering keys as the primary EventCollector channel. Reserve Firestore triggers for internal propagation only. |
| **ReScript GCP SDK bindings maintenance** | GCP SDKs are stable but updates may require binding changes | Pin SDK versions. GCP client libraries follow semantic versioning — less churn than Azure SDKs. |
| **Cost model differences** | Firestore pricing (reads/writes/storage) differs from DynamoDB's capacity model | Document cost implications. Firestore's per-operation pricing is transparent but can surprise at scale. |
| **Pulumi GCP provider** | `@pulumi/gcp` is mature but `@pulumi/google-native` has gaps | Use `@pulumi/gcp` (classic provider). It covers all services needed and is the recommended provider. |
| **Dual maintenance burden** | Same risk as Azure — every framework change needs GCP implementation | Shared adapter contract test suites mitigate this. GCP's simpler service model (Pub/Sub unifying SNS+SQS) may reduce maintenance. |

### 6.3 Low Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Cloud Storage event triggers** | Eventarc provides at-least-once delivery | Good match for S3 event notification semantics. |
| **Cloud Scheduler** | Well-understood, simple API | Straightforward implementation via Pub/Sub target. |
| **IAM / Service Account differences** | Simpler than AWS IAM | Pulumi abstracts most of this. GCP's service account model is easier to reason about. |
| **Core package contamination** | Risk of GCP-specific concerns leaking into core | Existing adapter pattern prevents this. |
| **Firebase Auth integration** | Closest Cognito equivalent among cloud providers | Mature service, well-documented, good SDK support. |

---

## 7. Recommendations

1. **If choosing one cloud provider to port first, GCP is the easier target.** Pub/Sub's unified messaging model, Firestore's subcollection hierarchy, and Firebase Auth's similarity to Cognito result in fewer paradigm mismatches than Azure.

2. **Share the GraphQL server implementation between Azure and GCP.** Both need a custom graphql-yoga server. Build it as a provider-agnostic module in `reventless-infra` or a shared package, with thin cloud-specific wrappers for deployment (Cloud Run vs Azure Functions).

3. **Start the PoC with Pub/Sub + Firestore EventLog.** These are the two most important adapters and the ones where GCP differs most from AWS. Validating them early de-risks the project.

4. **Use Pub/Sub as the primary messaging backbone.** Unlike AWS (where SNS and SQS serve different roles), Pub/Sub handles both pub/sub and queuing. This simplifies the adapter layer — CommandTopic, EventTopic, and EventCollector all use the same underlying service with different configurations.

5. **Document Firestore query limitations prominently.** Users designing read models need to know about the single-inequality-filter restriction upfront. Provide alternative patterns (denormalization, composite fields) for common workarounds.

6. **Consider a unified multi-cloud effort** if both Azure and GCP are planned. The GraphQL API gap, `reventless-infra` resource types, and adapter contract test suite are shared work. Implementing them once benefits both cloud targets. Estimated shared work: ~20% of total effort.

---

## 8. Comparison Summary: AWS vs GCP vs Azure

| Dimension | AWS (existing) | GCP (proposed) | Azure (proposed) |
|-----------|---------------|----------------|------------------|
| **Messaging** | SNS + SQS (two services) | Pub/Sub (one service) | Service Bus (one service, sessions) |
| **Storage** | DynamoDB (key-value) | Firestore (document) | Cosmos DB (multi-model) |
| **Event Fanout** | DynamoDB Streams | Firestore triggers + Pub/Sub | Cosmos DB Change Feed |
| **GraphQL** | AppSync (managed) | Custom (graphql-yoga) | Custom (graphql-yoga) |
| **Auth** | Cognito | Firebase Auth | Azure AD B2C |
| **Scheduling** | EventBridge | Cloud Scheduler | Logic Apps / Timer |
| **Effort multiplier** | 1.0x (baseline) | 1.1-1.3x | 1.3-1.5x |
| **Risk level** | N/A (proven) | Medium | Medium-High |
| **Paradigm fit** | Native | Good (Pub/Sub is arguably better) | Acceptable (Service Bus sessions differ) |
