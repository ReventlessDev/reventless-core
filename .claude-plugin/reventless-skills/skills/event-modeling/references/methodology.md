# Event Modeling Methodology

## Overview

Event Modeling is a method for designing information systems by focusing on **what happens** (events) rather than **what exists** (entities). A model is built as a timeline of events, with commands triggering state changes and views projecting state for users.

## Swimlane Structure

An Event Model is organized as horizontal swimlanes on a timeline:

```
┌─────────────────────────────────────────────────┐
│  UI / Actors          (who triggers commands)    │
├─────────────────────────────────────────────────┤
│  Commands             (blue sticky notes)        │
├─────────────────────────────────────────────────┤
│  Events               (orange sticky notes)      │
├─────────────────────────────────────────────────┤
│  Read Models / Views  (green sticky notes)       │
├─────────────────────────────────────────────────┤
│  Automation / Policies (purple/lilac notes)      │
├─────────────────────────────────────────────────┤
│  External Systems     (pink/gray notes)          │
└─────────────────────────────────────────────────┘
```

## The 4 Core Patterns

### 1. Command Pattern (State Change)

A user action that validates against current state and produces events.

```
User → Command → [validates against state] → Event(s)
```

- **Input:** Command with data fields
- **Decision:** Check business rules against current state
- **Output:** Zero or more events (zero = idempotent no-op)
- **Error:** Explicit rejection with reason

### 2. View Pattern (State View)

Events are projected into a query-optimized read model for display.

```
Event(s) → [projection] → Read Model → UI/Screen
```

- **Input:** One or more event types
- **Transformation:** Set, Update, Delete, Ignore per event
- **Output:** Queryable state record

### 3. Automation Pattern

Events trigger autonomous processing that generates new commands.

```
Event(s) → [TODO list] → Processor → Command → Event(s)
```

- **Trigger:** An event creates a work item
- **Resolution:** Another event marks the work item as done
- **Processing:** Generate a command from the work item
- **Retry:** Failed processing retries with backoff

### 4. Translation Pattern

Events cross system boundaries — inbound or outbound.

**Inbound:** External data is validated and translated into domain commands.

```
External System → [validate + translate] → Command
```

**Outbound:** Domain events trigger calls to external systems.

```
Event → [collect + translate] → External System Call
```

## Event Modeling JSON Format

When exported from Event Modeling tools, the model is structured as:

```json
{
  "slices": [
    {
      "id": "slice-1",
      "title": "Add Product",
      "sliceType": "STATE_CHANGE",
      "context": "Catalog",
      "commands": [{ "id": "cmd-1", "title": "AddProduct", "fields": [...] }],
      "events": [{ "id": "evt-1", "title": "ProductAdded", "fields": [...] }],
      "readmodels": []
    }
  ]
}
```

**Slice types:** `STATE_CHANGE`, `STATE_VIEW`, `AUTOMATION`

**Field types:** `String`, `Int`, `Double`, `Boolean`, `UUID`, `Custom`, `Date`, `DateTime`

**Field properties:** `optional`, `idAttribute` (marks entity identity fields), `cardinality` (`Single` or `List`)
