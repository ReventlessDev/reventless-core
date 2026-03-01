# Container-Based Runtime Support for Reventless — Feasibility Analysis

**Status:** Analysis
**Date:** 2026-03-01

---

## Executive Summary

Adding container-based runtime support to Reventless is **architecturally feasible** because the framework already has a clean abstraction boundary at `Runtime.Environment`. However, the effort is **substantial** — not because of the runtime environment abstraction itself, but because of a fundamental mismatch in **message-consumption model**: Lambda uses push-based event source mappings, while containers require pull-based consumers or a different invocation pattern. Total effort across all phases: **12–18 weeks** for a production-grade implementation.

---

## Current Architecture: What Already Abstracts

The framework separates concerns across three layers, which makes this possible at all:

| Layer | Provider-Agnostic | AWS-Specific |
|-------|-------------------|--------------|
| Runtime environment | `Runtime.Environment` interface | `RuntimeEnvironment_Lambda.res` |
| Storage | `EventLog_Adapter.Storage` | `EventLogStorage_DynamoDb.res` |
| Command channel | `CommandTopic_Adapter.Channel` | `CommandTopicChannel_SQS.res` |
| Event collection | `EventCollector_Adapter.Channel` | `EventCollectorChannel_DynamoDbStream.res` |
| Event publishing | `EventTopic_Adapter.Publisher` | `EventTopicPublisher_SNS.res` |

The `Runtime.Environment` module type is the only thing that needs a new implementation to support a different compute target. The business logic (specs, behaviors, mappings) and the storage/messaging adapters do not need to change.

The `Plugin` pattern already expresses this: a Plugin receives a `Platform` module that bundles all adapters. A `ContainerPlatform` would be a new platform implementation without touching any application code.

---

## The Core Problem: Push vs. Pull

This is the most important architectural challenge.

**Lambda model (push-based):**
AWS manages invocation. SQS sends a batch of messages directly to the Lambda function. DynamoDB Streams trigger Lambda. The `handleChannelEvent` pattern in every channel adapter assumes this model — the function *receives* an event.

**Container model (pull-based):**
A container is a long-running process. It must *poll* SQS or DynamoDB Streams for new messages, or expose an HTTP endpoint and receive messages pushed via HTTP.

This means every channel adapter that today returns a `handleChannelEvent` lambda handler needs a counterpart that either:
1. Runs a polling loop inside the container process, or
2. Exposes an HTTP route and connects to an HTTP-push source (e.g., EventBridge Pipes).

This is not a small change — it redefines how messages flow through the runtime.

---

## Three Viable Architectural Approaches

### Approach A: Native Pull-Based Consumers (Most Capable, Highest Effort)

Containers run SQS polling loops and DynamoDB Streams consumers internally. Each channel adapter gains a container-mode variant:

- `CommandTopicChannel_SQS_Container.res` — starts an SQS consumer thread/loop
- `EventCollectorChannel_SQS_Container.res` — SQS polling for event collection
- `EventCollectorChannel_DynamoDbStream_Container.res` — DynamoDB Streams polling

The container's main entry point starts all registered consumers and dispatches to business logic.

**Pros:** No dependency on Lambda at all; multi-cloud capable; full control over throughput and batching.
**Cons:** Significant new code; scaling becomes container-level rather than per-message; requires a container main-loop framework.

### Approach B: HTTP-Based Command Routing (Lower Effort, AWS-Tied)

Commands are delivered to the container via HTTP instead of via queue polling. SQS messages are forwarded to an HTTP endpoint using AWS EventBridge Pipes or a thin Lambda proxy. The container exposes routes like `POST /commands/{aggregate}`.

Channel adapters would expose an HTTP handler instead of a Lambda handler.

**Pros:** Reuses much of the existing channel adapter structure; simpler consumer code; good fit for request/response patterns.
**Cons:** Still somewhat AWS-tied (EventBridge Pipes); adds HTTP server dependency; less efficient for high-volume event streams.

### Approach C: Hybrid Bridge (Pragmatic Middle Ground)

Keep SQS/SNS/DynamoDB Streams as the messaging layer. Add a thin bridge: an always-on SQS consumer (could be a sidecar, or the container itself) that receives messages and dispatches to the container's internal handler registry.

This is essentially Approach A but with the consumer loop factored into a shared `ContainerRuntime` module rather than per-channel adapters.

