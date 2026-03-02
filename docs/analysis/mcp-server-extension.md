# Analysis: MCP Server Extension for Reventless

**Date:** 2026-03-02
**Status:** Draft — not yet tied to an implementation plan

---

## Overview

Model Context Protocol (MCP) is Anthropic's open standard for connecting AI models to external data sources and tools. An MCP server exposes three primitive types to AI clients (agents, Claude, other LLMs):

- **Resources** — structured data that agents can read (comparable to GET endpoints)
- **Tools** — functions that agents can invoke to perform actions (comparable to POST/mutation endpoints)
- **Prompts** — reusable prompt templates (less relevant here)

This analysis evaluates whether it makes sense to extend Reventless with an MCP server layer alongside the existing GraphQL API, so that AI agents can natively access and interact with a Reventless-based business platform.

---

## Does it make sense?

**Yes — and it is more natural a fit than it might appear.**

Reventless is built around two complementary halves of CQRS:

| Reventless concept | MCP primitive |
|---|---|
| ReadModel / StateViewSlice (query side) | **Resource** — agents read current projected state |
| Aggregate command / DCB StateChangeSlice (write side) | **Tool** — agents invoke domain commands |
| EventLog (history) | **Resource** — agents read event history for context |
| Plugin (bounded context) | **MCP server** or **namespaced tool/resource group** |

This mapping is not forced. Reventless already models the domain in the exact shape MCP needs:

- **Tools = domain commands.** A command (`type command = CreateProduct({name, price}) | ArchiveProduct({id})`) is already a well-typed, intentional domain action. MCP tools are exactly this — named functions with typed inputs. The sury-ppx `@schema` annotation already produces the JSON schema that MCP tool definitions require.

- **Resources = projected state.** ReadModels and StateViewSlices are precomputed, queryable projections. They are exactly what an AI agent needs as readable context. The `type state` schema is already available.

- **Bounded contexts = plugin isolation.** Each Plugin is a bounded context with its own aggregates and read models. MCP servers can namespace tools and resources per plugin, giving agents a clean mental model of what capabilities belong where.

Where GraphQL is optimised for structured queries from human-facing UIs, MCP is optimised for AI-agent access. Both serve the same underlying platform data and commands — they are not in competition.

---

## Is it feasible?

**Yes, technically straightforward given the existing architecture.**

### Schema auto-generation from specs

The most important feasibility signal: Reventless already has everything needed to generate MCP tool and resource schemas automatically:

1. **Tool schemas from commands** — `Spec.commandSchema: S.t<command>` (produced by sury-ppx) is the JSON schema for each command type. The MCP tool input schema is exactly a JSON Schema object. The translation is mechanical.

2. **Resource schemas from state** — `Spec.stateSchema: S.t<state>` drives the ReadModel projection. The same schema describes what an agent reads from a resource.

3. **Tool naming** — The GraphQL naming conventions from the api-graphql plan apply directly: `PluginName_AggregateName_CommandName` for tools, `PluginName_ReadModelName` for resources.

This means the MCP server can be auto-generated from the same Plugin/Aggregate/ReadModel specs that already drive GraphQL generation. Very little extra per-domain work is required.

### Transport and runtime

MCP's recommended production transport is **Streamable HTTP** (the SSE-based transport is deprecated as of the 2025-03-26 spec). Streamable HTTP is straightforward HTTP: clients POST requests and receive HTTP responses or streaming responses.

For Reventless (AWS), this translates to:

- **Lambda + Function URL** (or API Gateway) — stateless Streamable HTTP fits Lambda well. Cold starts are the main concern, but a modest amount of provisioned concurrency handles it. The Lambda response streaming feature supports SSE-like streaming natively.
- **Fargate** — if persistent connections or sub-second latency are required, a lightweight Fargate container running an MCP HTTP server is the natural fit. Reventless already has a `Fargate`-based Cloner adapter, so the deployment pattern exists.

For the in-memory/test platform, the existing `graphql-yoga` server can be extended or a separate MCP endpoint started alongside it.

### Technology

The MCP TypeScript SDK (`@modelcontextprotocol/sdk`) is mature and handles protocol framing, schema validation, and transport. The server definition is a thin layer over it. Since Reventless compiles to CommonJS/ESM JavaScript, the SDK integrates directly.

---

## Advantages

### 1. AI-native access to the business domain

Without MCP, an AI agent accessing a Reventless platform must either:
- Call GraphQL (requires understanding the schema and writing queries)
- Use some other bespoke API

With MCP, the agent receives a structured, self-describing interface where every tool and resource has a name, description, and typed schema. The agent can discover capabilities and use them without external documentation.

### 2. Schema-driven, zero-overhead per domain

Because Reventless specs are fully typed and sury-ppx generates JSON schemas, adding MCP support for a new Aggregate or ReadModel requires **zero extra work** beyond what's already written. The MCP tool/resource definitions are derived automatically — just as GraphQL mutations and queries are derived in the api-graphql plan.

