# Reventless Component Catalog

## Write-Side Components

### Aggregate (Aggregate approach)

Command handler with per-entity event stream.

**Spec fields:**
```rescript
module Id = Id.String
let name = "EntityName"
let moduleUrl: string = %raw(`import.meta.url`)
@schema type command = | Cmd1({...}) | Cmd2({...})
@schema type event = | Evt1({...}) | Evt2({...})
@schema type error = | Err1 | Err2
```

**Behavior fields:**
```rescript
module Spec = EntityName
@schema type state = NotCreated | Created({...})
let initialState = NotCreated
let evolve = (state, event) => newState
let decide = (state, command) => result<array<event>, error>
let moduleUrl: string = %raw(`import.meta.url`)
```

**Builder:** `Platform.Aggregate.Make(Spec, Behavior, EventMappings)`

### StateChangeSlice (DCB approach)

Command handler querying shared event log with tag-based filtering.

**Spec fields:**
```rescript
let name = "CommandName"
let moduleUrl: string = %raw(`import.meta.url`)
type state = {/* minimal decision state */}
let initialState = {/* ... */}
@schema type consumedEvent = | Evt1 | Evt2({...})
let evolve = (state, consumedEvent) => state
@schema type command = CmdName({entityId: @s.matches(DcbTag.string) string, ...})
@schema type error = ErrVariant
@schema type producedEvent = | Evt({entityId: @s.matches(DcbTag.string) string, ...})
let decide = (state, command) => result<array<producedEvent>, error>
```

**Builder:** `Platform.StateChangeSlice.Make(Spec)`

## Read-Side Components

### ReadModel + Projection (Aggregate approach)

**ReadModel spec:**
```rescript
module Id = Id.String
let name = "EntityNames"  // plural
let moduleUrl: string = %raw(`import.meta.url`)
@schema type state = {field1: string, field2: float}
let config = Reventless.ReadModel.config()
let subIdConfig = None
```

**Projection mapping:**
```rescript
module EntityMapping = Mapping.Make(EntitySpec, ReadModelSpec, {
  let project = ({event, id, _}) => switch event {
  | Added({...}) => Set(id, {...})
  | FieldChanged({field}) => Update(id, state => {...state, field})
  }
})
```

**Builder:** `Platform.ReadModel.Make(ReadModelSpec, Projections)`

### StateViewSlice (DCB approach)

**Spec fields:**
```rescript
let name = "EntityView"
let moduleUrl: string = %raw(`import.meta.url`)
@schema type state = {field1: string, field2: float}
@schema type consumedEvent = | Evt1({...}) | Evt2({...})
let project = event => switch event {
| Evt1({id, ...}) => [Set(id, {...})]
| Evt2({id, field}) => [Update(id, state => {...state, field})]
}
```

**Builder:** `Platform.StateViewSlice.Make(Spec)`

## Cross-Plugin Components

### ExtensionPoint Spec (in spec package)

```rescript
let name = "Plugin.EntityNames"
let moduleUrl: string = %raw(`import.meta.url`)
@schema type command = unit  // or inbound command types
@schema type event = | PublicEvt1({...}) | PublicEvt2({...})
@schema type directive = unit
```

### ExtensionPoint Mapping (in plugin)

Maps internal events to public ExtensionPoint events. See `references/cross-plugin-patterns.md`.

### Extension (in plugin)

Subscribes to another plugin's ExtensionPoint. Routes incoming events to local commands. See `references/cross-plugin-patterns.md`.

## Automation Components (DCB only)

### AutomationSlice

```rescript
let name = "AutoProcessName"
let moduleUrl: string = %raw(`import.meta.url`)
@schema type consumedEvent = | TriggerEvt({...}) | ResolutionEvt({...})
@schema type todoItem = {entityId: string}
@schema type command = DoSomething({entityId: @s.matches(DcbTag.string) string})
let collect = event => [(id, todoItem)]  // create work items
let resolve = event => Some(id) | None   // complete work items
let process = (id, item) => Some((id, command)) | None  // generate command
let maxRetries = 3
let heartbeatInterval = 60
```

**Builder:** `Platform.AutomationSlice.Make(Spec)`

### InboundTranslationSlice

```rescript
let name = "ImportEntityName"
let moduleUrl: string = %raw(`import.meta.url`)
@schema type externalInput = {/* external format */}
@schema type command = CmdName({entityId: @s.matches(DcbTag.string) string, ...})
let translate = input => result<(string, command), string>
```

**Builder:** `Platform.InboundTranslationSlice.Make(Spec)`

### OutboundTranslationSlice

```rescript
let name = "SendNotificationName"
let moduleUrl: string = %raw(`import.meta.url`)
@schema type consumedEvent = | TriggerEvt({...})
@schema type outboundItem = {/* data to send */}
@schema type inboundCommand = unit  // or echo command type
let collect = event => [(id, outboundItem)]
let translate = async (id, item) => result<option<(string, inboundCommand)>, string>
let maxRetries = 3
let heartbeatInterval = 60
```

**Builder:** `Platform.OutboundTranslationSlice.Make(Spec)`

## Infrastructure Components

### Plugin

Composition root wiring all components. See `references/aggregate-patterns.md` and `references/dcb-patterns.md`.

**Builder:** `Platform.Plugin.make(~name, ~aggregates, ~readModels, ~stateChangeSlices, ~stateViewSlices, ~extensionPoints, ~extensions, ...)`

### Platform

Top-level composition wiring all plugins.

```rescript
module Platform = ReventlessInMemory.Platform.Make()
module Plugin1 = Plugin1Plugin.Plugin1Plugin.Make(Platform)
module Plugin2 = Plugin2Plugin.Plugin2Plugin.Make(Platform)
Platform.makePlatform(~version=Reventless.PackageVersion.fromCwd(), ~plugins=[module(Plugin1), module(Plugin2)])
```