**Pros:** Reuses existing adapter structure to the extent possible; single place to implement polling.
**Cons:** Requires the container runtime module to know about all registered channels — similar to how `RuntimeEnvironment_Lambda` registers event source mappings today.

---

## Advantages of Container Support

### 1. Elimination of Lambda Constraints
- **Execution time**: Lambda caps at 15 minutes. Containers have no limit — critical for long-running streams, batch replay, and complex migrations.
- **Cold starts**: Containers can run warm continuously. Zero cold-start latency for latency-sensitive commands.
- **Concurrency**: Lambda concurrent execution limits and reserved concurrency require careful configuration. Container scaling is coarser but more predictable.

### 2. Portability
- Same application code deployable to **AWS ECS/Fargate**, **Kubernetes (EKS, GKE, AKS, on-premise)**, and **local Docker Compose**.
- Removes vendor lock-in on the compute layer. Storage and messaging are already swappable.
- Enables on-premise deployment for regulated industries (finance, healthcare) where Lambda is not an option.

### 3. Richer Runtime Capabilities
- **Stateful in-process caches**: Connection pools, read-model caches, session state — all managed in process memory across many requests.
- **WebSocket support**: Long-lived connections for real-time read models (Lambda@Edge has severe WebSocket limitations).
- **Heavy runtimes**: ML inference models, JVM, native binaries — anything that Lambda's bootstrapping overhead makes impractical.
- **Streaming**: Full support for server-sent events and bidirectional streams without API Gateway WebSocket complexity.

### 4. Cost Profile for Stable Workloads
- For predictable, steady-state traffic, always-on containers can be cheaper than Lambda (no per-invocation pricing, no minimum request charges).
- ECS Fargate Spot or K8s spot nodes can cut compute costs significantly.

### 5. Local Development Parity
- The in-memory platform already supports local testing. A Docker Compose–based deployment would bridge the gap between the in-memory test environment and a real infrastructure run — no Lambda simulation needed.

---

## Consequences and Risks

### 1. Operational Complexity Increase
Lambda is fully managed: deployment, scaling, health checking, log aggregation all happen automatically. Containers require:
- Service health checks (liveness, readiness probes)
- Rolling deployments and rollback strategy
- Log routing (CloudWatch, Fluentd, etc.)
- Load balancers (ALB, NLB) for HTTP-facing services
- Networking (VPC, subnets, security groups, service discovery)

This operational burden is non-trivial and is one of the main reasons teams choose Lambda.

### 2. Scaling Behavior is Coarser
Lambda scales per message — 1000 SQS messages can trigger 1000 concurrent Lambda invocations instantly. Containers scale by replica count — ECS typically takes 30–90 seconds to provision a new task. This means container mode is less suited for spiky, bursty workloads unless horizontal pod autoscaling (HPA/KEDA) with SQS queue depth is configured.

### 3. Always-On Cost for Idle Systems
Lambda charges only for actual invocations. A container running at near-zero traffic still pays for the full compute reservation. For development environments and low-traffic applications, this is a cost regression.

### 4. State Introduces New Bug Classes
Lambda's stateless execution model eliminates a category of bugs (stale in-process state, race conditions across invocations). Containers introduce these back if not managed carefully. The framework would need to provide clear guidance on what is safe to cache in-process.

### 5. Pulumi Bindings Gap
`rescript-pulumi-aws` currently has no ECS, ALB, or ECR bindings. These need to be written as new ReScript bindings packages — similar in scope to the existing `rescript-pulumi-aws` work, but for different AWS services.

### 6. Kubernetes Requires an Additional Pulumi Provider
Supporting Kubernetes requires a new `rescript-pulumi-kubernetes` binding package and a new `RuntimeEnvironment_K8s.res`. This is independent of the ECS work.

---

## Impact on Existing Abstractions

### Unchanged
- `Runtime.Environment` interface — already abstract
- All storage adapters (`EventLog_Adapter.Storage`, implementations)
- All event publishing adapters (`EventTopic_Adapter.Publisher`, implementations)
- Business logic: specs, behaviors, mappings, projections
- Plugin and Core components
- The `reventless-in-memory` package

### New Implementations Needed
- `RuntimeEnvironment_ECS.res` — creates ECS task definitions, services, IAM task roles
- `CommandTopicChannel_SQS_Container.res` — SQS consumer loop variant
- `EventCollectorChannel_SQS_Container.res` — SQS polling for event collection
- Or: a `ContainerRuntime` central consumer module (Approach C)
- A container entry point / main loop module

