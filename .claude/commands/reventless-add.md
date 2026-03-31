---
description: Add a new component to an existing Reventless plugin or platform
argument-hint: component-type (plugin, aggregate, slice, readmodel, viewslice, extensionpoint, extension, automation, inbound, outbound)
---

# Add Component to Existing Reventless Project

Add a new component to an existing plugin or platform. Detects the current project structure and generates only the new component, updating the plugin composition root to include it.

## Supported Component Types

| Argument | What Gets Created |
|----------|-------------------|
| `plugin` | New plugin package + spec package + composition root |
| `aggregate` | Aggregate spec + behavior + wiring in plugin |
| `slice` | StateChangeSlice file + wiring in plugin |
| `readmodel` | ReadModel spec + projection mapping + wiring in plugin |
| `viewslice` | StateViewSlice file + wiring in plugin |
| `extensionpoint` | EP spec (in spec package) + EP mapping + wiring |
| `extension` | Extension mapping + wiring (subscribes to external EP) |
| `automation` | AutomationSlice file + wiring in plugin |
| `inbound` | InboundTranslationSlice file + wiring in plugin |
| `outbound` | OutboundTranslationSlice file + wiring in plugin |

## Workflow

### 1. Detect Project Context

- Find the current plugin by looking for `*Plugin.res` composition root
- Determine architecture (aggregate, DCB, or hybrid) from existing components
- Identify naming conventions from existing components

### 2. Gather Component Details

Ask the user for the specific component details based on type:
- **aggregate/slice:** entity name, commands, events, errors
- **readmodel/viewslice:** view name, fields, which events to project
- **extensionpoint:** public event types to expose
- **extension:** which external EP to subscribe to, routing rules
- **automation:** trigger events, resolution events, generated commands
- **inbound/outbound:** external data format, translation rules

### 3. Generate Files

Use the `reventless-app` skill references for code templates. Match existing project conventions.

### 4. Update Plugin Composition

Add the new component to the plugin's `Make` functor and `Plugin.make(...)` call.

### 5. Update Configuration

Add any new spec package dependencies to `package.json` and `rescript.json` if needed.

### 6. Build and Verify

```bash
npm install  # if dependencies changed
npm run build
npm test
```

Verify zero warnings and all tests pass.
