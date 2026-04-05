---
title: Glossary
sidebar_position: 99
---

# Glossary

Key terms used throughout the Reventless framework and documentation.

## Adapter

A module that implements a framework interface for a specific cloud provider. Adapters exist at two levels: **deploy-time** (creates cloud resources using Pulumi) and **runtime** (executes operations inside Lambda). See [Adapter Pattern](/infrastructure/adapter-pattern).

## Aggregate

A command handler that enforces business invariants and emits events. Aggregates are the write side of CQRS. Each aggregate instance is identified by an ID and manages its own event log. Commands are either accepted (producing events) or rejected (returning an error). See [Aggregate component](/app/components/aggregate).

## Behavior

A ReScript module that implements the business logic for an Aggregate or DCB Slice. Contains `handle` (command → events | error), `apply` (state × event → state), and `initialState`. Annotated with `@@reventless.behavior`.

## DCB (Dynamic Consistency Boundary)

A pattern for handling commands that span multiple entities without requiring a full aggregate per entity. A DCB slice queries a shared event log filtered by entity ID tags, builds a decision model from relevant events, and emits new events. Avoids the overhead of per-entity event logs for write-heavy, cross-entity consistency needs.

## Extension

A component that connects to an **ExtensionPoint** published by another plugin. Extensions receive events and send commands across plugin boundaries without direct coupling. See [Extension component](/app/components/extension).

## Extension Point

The external interface of a Plugin. An ExtensionPoint publishes events outward and accepts commands inward through a stable, versioned protocol. Other plugins connect via Extensions. See [ExtensionPoint component](/app/components/extensionpoint).

## Plugin

The deployable unit of a Reventless application. A Plugin groups related Aggregates, ReadModels, ExtensionPoints, and their infrastructure. Plugins are independently versioned and communicate only through ExtensionPoints and Extensions. See [Plugin component](/app/components/plugin).

## Platform

The top-level deployment unit that assembles one or more Plugins and creates shared infrastructure (admin components, Lambda runtime, API gateway). Created by `Platform.makePlatform`.

## Projection

A mapping from one event type to a read model state update. Projections are pure functions: `event × state → state`. They are composed into a read model's `ProjectionMappings` module.

## ReadModel

A query-side projection of events into a queryable data store (DynamoDB via AppSync). ReadModels consume events from EventCollectors and project them into a QueryDb. See [ReadModel component](/app/components/readmodel).

## Slice

A component in a DCB-based plugin that processes a subset of events from a shared DcbEventLog. There are several slice types:

- **StateChangeSlice** — handles commands and emits events; the DCB equivalent of an Aggregate
- **StateViewSlice** — reads events to produce a query view without handling commands
- **AutomationSlice** — reacts to events by emitting other events or commands
- **InboundTranslationSlice** — translates incoming external events into internal events
- **OutboundTranslationSlice** — translates internal events into outgoing external events

## Spec

A ReScript module that defines the type contract for a component: `type command`, `type event`, `type error`, `type state`, `let name`, `module Id`. Specs are annotated with `@@reventless.spec` and live in `*Spec.res` files.

## StateChangeSlice

The DCB equivalent of an Aggregate. Handles commands against a decision model built from DCB-filtered events, and emits new events. Participates in a Dynamic Consistency Boundary. See [StateChangeSlice component](/app/components/statechangeslice).

## StateViewSlice

A read-only DCB slice. Consumes DCB-filtered events to build a view used for queries or validation, without handling commands. See [StateViewSlice component](/app/components/stateviewslice).
