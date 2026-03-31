# ES/CQRS Concept to Reventless Component Map

## Write Side

| ES/CQRS Concept | Aggregate Approach | DCB Approach |
|----------------|-------------------|-------------|
| Command handler + state machine | Aggregate (Spec + Behavior) | StateChangeSlice |
| Event store (per entity) | EventLog | — |
| Event store (shared, tag-filtered) | — | DcbEventLog |
| Command delivery queue | CommandTopic (per aggregate) | CommandTopic (shared per plugin) |
| Event publication | EventTopic (per aggregate) | EventTopic (shared) |

## Read Side

| ES/CQRS Concept | Aggregate Approach | DCB Approach |
|----------------|-------------------|-------------|
| Query-optimized view | ReadModel | StateViewSlice |
| Event-to-view transformation | Projection (Mapping module) | `project` function in StateViewSlice |
| Query storage | QueryDb | QueryDb |

## Cross-Cutting

| ES/CQRS Concept | Aggregate Approach | DCB Approach |
|----------------|-------------------|-------------|
| Cross-boundary pub/sub | ExtensionPoint + Extension | ExtensionPoint + Extension |
| Event-driven command routing | EventMapper | AutomationSlice |
| External data ingestion | Task (S3 bucket trigger) | InboundTranslationSlice |
| External system calls | SideEffectHandler | OutboundTranslationSlice |
| API endpoint | CommandGenerator | CommandGenerator |
| Periodic processing | Heartbeat | Heartbeat |
| Scheduled operations | Scheduler | Scheduler |
| Counters / thresholds | Counter | — |

## Infrastructure

| ES/CQRS Concept | Reventless Component |
|----------------|---------------------|
| Deployable unit | Plugin |
| Bounded context boundary | Plugin boundary |
| Public API contract | ExtensionPoint Spec (in spec package) |
| Application composition | Platform (wires plugins together) |
| Infrastructure provider | Platform adapter (InMemory, AWS) |

## Command Flow (Aggregate)

```
Command
  → CommandTopic (FIFO, ordered per ID)
  → replay(id) from EventLog
  → evolve events into state
  → decide(state, command) → new events
  → append to EventLog
  → publish to EventTopic
  → ReadModel Projection → QueryDb
```

## Command Flow (DCB)

```
Command
  → CommandTopic (shared)
  → extract tags from command fields (@s.matches)
  → query DcbEventLog by tags + event types
  → evolve matching events into decision model
  → decide(state, command) → new events
  → conditional append (retry on conflict)
  → publish to EventTopic
  → StateViewSlice projects → QueryDb
```

## Plugin Composition

```
Platform.Make()           // Choose infrastructure (InMemory, AWS)
  → Plugin.Make(Platform) // Build each plugin with platform's builders
    → Aggregate.Make(Spec, Behavior, EventMappings)
    → ReadModel.Make(Spec, Projections)
    → ExtensionPoint.Make(Spec, Mappings)
    → Extension.Make(ExternalSpec, Mappings)
    → StateChangeSlice.Make(Spec)     // DCB
    → StateViewSlice.Make(Spec)       // DCB
    → AutomationSlice.Make(Spec)      // DCB
  → Platform.makePlatform(~plugins=[...])
```