This is the critical advantage over a hand-written MCP server: the platform knows its own shape, and MCP is just another way to expose it.

### 3. Commands as agent affordances

Domain commands are exactly the kind of things AI agents should be doing: intentional, named, typed actions with bounded side effects. The aggregate's command validation and event sourcing ensure that agent-driven mutations go through the same business rule enforcement as human-driven ones. No special agent code path needed.

### 4. Complementary to GraphQL, not a replacement

GraphQL serves structured queries from UI clients. MCP serves AI agents. The same DynamoDB read models back both. No data duplication, no consistency concerns between the two APIs.

### 5. Event history as agent context

The EventLog (per-aggregate, append-only history) is a natural fit for giving agents deep context. An agent deciding whether to create a product can first read the product's event history to understand what happened before. This kind of context retrieval is exactly what MCP Resources are designed for.

### 6. Multi-agent and orchestration architectures

With MCP, different AI specialists can target different Reventless plugins. A catalog-specialist agent uses the Catalog plugin's MCP tools/resources; an ordering-specialist uses the Ordering plugin's. An orchestrating agent coordinates them. Plugin isolation gives each agent a clean bounded interface.

### 7. AI-first DDD

Exposing aggregates and read models as MCP primitives forces good domain modeling discipline: tools must have clear names and descriptions that communicate intent to an AI model. This reinforces Domain-Driven Design rather than compromising it.

### 8. Testing and automation

An MCP interface doubles as a structured automation API. Integration tests, scenario runners, and synthetic monitoring can use the same MCP client to exercise the platform that real agents will use. No separate test API needed.

---

## Consequences and Challenges

### 1. New infrastructure component

An MCP server is a new runtime. It must:
- Be hosted (Lambda with Function URL, Fargate, or EC2)
- Be scaled and monitored
- Be secured

For a serverless-first platform like Reventless, the most natural fit is Lambda + Function URL (Streamable HTTP). But cold starts, concurrency limits, and the 15-minute Lambda timeout must be considered for long-running agent sessions.

**Recommendation**: start with Lambda Function URL (simple, cheap, fits the serverless model). Migrate to Fargate if persistent connections or latency SLAs require it.

### 2. Authorization and security

This is the most serious consequence. MCP Tools give agents the ability to invoke domain commands — real business mutations. An incorrectly authorized agent could:
- Create, update, or delete business data at scale
- Trigger commands that cause irreversible side effects

