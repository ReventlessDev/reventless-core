---
title: Glossary
---

# Glossary

Key terms used throughout the Reventless framework and documentation.

## Adapter

A module that implements a framework interface for a specific provider. Adapters
exist at two levels: **deploy-time** (creates cloud resources using Pulumi) and
**runtime** (executes operations inside the deployed handler). See
[Adapter Pattern](/infrastructure/adapter-pattern).

## Aggregate

A command handler that enforces business invariants and emits events. Aggregates
are the write side of CQRS. Each aggregate instance is identified by an ID and
has its own event log. Commands are either accepted (producing events) or
rejected (returning an error). See
[Aggregate component](/app/components/aggregate).

## AutomationSlice

A DCB component implementing the automation (TODO-list) pattern: it accumulates
pending work from events, issues a command per item, and marks the item resolved
when the resulting event arrives. Stateful, unlike an EventMapping. See
[AutomationSlice component](/app/components/automationslice).

## Behavior

The module holding a component's state machine, annotated `@@reventless.behavior`:
`type state`, `initialState`, `evolve` (state × event → state), and `decide`
(state × command → events or error). Paired with a **Spec**, which holds the
types the behavior operates on.

## Consumed event

An event a slice reads in order to decide — declared as `type consumedEvent` on
its spec, separately from the events it emits. Only the fields the decision
needs have to be present; where existence is all that matters the variant can be
payload-less.

## Decision model

The ephemeral state a write-side component builds by replaying the events
relevant to one command, folding them with `evolve` from `initialState`. It is
never stored: it is rebuilt per command, used by `decide`, and discarded.

## DCB (Dynamic Consistency Boundary)

A way to handle commands that span several entities without giving each entity
its own event log. A DCB slice reads a shared event log filtered by **tags**,
builds a decision model from what it reads, and appends new events conditioned on
nothing having changed underneath it. The consistency boundary is per command,
not per entity — which is what lets one entity's decision depend on another's
events. See [What is a DCB?](/app/concepts/dcb).

## Extension

A component that connects to an **extension point** published by another plugin.
Extensions receive events and send commands across plugin boundaries without
direct coupling. See [Extension component](/app/components/extension).

## Extension point

The external interface of a plugin. An extension point publishes events outward
and accepts commands inward through a stable, versioned protocol. Other plugins
connect via extensions. See
[ExtensionPoint component](/app/components/extensionpoint).

## Fence

The consistency check a DCB append carries: for each tag the decision read, the
append is rejected if any new event carrying that tag was recorded since the
read. This is how optimistic concurrency is enforced without locking. See
[DCB consistency checks](/framework/internals/dcb-consistency-checks).

## GWT (Given/When/Then)

The scenario format Reventless tests are written in: *given* these prior events,
*when* this command or event arrives, *then* these events, this state, or this
error. Scenarios are written in the domain's vocabulary and run as the test
suite. See [Writing scenarios](/app/given-when-then).

## Local platform

A running instance of an application on the **Local provider** — one process, in
memory or on SQLite, with the GraphQL and MCP servers attached. The distinction
matters: *Local provider* names the `reventless-local` package, *local platform*
names the thing you started.

## Optimistic concurrency

Writing without holding a lock: read, decide, then append on the condition that
nothing relevant changed in between. A conflicting append is rejected and
retried rather than blocking other writers. Aggregates apply it per instance;
DCB slices apply it per tag through the fence.

## Partition tag

The tag that decides which storage partition a DCB event lands in, marked
`@partitionTag` when an event carries more than one `*Id` field. Distinct from a
tag that is merely queryable: every tag can be read on, but one decides
placement.

## Platform

The top-level deployment unit that assembles one or more plugins and creates the
shared infrastructure they use (admin components, runtime, API). Built by
`Platform.makePlatform`.

## Plugin

The deployable unit of a Reventless application, grouping related components and
their infrastructure. Plugins are independently versioned and communicate only
through extension points and extensions. See
[Plugin component](/app/components/plugin).

## PPX

The compile-time source transformation that injects the repetitive parts of a
spec — names, module identity, schema annotations, DCB tags — from the file-level
markers (`@@reventless.spec`, `@@reventless.behavior`, …). It is why a spec file
states its types and almost nothing else. See
[PPX annotations](/app/reventless-ppx).

## Projection

A mapping from one event type to a read model state update. Projections are pure:
`event × state → state`. A read model composes several of them.

## ReadModel

A query-side projection of events into a queryable store. Read models consume
events from an event collector and project them into a QueryDb. See
[ReadModel component](/app/components/readmodel).

## Slice

A component in a DCB-based plugin that processes a subset of events from a shared
DCB event log:

- **StateChangeSlice** — handles commands and emits events; the DCB equivalent of
  an aggregate
- **StateViewSlice** — reads events to produce a query view without handling
  commands
- **AutomationSlice** — reacts to events by issuing commands
- **InboundTranslationSlice** — translates incoming external input into commands
- **OutboundTranslationSlice** — translates internal events into outgoing calls

## Spec

The module defining a component's type contract — `command`, `event`, `error`,
and where applicable `consumedEvent` or `state` — plus its name and schemas.
Annotated `@@reventless.spec`. Paired with a **Behavior** that holds the logic.

## StateChangeSlice

The DCB equivalent of an aggregate: decides commands against a decision model
built from tag-filtered events and appends new ones. See
[StateChangeSlice component](/app/components/statechangeslice).

## StateViewSlice

A read-only DCB slice, consuming tag-filtered events to build a view used for
queries or validation. See
[StateViewSlice component](/app/components/stateviewslice).

## Sury

The schema library behind `@schema`: it derives serialization for a type from its
declaration, so events and commands cross the wire without hand-written codecs.

## Tag

A key on a DCB event that makes it findable — usually an entity id. A decision
reads by tags, and the events it appends carry them, which is what lets two
slices' events live in one log and still be queried apart. See
[DCB usage](/app/dcb-usage).