### New Bindings Packages Needed
- `rescript-pulumi-aws-ecs` (or extend `rescript-pulumi-aws`) — ECS cluster, task definition, service, IAM task role, ALB
- Optionally: `rescript-pulumi-kubernetes` for K8s support

### Potentially Changed
- `AggregateRuntime_Builder_Single/PerAggregate/Micro.res` — the deployment-strategy builders currently assume Lambda's event source mapping model. The container equivalent needs a "how to connect consumers to this runtime" pattern.

---

## Phased Implementation Plan

### Phase 1 — ECS Runtime Environment (3–4 weeks)
Write `RuntimeEnvironment_ECS.res` that, instead of creating a Lambda `CallbackFunction`, creates:
- ECS cluster (or accepts an existing one)
- Task definition with IAM task role
- ECS service with desired count
- ALB listener rule (if HTTP-based)

Write the Pulumi bindings for these resources (extend `rescript-pulumi-aws`).

**Deliverable:** A container is created and deployed. It cannot yet receive messages.

### Phase 2 — Message Consumption Model (4–5 weeks)
Choose one of the three approaches and implement it:
- **Approach A**: Per-channel SQS consumer loop adapters
- **Approach B**: HTTP routing layer + EventBridge Pipes or Lambda bridge
- **Approach C**: Central `ContainerRuntime` consumer dispatcher

This is the highest-risk phase because it requires design decisions that affect the adapter API surface.

**Deliverable:** Commands can be sent to the container and processed correctly.

### Phase 3 — Container Runtime Module (2–3 weeks)
- Container entry point: starts consumers, registers handlers, manages lifecycle
- Graceful shutdown (SIGTERM handling, drain in-flight messages)
- Health check HTTP endpoint (liveness/readiness)
- Observability hooks (structured logs, metrics export)

**Deliverable:** Production-grade container runtime process.

### Phase 4 — Local Docker Compose Platform (1–2 weeks)
- `reventless-docker-compose` package or extend `reventless-in-memory`
- Docker Compose file generation via Pulumi local/Docker provider
- Uses real SQS/DynamoDB via LocalStack, or keeps in-memory adapters
- Bridges gap between unit tests and real infrastructure

**Deliverable:** `docker compose up` runs the full application locally with real message passing.

### Phase 5 — Kubernetes Support (3–4 weeks)
- Write `rescript-pulumi-kubernetes` bindings (Deployment, Service, ConfigMap, HPA)
- `RuntimeEnvironment_K8s.res` — creates K8s Deployment + Service
- KEDA ScaledObject for SQS-driven autoscaling

**Deliverable:** Application deployable to any Kubernetes cluster.

**Total: 13–18 weeks** for all five phases. Phase 1 + 2 alone (minimum viable container support) are **7–9 weeks**.

---

## Recommendation

Container support is worth building, but the decision of *which approach to take* for message consumption (Phase 2) is the most consequential design choice and should be prototyped before committing to a full implementation.

**Recommended next step:** Spike Approach C (central consumer dispatcher) using the existing in-memory bus as a reference. Validate that the `Runtime.Environment` interface can accommodate both Lambda's event handler model and a pull-based polling model without breaking existing adapters. This spike should take 1–2 weeks and de-risks Phase 2 significantly.

**Priority order for target platforms:**
1. **AWS ECS/Fargate** — lowest friction; same AWS ecosystem, same IAM, same VPC — most teams already familiar
2. **Local Docker Compose** — developer experience; closes the gap between `reventless-in-memory` and real infra
3. **Kubernetes (EKS)** — for teams that already run K8s; lowest incremental value if ECS is already supported

---

## Appendix: Files Most Relevant to This Work

| File | Relevance |
|------|-----------|
| `reventless/reventless-core/src/adapter/Runtime/Runtime.res` | The abstract `Runtime.Environment` interface to implement |
| `reventless/reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res` | Reference implementation to model the ECS version on |
| `reventless/reventless-core/src/adapter/Runtime/AggregateRuntime_Builder_Single.res` | Shows how runtimes and channels are connected |
| `reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS.res` | Channel adapter using Lambda-push model |
| `reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res` | Event collector using Lambda event source mapping |
| `rescript/rescript-pulumi-aws/src/` | Existing AWS Pulumi bindings to extend |