Mitigation strategies:
- **OAuth 2.0 / Cognito** — MCP 1.0 standardizes on OAuth 2.0 for remote server authentication. Reventless can reuse the same Cognito user pool as AppSync.
- **Scoped tool access** — not all agents need all tools. The MCP server can expose a filtered view based on the authenticated agent's scopes.
- **Read-only mode** — an initial read-only MCP server (Resources only, no Tools) is much lower risk and still highly valuable for context retrieval.
- **Rate limiting** — agents can invoke tools at high frequency. Throttling at the API Gateway / Lambda level is required.
- **Human-in-the-loop confirmation** — for destructive commands, the MCP server can require an explicit confirmation step (MCP's `elicitation` primitive, currently in draft).

### 3. Tool descriptions require domain documentation

MCP tools and resources need human-readable `description` fields for AI models to use them correctly. The current Reventless spec types (`type command`, `type state`) carry no descriptions — they're pure types.

Two options:
- **Doc comments** — add `/** description */` comments to spec types/fields and extract them at build time.
- **Separate description map** — add a `let mcpDescription: dict<string>` to Specs (parallel to how `config` works in ReadModel).

This is a non-trivial change to how specs are written, but the payoff is significant: good descriptions make the difference between an agent that uses tools correctly and one that hallucates wrong arguments.

### 4. Per-plugin vs. platform-wide MCP server

Two topologies are viable:

**Option A — One MCP server per plugin**: each plugin is a separate MCP server. Agents connect to the plugin they need. Clean isolation, but agents that need cross-plugin actions must connect to multiple servers.

**Option B — One platform-wide MCP server**: a single MCP server exposes all plugins' tools and resources, namespaced by plugin name. Simpler for agents (one connection), but requires the Core to aggregate all plugin schemas.

Option B is the better starting point. Plugin isolation is preserved via namespacing. The platform-wide MCP server fits naturally into the `makePlatform` concept from the platform-plugin-core-extension plan.

### 5. Statefulness vs. serverless tension

MCP sessions (especially with SSE or long-running streaming responses) imply some statefulness. Lambda is stateless and short-lived. For most agentic interactions (retrieve context, invoke a command, get result), stateless Lambda is fine. For subscriptions or event streaming, a persistent process is needed.

**For v1**: stateless Lambda handles all MCP interactions. Each invocation is independent. Agent session state lives in the agent framework (Claude, LangGraph, etc.), not in the MCP server.

**For v2**: consider a Fargate-based MCP server with EventBridge subscriptions for agents that need to react to domain events in real time.

### 6. DCB event log as a resource

DCB event logs (multi-entity, decision-model-based) are richer than per-aggregate event logs. Exposing them as MCP Resources requires careful schema design — agents receive raw event arrays with sury-decoded types. This is powerful but requires good descriptions to prevent misuse.

### 7. Versioning and backward compatibility

MCP tool schemas should be stable — breaking changes to a tool's input schema will break agents that depend on it. Since Reventless command types evolve, a versioning strategy for MCP tools is needed (e.g., keep old tool versions, add new ones with a `_v2` suffix).

---

## Architecture Sketch

```
                        ┌──────────────────────────────────┐
                        │         Reventless Platform       │
                        │                                   │
  Human UI ────GraphQL──► AppSync API                       │
                        │    ├─ Catalog mutations/queries   │
                        │    └─ Ordering mutations/queries  │
                        │                                   │
  AI Agent ────MCP──────► MCP Server (Lambda / Fargate)     │
                        │    ├─ Tool: Catalog_CreateProduct │
                        │    ├─ Tool: Catalog_ArchiveProduct│
                        │    ├─ Resource: catalog/products  │
                        │    ├─ Resource: catalog/product/{id}│
                        │    ├─ Tool: Ordering_PlaceOrder   │
                        │    └─ Resource: ordering/orders   │
                        │         │               │         │
                        │         ▼               ▼         │
                        │    SQS CommandTopics  DynamoDB    │
                        │    (Aggregates)     (ReadModels)  │
                        └──────────────────────────────────┘
```

The MCP server sits alongside AppSync, backed by the same SQS command channels and DynamoDB read models. No new storage, no new domain logic — only a new protocol adapter.

---

## Integration with Existing Plans

### api-component-graphql plan

The api-graphql plan (Phase 3) introduces `GraphQL_FragmentGenerator` which traverses sury `S.t<'a>` schemas to derive GraphQL types. The same traversal can be adapted for MCP tool/resource schema generation. A shared `SchemaInspector` utility in `reventless-core` could serve both.

The `mutationSchemaEntry` and `querySchemaEntry` types defined in `Api.res` map directly to MCP tool definitions and resource definitions. The naming conventions table (plugin + aggregate naming rules) applies unchanged.

### platform-plugin-core-extension plan

`makePlatform` is the natural place to instantiate and register the MCP server alongside the GraphQL API:

```rescript
Platform.makePlatform(
  ~api=myApi,           // GraphQL / AppSync
  ~mcp=myMcpServer,     // MCP server (new, optional)
  ~core,
  ~plugins=[catalogPlugin, orderingPlugin],
)
```

The MCP server collects tool/resource definitions from all plugins (analogous to how schema fragments are collected for GraphQL stitching) and registers them at startup.

### Platform.T extension

A new `module Mcp` would be added to `Platform.T` alongside the existing `module Api`:

```rescript
module Mcp: {
  module Make: (Config: {let serverName: string}) => Mcp.T
}
```

The AWS implementation wraps a Lambda Function URL + MCP HTTP handler. The in-memory implementation starts a local MCP HTTP server (port configurable) for agent-in-the-loop testing.

---

## Recommendation

**Proceed, in two stages:**

**Stage 1 — Read-only MCP server (Resources only)**

Start with a read-only MCP server that exposes ReadModel and StateViewSlice state as Resources. No Tools (no mutations). This is:
- Low risk (no agent-driven side effects)
- Immediately useful (AI agents can retrieve rich domain context)
- Simple to implement (DynamoDB reads, no command routing)

This stage can be implemented before the api-graphql plan is complete, since it doesn't require GraphQL schema generation infrastructure — it derives MCP resource schemas directly from ReadModel specs.

**Stage 2 — Full MCP server (Resources + Tools)**

Add Tools for aggregate commands and DCB StateChangeSlice commands. This requires:
- OAuth 2.0 / Cognito-based authorization (not optional for production)
- Tool descriptions (requires spec annotations or doc comment extraction)
- Rate limiting
- Integration testing with real AI agent clients

This stage is best implemented after the platform-plugin-core-extension plan is complete, so `makePlatform` can manage the MCP server lifecycle alongside the GraphQL API.

---

## Summary

| Question | Answer |
|---|---|
| Does it make sense? | Yes — Reventless's CQRS model maps naturally to MCP Resources (read models) and Tools (commands) |
| Is it feasible? | Yes — auto-generation from sury schemas, Streamable HTTP transport via Lambda, MCP TypeScript SDK |
| Biggest advantage | Zero-overhead per domain: MCP schemas auto-generated from existing typed specs |
| Biggest challenge | Authorization: agent-driven mutations require OAuth, scoping, and rate limiting before production use |
| Recommended first step | Read-only MCP server (Resources from ReadModels) — low risk, immediately useful for AI context retrieval |
| Strategic fit | Complementary to GraphQL; serves AI agents as GraphQL serves human UIs; same underlying platform data and commands |
